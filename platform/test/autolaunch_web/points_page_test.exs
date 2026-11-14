defmodule AutolaunchWeb.PointsPageTest do
  # What a signed-in person gets from Points on the first render, with no wait:
  # their own figures, every action by its site with the ones open here and where to
  # do them, and their own row on the leaderboard beside other people's names or
  # wallets. Autolaunch earns nothing (no start time, no rule approved), so this test
  # approves two rules and a start time for itself and records an award the way a
  # site's checked action does. The board every reader shares is then read once, as
  # its producer reads it on notice.
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.{Accounts, SharedReading}
  alias Autolaunch.Actors.System
  alias Autolaunch.Points.Board
  alias RegentPoints.{Amount, Rules, Store}

  defmodule Source do
    @moduledoc false
    # The site's own check of an action, as an adapter answers it: the facts it saved.
    def verify(%{"source_event_key" => key}),
      do: Map.fetch(Application.get_env(:regent_points, :test_facts, %{}), key)
  end

  @earned "account.activated"
  @open "social.x"
  @wallet "0x" <> String.duplicate("b", 40)
  @other "0x" <> String.duplicate("9", 40)

  setup do
    # The site starts its Oban only with the database at start-up; Points queues on it.
    start_supervised!({Oban, Application.fetch_env!(:autolaunch, Oban)})

    keys = [:starts_at, :approved_rules, :adapters, :test_facts]
    previous = Map.new(keys, &{&1, Application.fetch_env(:regent_points, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:regent_points, key, value)
        {key, :error} -> Application.delete_env(:regent_points, key)
      end)

      SharedReading.delete(Board.key())
    end)

    Application.put_env(:regent_points, :starts_at, DateTime.add(DateTime.utc_now(), -86_400))
    Application.put_env(:regent_points, :approved_rules, [@earned, @open])
    Application.put_env(:regent_points, :adapters, %{@earned => Source, @open => Source})

    person =
      Accounts.register_verified!("did:privy:points-page", @wallet, [@wallet], actor: %System{})

    other =
      Accounts.register_verified!("did:privy:points-page-other", @other, [@other],
        actor: %System{}
      )

    for account <- [person, other], do: earn(account)
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :points, with_recursion: true)
    assert :ok = Board.read()

    conn =
      build_conn()
      |> put_req_header("accept", "text/html")
      |> init_test_session(%{human_account_id: person.id})

    %{conn: conn, other: other, person: person}
  end

  test "the first render carries the person's figures, open actions and place", %{conn: conn} do
    page = conn |> get("/account/points") |> html_response(200) |> LazyHTML.from_document()

    assert text(page, "#points-total .rg-points-total__figure") == "25"
    assert text(page, "#points-total dl") =~ "+25"
    assert text(page, "#points-total dl") =~ "#1"

    # The account's own award is ticked; the social link is open and says where to go.
    # The other actions with a page here are not earned here, so none of them links.
    assert page |> todo_row(@earned) |> LazyHTML.attribute("data-done") == ["true"]
    assert page |> todo_row(@open) |> LazyHTML.attribute("data-done") == ["false"]

    assert LazyHTML.attribute(
             LazyHTML.query(page, ~s(#points-todo li[data-done="false"] a)),
             "href"
           ) == ["/account"]

    # Two accounts level on points share first place; only the reader's row is marked.
    ranks =
      page
      |> LazyHTML.query("#points-board li .rg-points-board__rank")
      |> Enum.map(&LazyHTML.text/1)

    assert ranks == ["1", "1"]
    assert page |> LazyHTML.query(~s(#points-board li[data-you="true"])) |> Enum.count() == 1
    refute text(page, "#points-page") =~ "Loading"
  end

  # Every action a Points page lists shows under its site, whichever site earns it:
  # a one-time action is done once earned anywhere, and a daily one shows today's
  # times. An action this site does not earn is never offered as one to do here.
  # The hidden rule never shows, and the agent gets the same groups.
  test "every listed action shows under its site, offered only where this site earns it", %{
    conn: conn,
    person: person
  } do
    count!(person.id, "keyfleet.first_vote", 1)
    count!(person.id, "keyfleet.key_bought", 2)
    of = rule("keyfleet.key_bought")["count"]

    page = conn |> get("/account/points") |> html_response(200) |> LazyHTML.from_document()
    answer = agent_answer(person)

    shown =
      for group <- LazyHTML.query(page, "#points-todo .rg-points-todo__group"),
          do: {text(group, "h3"), todo_labels(group)}

    assert shown ==
             for(
               %{site: site, rules: rules} <- Rules.groups(),
               do: {site, rules |> Enum.map(&Rules.label(&1["id"])) |> Enum.sort()}
             )

    refute Rules.label("template.first_agent_note") in todo_labels(page)
    assert Enum.empty?(LazyHTML.query(page, "#points-limit"))

    assert page |> todo_row("keyfleet.first_vote") |> LazyHTML.attribute("data-done") == ["true"]

    keys = todo_row(page, "keyfleet.key_bought")
    assert LazyHTML.attribute(keys, "data-done") == ["false"]
    assert keys |> LazyHTML.query("progress") |> LazyHTML.attribute("value") == ["2"]

    assert Enum.map(answer["to_do"], & &1["site"]) == Enum.map(Rules.groups(), & &1.site)
    actions = actions(answer)

    assert %{"done" => true, "left" => false, "repeats" => "once"} =
             actions[Rules.label("keyfleet.first_vote")]

    assert %{"done" => false, "left" => false, "repeats" => "once"} =
             actions[Rules.label("keyfleet.first_membership")]

    assert %{"done" => false, "left" => false, "repeats" => "daily", "today" => today} =
             actions[Rules.label("keyfleet.key_bought")]

    assert today == %{"done" => 2, "of" => of}

    # Left to do here: only the open action this site earns, the social link.
    assert for({label, %{"left" => true}} <- actions, do: label) == [Rules.label(@open)]
  end

  # While a daily action earns here, it stays to do until today's count is used or
  # the one limit every daily action shares is spent, and that limit shows under the
  # list's title with what is used of it today, as the agent gets it.
  test "a daily action earned here counts today's times against its count and the limit", %{
    conn: conn,
    person: person
  } do
    created = "autolaunch.auction_created"
    bid = "autolaunch.auction_bid"
    adapters = Application.get_env(:regent_points, :adapters)
    Application.put_env(:regent_points, :approved_rules, [@earned, @open, created, bid])

    Application.put_env(
      :regent_points,
      :adapters,
      Map.merge(adapters, %{created => Source, bid => Source})
    )

    limit = Rules.daily_cap("activity:account")
    count!(person.id, bid, 1)
    spend!(person.id, Rules.program(), "activity:account", today(), 20 * Rules.unit())

    page = conn |> get("/account/points") |> html_response(200) |> LazyHTML.from_document()
    assert page |> todo_row(bid) |> LazyHTML.attribute("data-done") == ["true"]
    assert page |> todo_row(created) |> LazyHTML.attribute("data-done") == ["false"]

    bar = LazyHTML.query(page, "#points-limit progress")
    assert LazyHTML.attribute(bar, "value") == ["20"]
    assert LazyHTML.attribute(bar, "max") == [to_string(div(limit, Rules.unit()))]

    answer = agent_answer(person)
    assert %{"done" => true, "left" => false} = actions(answer)[Rules.label(bid)]
    assert %{"done" => false, "left" => true} = actions(answer)[Rules.label(created)]
    assert [%{"remaining" => remaining}] = answer["daily_limits"]
    assert remaining == Amount.format(limit - 20 * Rules.unit())

    # Once the shared limit is spent, nothing daily is left to do today.
    spend!(person.id, Rules.program(), "activity:account", today(), limit - 20 * Rules.unit())
    spent = build_conn() |> get("/api/v1/account/points") |> json_response(200)
    assert %{"done" => false, "left" => false} = actions(spent)[Rules.label(created)]
  end

  # Names are not unique, and everyone who has only the first award is level on points:
  # two people named alike at one place still get a picture each. Names are read for
  # the site's Privy app, which the test suite has none of until this test names one.
  test "two people with one name, level on points, each keep their own picture", %{
    conn: conn,
    other: other,
    person: person
  } do
    privy = Application.get_env(:autolaunch, :privy, [])
    Application.put_env(:autolaunch, :privy, Keyword.put(privy, :app_id, "test-app"))
    on_exit(fn -> Application.put_env(:autolaunch, :privy, privy) end)
    now = DateTime.utc_now()

    Autolaunch.Repo.insert_all(
      "profiles",
      for did <- [person.privy_user_id, other.privy_user_id] do
        %{
          id: Ecto.UUID.bingenerate(),
          app_id: "test-app",
          privy_user_id: did,
          display_name: "Sam",
          wallet_addresses: [],
          proof_issued_at: 0,
          inserted_at: now,
          updated_at: now
        }
      end,
      prefix: "regent_identity",
      on_conflict: {:replace, [:display_name, :updated_at]},
      conflict_target: [:app_id, :privy_user_id]
    )

    assert :ok = Board.read()
    page = conn |> get("/account/points") |> html_response(200) |> LazyHTML.from_document()

    faces =
      for row <- LazyHTML.query(page, "#points-board li"),
          LazyHTML.text(row) =~ "Sam",
          id <- row |> LazyHTML.query("[id]") |> LazyHTML.attribute("id"),
          do: id

    assert text(page, "#points-board") |> String.split("Sam") |> length() == 3
    assert length(faces) == 2
    assert faces == Enum.uniq(faces)
  end

  # Every wallet is public: another person with no name shows by their wallet, whose
  # copy icon copies it in full. Nothing else about the account leaves it.
  test "a person with no name shows by their wallet, with its copy icon", %{
    conn: conn,
    other: other
  } do
    html = conn |> get("/account/points") |> html_response(200)
    page = LazyHTML.from_document(html)

    copies =
      page
      |> LazyHTML.query(
        ~s(#points-board li[data-you="false"] [id^="points-board-wallet-"][id$="-copy"])
      )
      |> LazyHTML.attribute("data-copy-text")

    assert @other in copies
    assert text(page, "#points-board") =~ Regent.Primitives.short_address(@other)
    refute html =~ other.privy_user_id
  end

  # A person's paired agent reads the same figures the page shows, and its copy of
  # the leaderboard carries a place, a name or wallet and a total for each row.
  test "a paired agent is answered with the page's figures", %{conn: conn, person: person} do
    page = conn |> get("/account/points") |> html_response(200) |> LazyHTML.from_document()
    answer = agent_answer(person)

    assert answer["points"] == text(page, "#points-total .rg-points-total__figure")
    assert "#" <> to_string(answer["rank"]) == "#1"
    assert answer["earned_today"] == "25"

    assert %{"done" => true, "left" => false} = actions(answer)[Rules.label(@earned)]
    assert %{"done" => false, "left" => true} = actions(answer)[Rules.label(@open)]
    assert Enum.map(answer["to_do"], & &1["site"]) == todo_sites(page)
    assert answer |> actions() |> Map.keys() |> Enum.sort() == todo_labels(page)

    assert length(answer["leaderboard"]) ==
             page |> LazyHTML.query("#points-board li") |> Enum.count()

    for row <- answer["leaderboard"] do
      assert row |> Map.keys() |> Enum.sort() == ~w(ens_name name points rank wallet you)
    end

    assert %{"name" => nil, "ens_name" => nil, "you" => false} =
             Enum.find(answer["leaderboard"], &(&1["wallet"] == @other))
  end

  # While the board is held for signed-in readers, a signed-out visitor gets none of it.
  test "a signed-out visitor is asked to sign in and gets nothing from the board" do
    assert {:ok, %{reading: %{top: [_ | _] = top}}} = SharedReading.fetch(Board.key())

    html =
      build_conn()
      |> put_req_header("accept", "text/html")
      |> get("/account/points")
      |> html_response(200)

    page = LazyHTML.from_document(html)

    assert Enum.count(LazyHTML.query(page, "#points-signed-out")) == 1
    assert Enum.empty?(LazyHTML.query(page, "#points-total"))
    assert Enum.empty?(LazyHTML.query(page, "#points-board"))
    for row <- top, shown <- [row.name, row.wallet], shown, do: refute(html =~ shown)
  end

  # Where the page would show the board as not read, the agent gets no half answer.
  test "while the board is not read, the agent's whole answer is unavailable", %{
    person: person
  } do
    SharedReading.delete(Board.key())

    assert %{"error" => %{"code" => "account_unavailable"}} =
             person |> agent_points() |> json_response(503)
  end

  defp agent_answer(person), do: person |> agent_points() |> json_response(200)

  # Pairs an agent with the person and asks for Points as that agent; the sign-in
  # service's check of the agent's signature is answered here.
  defp agent_points(person) do
    Req.Test.stub(RegentAgents.Broker, fn conn ->
      Req.Test.json(conn, %{
        code: "http_envelope_valid",
        data: %{
          verified: true,
          walletAddress: @wallet,
          agentBook: nil,
          agentRegistration: nil,
          principal: %{
            kind: "wallet",
            wallet_address: @wallet,
            chain_id: 8453,
            audience: "autolaunch"
          }
        }
      })
    end)

    code =
      RegentAgents.issue_pairing_code!(
        actor: %RegentAgents.Person{privy_user_id: person.privy_user_id}
      )

    RegentAgents.pair_agent!(code.code, "Fixture", :codex,
      actor: %RegentAgents.Agent{wallet: @wallet}
    )

    get(build_conn(), "/api/v1/account/points")
  end

  # Records the account's activation the way a site's checked action does.
  defp earn(account) do
    key = "#{@earned}:#{account.id}"
    at = DateTime.utc_now()

    facts = %{
      source_app: "autolaunch",
      source_kind: "test",
      source_event_key: key,
      account_id: account.id,
      actor_kind: "human",
      actor_id: to_string(account.id),
      source_action_at: at,
      qualified_at: at,
      evidence_ref: "test:" <> key,
      evidence: %{}
    }

    saved = Application.get_env(:regent_points, :test_facts, %{})
    Application.put_env(:regent_points, :test_facts, Map.put(saved, key, facts))

    {:ok, _} =
      RegentPoints.record_event(
        %{rule_id: @earned, source_app: "autolaunch", source_kind: "test", source_event_key: key},
        actor: RegentPoints.Store.system()
      )
  end

  # How many times the account has had a rule, ever for a one-time one and today for
  # a daily one, kept where an award keeps it, as if another site had earned it.
  defp count!(account_id, id, times) do
    rule = rule(id)
    program = if rule["period"] == "lifetime", do: "lifetime", else: Rules.program()
    window = Rules.window(rule["period"], DateTime.utc_now())

    for _ <- 1..times, do: spend!(account_id, program, Rules.count_scope(rule), window, 0)
  end

  defp spend!(account_id, program, scope, {from, to}, points) do
    %{
      account_id: account_id,
      program_id: program,
      cap_scope: scope,
      window_start: from,
      window_end: to
    }
    |> RegentPoints.reserve_cap!(actor: Store.system())
    |> RegentPoints.consume_cap!(points, actor: Store.system())
  end

  defp today, do: Rules.window("day", DateTime.utc_now())

  defp rule(id), do: Enum.find(Rules.catalog(), &(&1["id"] == id))

  # The agent's actions by label, from every site's group.
  defp actions(answer),
    do:
      for(
        group <- answer["to_do"],
        action <- group["actions"],
        into: %{},
        do: {action["label"], action}
      )

  defp todo_sites(page) do
    page
    |> LazyHTML.query("#points-todo .rg-points-todo__group > h3")
    |> Enum.map(&String.trim(LazyHTML.text(&1)))
  end

  defp todo_row(page, id) do
    page
    |> LazyHTML.query("#points-todo li")
    |> Enum.find(&(text(&1, ".rg-points-todo__label > :first-child") == Rules.label(id)))
  end

  defp todo_labels(page) do
    page
    |> LazyHTML.query("li .rg-points-todo__label > :first-child")
    |> Enum.map(&String.trim(LazyHTML.text(&1)))
    |> Enum.sort()
  end

  defp text(page, selector),
    do: page |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
end
