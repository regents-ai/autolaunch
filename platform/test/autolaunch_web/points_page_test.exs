defmodule AutolaunchWeb.PointsPageTest do
  # What a signed-in person gets from Points on the first render, with no wait:
  # their own figures, the actions still open with where to do them, and their own
  # row on the leaderboard beside other people's names or wallets. Autolaunch earns
  # nothing (no start time, no rule approved), so this test approves two rules and a
  # start time for itself and records an award the way a site's checked action does.
  # The board every reader shares is then read once, as its producer reads it on notice.
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.{Accounts, SharedReading}
  alias Autolaunch.Actors.System
  alias Autolaunch.Points.Board

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
    assert text(page, ~s(#points-todo li[data-done="true"])) =~ "Account activated"

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

    assert %{"done" => true, "left" => false} =
             Enum.find(answer["to_do"], &(&1["label"] == "Account activated"))

    assert %{"done" => false, "left" => true} =
             Enum.find(answer["to_do"], &(&1["label"] == "X account linked"))

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

  defp text(page, selector),
    do: page |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
end
