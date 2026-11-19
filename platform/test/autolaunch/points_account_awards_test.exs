defmodule Autolaunch.PointsAccountAwardsTest.X do
  @moduledoc false
  # X's side of the Account page's X button: its sign-in window, and its answer
  # naming the X account the test's callback asks for.
  def authorize_url(_config) do
    state = Ecto.UUID.generate()

    {:ok,
     %{
       url: "https://x.com/i/oauth2/authorize?" <> URI.encode_query(%{state: state}),
       session_params: %{state: state, code_verifier: Ecto.UUID.generate()}
     }}
  end

  def callback(_config, %{"x_user_id" => id}),
    do: {:ok, %{user: %{"data" => %{"id" => id, "username" => "x" <> id}}}}
end

defmodule Autolaunch.PointsAccountAwardsTest do
  # The account rules every Regent site offers, as this site offers them: a new
  # account at sign-in, a GitHub or Farcaster account Privy lists at sign-in, the
  # person's own X connected with the Account page's X button, and a paired
  # agent. Each is offered inside the save that makes it and earns once, on this
  # site or any other; the start run records what no offer did, earning at the
  # start what came before it and at its own time what came after.
  # Autolaunch earns nothing outside production, so each test opens the rules it
  # needs, runs the real library's queue and reads what it wrote.
  use Autolaunch.DataCase, async: false
  use Oban.Testing, repo: Autolaunch.Repo
  import Autolaunch.PointsTesting

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.{SessionAuthority, VerifiedSession, XOAuth}
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.OtherSiteSource
  alias RegentPoints.{IntakeWorker, StartAwards, Store}

  @rules ~w(account.activated social.x social.github social.farcaster agent.activated)

  setup do
    put_env(:x_oauth_strategy, __MODULE__.X)
    put_env(:x_oauth_client_id, "points-test")
  end

  test "a new account earns once, and signing in again offers nothing" do
    open(["account.activated"])
    did = did("new")
    account = sign_in(did, [])
    assert [_offer] = offers("account.activated")

    assert sign_in(did, []).id == account.id
    assert [_offer] = offers("account.activated")

    # The shared account table keeps its time to the second, rounded, so it can
    # be up to half a second ahead of the clock; Points' check waits for it.
    Process.sleep(1_000)
    drain()

    assert awards(account.id) == [{"account.activated", to_string(account.id)}]
    assert [%{source_app: "regents"}] = events("account.activated")
  end

  test "a GitHub link earns once, a refresh offers nothing, and a Farcaster link earns once" do
    open(["social.github", "social.farcaster", "social.x"])
    did = did("linked")
    [github, farcaster, x] = Enum.map([:github, :farcaster, :x], &social/1)
    account = sign_in(did, [github, farcaster, x])

    assert [_offer] = offers("social.github")
    assert [_offer] = offers("social.farcaster")
    # An X account Privy lists is not how X earns here.
    assert offers("social.x") == []

    # Signing in again with the same accounts only refreshes them.
    sign_in(did, [%{github | username: "renamed"}, farcaster, x])
    assert [_offer] = offers("social.github")
    assert [_offer] = offers("social.farcaster")
    drain()

    assert awards(account.id) == [
             {"social.farcaster", "farcaster:" <> farcaster.subject},
             {"social.github", "github:" <> github.subject}
           ]

    # Another GitHub account in its place is linked anew and offered, and the
    # account's GitHub award stays the one it has.
    {:ok, %{inserted_at: linked_at}} = linked(:github, github.subject)
    other = social(:github)
    sign_in(did, [other, farcaster])
    assert {:ok, %{inserted_at: relinked_at}} = linked(:github, other.subject)
    assert DateTime.after?(relinked_at, linked_at)
    assert [_offer] = offers("social.github")
    drain()

    assert {"social.github", "github:" <> github.subject} in awards(account.id)
    assert length(awards(account.id)) == 2
  end

  test "the person's own X earns once; a company X, or reconnecting the same X, earns nothing" do
    open(["social.x"])
    account = sign_in(did("x"), [])
    x_user_id = x_user_id()

    connect_x(account, "profile", x_user_id)
    assert [_offer] = offers("social.x")
    connect_x(account, "company", x_user_id())
    assert [_offer] = offers("social.x")
    drain()

    assert awards(account.id) == [{"social.x", "x:" <> x_user_id}]

    disconnect_x(account, "profile")
    connect_x(account, "profile", x_user_id)
    assert [_offer] = offers("social.x")
    drain()

    assert awards(account.id) == [{"social.x", "x:" <> x_user_id}]
    assert [_event] = events("social.x")
  end

  test "the first paired agent earns once; another agent, or pairing again, earns nothing more" do
    open(["agent.activated"])
    did = did("paired")
    account = sign_in(did, [])
    person = %RegentAgents.Person{privy_user_id: did}
    wallet = wallet()

    # Two agents paired before either award is checked are both recorded; only
    # the first earns, and the second ends capped with no entry of its own.
    first = pair(person, wallet, "First")
    second = pair(person, wallet(), "Second")
    assert length(offers("agent.activated")) == 2
    drain()

    assert awards(account.id) == [{"agent.activated", first.id}]

    assert outcomes("agent.activated") ==
             Enum.sort([{first.id, :confirmed}, {second.id, :capped}])

    # Once it has earned, pairing again records nothing more.
    :ok = RegentAgents.unpair_agent(first, actor: person)
    pair(person, wallet, "First")
    assert [_offer] = offers("agent.activated")
    drain()

    assert awards(account.id) == [{"agent.activated", first.id}]

    assert outcomes("agent.activated") ==
             Enum.sort([{first.id, :confirmed}, {second.id, :capped}])

    assert earned("agent.activated") == [{first.id, 25}]

    # The award's agent is the paired wallet, and the Points page names it.
    assert [%{actor_kind: "agent", actor_id: ^wallet}] =
             for(%{processing_status: :confirmed} = event <- events("agent.activated"), do: event)

    assert {:ok, %{^wallet => "First"}} =
             Autolaunch.Points.Accounts.agent_names(account.id, [wallet])
  end

  test "the start run records what Points has not: from before the start at the start, from after it at its own time, once" do
    # Points has not started, and nothing is approved.
    open([])
    close()

    did = did("early")
    github = social(:github)
    early = sign_in(did, [github])
    x_user_id = x_user_id()
    connect_x(early, "profile", x_user_id)
    pairing = pair(%RegentAgents.Person{privy_user_id: did}, wallet(), "Early")
    company_did = did("company")
    company = sign_in(company_did, [])
    connect_x(company, "company", x_user_id())
    recorded = sign_in(did("recorded"), [social(:github)])
    assert all_enqueued(queue: :points) == []

    # The shared account table keeps its time to the second, rounded, so it can
    # be up to half a second ahead of the clock.
    Process.sleep(1_000)
    start = DateTime.utc_now()
    Application.put_env(:regent_points, :starts_at, start)

    # After the start, while no rule is approved, the company's owner links GitHub.
    late = social(:github)
    sign_in(company_did, [late])
    {:ok, %{inserted_at: late_linked_at}} = linked(:github, late.subject)
    assert all_enqueued(queue: :points) == []

    Application.put_env(:regent_points, :approved_rules, @rules)

    # Another site already recorded a GitHub account for this account.
    elsewhere = "github:" <> Ecto.UUID.generate()
    rewarded_elsewhere(recorded.id, "social.github", elsewhere)

    # A second run before the first one's offers are checked offers them all again.
    assert :ok = StartAwards.perform(%Oban.Job{})
    first_run = length(intake())
    assert :ok = StartAwards.perform(%Oban.Job{})
    assert length(intake()) == 2 * first_run
    drain()

    assert awards(early.id) == [
             {"account.activated", to_string(early.id)},
             {"agent.activated", pairing.id},
             {"social.github", "github:" <> github.subject},
             {"social.x", "x:" <> x_user_id}
           ]

    for %{account_id: id, source_action_at: at} <- events(),
        id == early.id,
        do: assert(DateTime.compare(at, start) == :eq)

    assert awards(company.id) == [
             {"account.activated", to_string(company.id)},
             {"social.github", "github:" <> late.subject}
           ]

    assert [%{source_action_at: late_at}] =
             for(
               %{account_id: id} = event <- events("social.github"),
               id == company.id,
               do: event
             )

    assert DateTime.compare(late_at, late_linked_at) == :eq
    assert DateTime.after?(late_at, start)

    assert awards(recorded.id) == [
             {"account.activated", to_string(recorded.id)},
             {"social.github", elsewhere}
           ]

    # Each account has one event and one entry for each rule, however many runs
    # offered it, and no offer was refused.
    assert length(events()) == length(Enum.uniq_by(events(), &{&1.account_id, &1.rule_id}))
    assert RegentPoints.read_rejections!(actor: Store.system()) == []

    entries = RegentPoints.read_entries!(actor: Store.system())
    assert length(entries) == length(Enum.uniq_by(entries, &{&1.account_id, &1.rule_id}))

    # A later run finds every account already recorded and offers nothing more.
    assert :ok = StartAwards.perform(%Oban.Job{})
    assert all_enqueued(queue: :points) == []
  end

  test "an X or GitHub account another site rewarded earns nothing here" do
    open(["social.github", "social.x"])
    someone = sign_in(did("someone"), [])
    github = social(:github)
    x_user_id = x_user_id()

    # Another site, under its own name, rewarded someone's X and GitHub accounts.
    rewarded_elsewhere(someone.id, "social.github", "github:" <> github.subject)
    rewarded_elsewhere(someone.id, "social.x", "x:" <> x_user_id)

    # Here a newcomer links that GitHub account and connects that X account.
    newcomer = sign_in(did("newcomer"), [github])
    connect_x(newcomer, "profile", x_user_id)
    drain()

    assert awards(newcomer.id) == []

    assert statuses(newcomer.id) == [
             {"social.github", "autolaunch", :capped},
             {"social.x", "autolaunch", :capped}
           ]
  end

  test "with the rules off, signing in, linking, connecting X and pairing all work and offer nothing" do
    # Points has started, and none of these rules is approved.
    open([])

    did = did("closed")
    x_user_id = x_user_id()
    account = sign_in(did, [social(:github), social(:farcaster)])
    connect_x(account, "profile", x_user_id)
    pair(%RegentAgents.Person{privy_user_id: did}, wallet(), "Agent")

    assert {:ok, [_, _]} =
             Accounts.list_linked_identities_for_account(account.id, actor: %System{})

    assert {:ok, %{x_user_id: ^x_user_id}} =
             Accounts.get_my_x_connection(:profile, actor: %Human{human_account_id: account.id})

    assert {:ok, [_pairing]} = RegentAgents.pairing_histories(did)

    assert all_enqueued(queue: :points) == []
    drain()
    assert events() == []
    assert RegentPoints.read_rejections!(actor: Store.system()) == []
  end

  # The person's verified Privy sign-in, with the social accounts Privy lists.
  defp sign_in(did, socials) do
    wallet = "0x" <> String.slice(Base.encode16(:crypto.hash(:sha, did), case: :lower), 0, 40)

    assert {:ok, account, []} =
             VerifiedSession.establish(%RegentPrivy.Session{
               app_id: "test-app",
               session_id: "test-session",
               privy_user_id: did,
               wallet_address: wallet,
               wallet_addresses: [wallet],
               linked_socials: socials,
               issued_at: :erlang.system_time(:second),
               expires_at: :erlang.system_time(:second) + 3600
             })

    account
  end

  # The Account page's X button: X's window opens, and X answers with `x_user_id`.
  defp connect_x(account, role, x_user_id) do
    claim = claim(account)
    assert {:ok, %{url: url}} = XOAuth.begin(claim, role, intent())
    %{"state" => state} = URI.decode_query(URI.parse(url).query)

    assert {:ok, _connected} =
             XOAuth.callback(claim, %{
               "state" => state,
               "code" => "code",
               "x_user_id" => x_user_id
             })
  end

  defp disconnect_x(account, role),
    do: assert({:ok, _disconnected} = XOAuth.disconnect(claim(account), role, intent()))

  defp claim(account) do
    {:ok, :bind, claim} = SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id)
    claim
  end

  defp intent,
    do: %{
      "intent_sequence" => Elixir.System.unique_integer([:positive, :monotonic]),
      "intent_generation" => Ecto.UUID.generate()
    }

  defp pair(person, wallet, name) do
    code = RegentAgents.issue_pairing_code!(actor: person)
    RegentAgents.pair_agent!(code.code, name, :codex, actor: %RegentAgents.Agent{wallet: wallet})
  end

  defp linked(provider, subject),
    do: Accounts.get_linked_identity_by_subject(provider, subject, actor: %System{})

  # What another site's award leaves in the shared ledger: its event and its
  # entry, under that site's name, earned at the start.
  defp rewarded_elsewhere(account_id, rule, key) do
    start = Application.fetch_env!(:regent_points, :starts_at)
    {:ok, snapshot} = RegentPoints.Rules.snapshot(rule, start)

    facts = %{
      source_app: "regents",
      source_kind: "linked_identity",
      source_event_key: key,
      account_id: account_id,
      actor_kind: "human",
      actor_id: to_string(account_id),
      source_action_at: start,
      qualified_at: start,
      evidence_ref: "linked_identity:" <> Ecto.UUID.generate(),
      evidence: %{"subject_key" => key}
    }

    RegentPoints.open_account!(%{id: account_id}, actor: Store.system())

    event =
      RegentPoints.create_event!(
        Map.merge(facts, %{
          program_id: RegentPoints.Rules.program(),
          rule_id: rule,
          rule_snapshot: snapshot,
          award_key: Store.digest({"regents", "linked_identity", key, rule}),
          payload_digest: Store.digest(facts)
        }),
        actor: Store.system()
      )

    assert {:ok, %{status: :confirmed}} =
             OtherSiteSource.settle(rule, fn ->
               RegentPoints.process_event(event.id, actor: Store.system())
             end)
  end

  defp offers(rule), do: for(%{args: %{"rule_id" => ^rule}} = job <- intake(), do: job)
  defp intake, do: all_enqueued(worker: IntakeWorker)

  # Each award the account holds, as `{rule, source key}`, sorted.
  defp awards(account_id) do
    keys = Map.new(events(), &{&1.id, &1.source_event_key})

    RegentPoints.read_entries!(actor: Store.system())
    |> Enum.filter(&(&1.account_id == account_id and &1.points_micro_delta > 0))
    |> Enum.map(&{&1.rule_id, Map.fetch!(keys, &1.event_id)})
    |> Enum.sort()
  end

  # What became of each action recorded for the account, by the site that recorded it.
  defp statuses(account_id) do
    for(
      %{account_id: ^account_id} = event <- events(),
      do: {event.rule_id, event.source_app, event.processing_status}
    )
    |> Enum.sort()
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:autolaunch, key)
    Application.put_env(:autolaunch, key, value)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:autolaunch, key, value)
        :error -> Application.delete_env(:autolaunch, key)
      end
    end)
  end

  defp did(name), do: "did:privy:points-#{name}-" <> Ecto.UUID.generate()
  defp x_user_id, do: Integer.to_string(Elixir.System.unique_integer([:positive]))
  defp wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

  defp social(provider),
    do: %{
      provider: provider,
      subject: "#{provider}-" <> Ecto.UUID.generate(),
      username: "linked",
      display_name: nil
    }
end
