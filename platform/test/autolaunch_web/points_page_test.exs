defmodule AutolaunchWeb.PointsPageTest do
  # What a signed-in person gets from Points on the first render, with no wait:
  # their own figures, the actions still open with where to do them, and their own
  # row on the leaderboard beside other people's names or wallets. Awards are earned the
  # way the site earns them: an account is made, and the queued checks are run. The
  # board every reader shares is then read once, as its producer reads it on notice.
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.{Accounts, SharedReading}
  alias Autolaunch.Accounts.VerifiedSession
  alias Autolaunch.Actors.System
  alias Autolaunch.Points.Board

  @wallet "0x" <> String.duplicate("b", 40)
  @other "0x" <> String.duplicate("9", 40)

  setup do
    # The site starts its Oban only with the database at start-up; Points queues on it.
    start_supervised!({Oban, Application.fetch_env!(:autolaunch, Oban)})

    previous =
      Map.new([:starts_at, :approved_rules], &{&1, Application.get_env(:regent_points, &1)})

    Application.put_env(:regent_points, :starts_at, ~U[2020-01-01 00:00:00Z])
    Application.put_env(:regent_points, :approved_rules, ~w(account.activated social.x))

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:regent_points, key, value) end)
      SharedReading.delete(Board.key())
    end)

    other =
      Accounts.register_verified!("did:privy:points-page-other", @other, [@other],
        actor: %System{}
      )

    {:ok, account, []} =
      VerifiedSession.establish(%RegentPrivy.Session{
        app_id: "test-app",
        session_id: "points-page",
        privy_user_id: "did:privy:points-page",
        wallet_address: @wallet,
        wallet_addresses: [@wallet],
        linked_socials: [],
        issued_at: :os.system_time(:second),
        expires_at: :os.system_time(:second) + 3600
      })

    # The account's time is kept to the second, rounded, so it can be up to half a
    # second ahead; Points' check waits for it.
    Process.sleep(1_000)
    assert %{failure: 0} = Oban.drain_queue(queue: :points, with_recursion: true)
    assert :ok = Board.read()

    conn =
      build_conn()
      |> put_req_header("accept", "text/html")
      |> init_test_session(%{human_account_id: account.id})

    %{conn: conn, other: other, person: account}
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

  defp text(page, selector),
    do: page |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
end
