defmodule Autolaunch.Accounts.SessionAuthorityTest do
  use AutolaunchWeb.ConnCase, async: false

  import Ecto.Query

  require Ash.Query

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.Repo

  @maximum_generation 9_223_372_036_854_775_807
  @wallet "0x1111111111111111111111111111111111111111"

  test "CANONICAL_AUTHORITY_ROW: a claim parses only from canonical, self-consistent fields" do
    claim = SessionAuthority.bootstrap()
    session = SessionAuthority.session(claim)

    assert claim |> Map.keys() |> Enum.sort() == [:generation, :lineage]
    assert session |> Map.keys() |> Enum.sort() == canonical_keys()
    assert SessionAuthority.claim(session) == claim

    for malformed <- [
          %{
            session
            | "live_socket_id" => SessionAuthority.topic(SessionAuthority.bootstrap().lineage)
          },
          %{session | "session_lineage" => String.replace_suffix(claim.lineage, "", "A")},
          %{session | "session_lineage" => binary_part(claim.lineage, 0, 42)},
          %{session | "session_lineage" => "not a lineage" <> String.duplicate("=", 30)},
          %{session | "session_generation" => -1},
          %{session | "session_generation" => @maximum_generation + 1},
          %{session | "session_generation" => "1"},
          Map.delete(session, "live_socket_id"),
          Map.delete(session, "session_generation"),
          %{}
        ] do
      assert SessionAuthority.claim(malformed) == nil
    end
  end

  test "LINEAGE_STABLE_SOCKET_TOPIC: the topic is the lineage digest and nothing else" do
    account = account!("topic")
    claim = SessionAuthority.bootstrap()

    assert SessionAuthority.topic(claim.lineage) ==
             "session_authority:" <>
               Base.url_encode64(:crypto.hash(:sha256, claim.lineage), padding: false)

    {:ok, :bind, bound} = SessionAuthority.sign_in(claim, account.id)
    {:ok, :refresh, refreshed} = SessionAuthority.sign_in(bound, account.id)

    assert SessionAuthority.session(refreshed)["live_socket_id"] ==
             SessionAuthority.topic(claim.lineage)

    assert SessionAuthority.revoke(refreshed) == SessionAuthority.topic(claim.lineage)

    refute SessionAuthority.topic(SessionAuthority.bootstrap().lineage) ==
             SessionAuthority.topic(claim.lineage)
  end

  test "CANONICAL_AUTHORITY_ROW: the row keeps the lineage digest and never the cookie's lineage" do
    account = account!("digest")
    {:ok, :bind, bound} = SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id)

    row = row!(bound.lineage)

    assert row.lineage_digest == :crypto.hash(:sha256, bound.lineage)
    refute inspect(row) =~ bound.lineage

    refute Repo.exists?(
             from(authority in "session_authorities",
               where: authority.lineage_digest == ^bound.lineage
             )
           )
  end

  test "GENERATED_PRIVATE_SCHEMA: the database refuses a negative generation" do
    claim = SessionAuthority.bootstrap()

    assert_raise Postgrex.Error, ~r/session_authorities_generation_nonnegative/, fn ->
      # Ash is bypassed on purpose: no action can write a negative generation, so the
      # database check constraint can only be exercised by writing the row directly.
      Repo.update_all(digest_query(claim.lineage), set: [generation: -1])
    end
  end

  test "LEGAL_TRANSITIONS_ONLY: first bind and same-account refresh each advance once" do
    account = account!("advance")
    claim = SessionAuthority.bootstrap()

    assert claim.generation == 0
    assert SessionAuthority.exact(claim) == {:ok, nil}

    assert {:ok, :bind, %{generation: 1} = bound} = SessionAuthority.sign_in(claim, account.id)
    assert SessionAuthority.exact(bound) == {:ok, account.id}

    # The copied pre-bind cookie is stale the moment the lineage binds.
    assert SessionAuthority.exact(claim) == {:error, :superseded}

    assert {:ok, :refresh, %{generation: 2} = refreshed} =
             SessionAuthority.sign_in(bound, account.id)

    assert SessionAuthority.exact(refreshed) == {:ok, account.id}
    assert SessionAuthority.exact(bound) == {:error, :superseded}
  end

  test "LEGAL_TRANSITIONS_ONLY: the actions refuse revocation, replacement and unbound refresh" do
    account = account!("forbidden")
    other = account!("forbidden-other")
    claim = SessionAuthority.bootstrap()

    assert {:error, _unbound_refresh} =
             Ash.update(authority!(claim.lineage), %{}, action: :advance, actor: %System{})

    {:ok, :bind, bound} = SessionAuthority.sign_in(claim, account.id)

    assert {:error, _replacement} =
             Ash.update(authority!(bound.lineage), %{account_id: other.id},
               action: :bind,
               actor: %System{}
             )

    assert SessionAuthority.revoke(bound)
    revoked = authority!(bound.lineage)

    assert {:error, _revoked_refresh} =
             Ash.update(revoked, %{}, action: :advance, actor: %System{})

    assert {:error, _re_revoke} = Ash.update(revoked, %{}, action: :revoke, actor: %System{})

    assert {:error, _rebind} =
             Ash.update(revoked, %{account_id: other.id}, action: :bind, actor: %System{})
  end

  test "LEGAL_TRANSITIONS_ONLY: generation exhaustion revokes instead of wrapping" do
    account = account!("exhaustion")
    {:ok, :bind, bound} = SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id)
    # Ash is bypassed on purpose: reaching the generation ceiling through actions would
    # take 2^63 refreshes, so the row is fast-forwarded straight to the ceiling.
    Repo.update_all(digest_query(bound.lineage), set: [generation: @maximum_generation])
    exhausted = %{bound | generation: @maximum_generation}

    assert SessionAuthority.sign_in(exhausted, account.id) == {:error, :reset}

    assert %{generation: @maximum_generation, revoked_at: revoked_at} = row!(bound.lineage)
    assert revoked_at
    assert SessionAuthority.exact(exhausted) == {:error, :reset}
  end

  test "EXPLICIT_REVOCATION: revocation is terminal, idempotent and keeps its first record" do
    account = account!("revocation")
    {:ok, :bind, bound} = SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id)
    topic = SessionAuthority.topic(bound.lineage)

    assert SessionAuthority.revoke(bound) == topic
    revoked = row!(bound.lineage)
    assert SessionAuthority.revoke(bound) == topic

    assert row!(bound.lineage) == revoked
    assert revoked.revoked_at
    assert revoked.generation == bound.generation
    assert SessionAuthority.exact(bound) == {:error, :reset}
    refute SessionAuthority.leased_account(bound.lineage, account.id)
    assert SessionAuthority.sign_in(bound, account.id) == {:error, :reset}
  end

  test "TWO_STEP_ACCOUNT_SWITCH: a different account revokes the lineage and binds nothing" do
    first = account!("switch-first")
    second = account!("switch-second")
    {:ok, :bind, bound} = SessionAuthority.sign_in(SessionAuthority.bootstrap(), first.id)

    assert SessionAuthority.sign_in(bound, second.id) ==
             {:switch, SessionAuthority.topic(bound.lineage)}

    assert %{human_account_id: still_first, generation: 1, revoked_at: revoked_at} =
             row!(bound.lineage)

    assert still_first == first.id
    assert revoked_at
    assert SessionAuthority.exact(bound) == {:error, :reset}
    # Ash is bypassed on purpose: counting the stored rows directly proves nothing was
    # bound, where a read through Ash could hide rows behind a policy filter instead.
    assert Repo.aggregate(active_rows_for(second.id), :count) == 0

    # Only a later bootstrap and a later sign-in produce the replacement.
    assert {:ok, :bind, replacement} =
             SessionAuthority.sign_in(SessionAuthority.bootstrap(), second.id)

    refute replacement.lineage == bound.lineage
    assert SessionAuthority.exact(replacement) == {:ok, second.id}
  end

  test "STALE_LOGOUT_REVOKES: logout accepts a superseded generation and an unseen lineage" do
    account = account!("stale-logout")
    {:ok, :bind, held} = SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id)
    {:ok, :refresh, current} = SessionAuthority.sign_in(held, account.id)

    assert SessionAuthority.revoke(held) == SessionAuthority.topic(current.lineage)
    assert SessionAuthority.exact(current) == {:error, :reset}
    assert row!(held.lineage).generation == current.generation

    unseen = absent_claim(4)

    assert SessionAuthority.revoke(unseen) == SessionAuthority.topic(unseen.lineage)
    assert row!(unseen.lineage).revoked_at
    assert SessionAuthority.sign_in(unseen, account.id) == {:error, :reset}
  end

  test "EXACT_CSRF_MATRIX: renewal separates bootstrap, observation, supersession and reset" do
    account = account!("matrix")

    assert {:bootstrap, %{generation: 0} = fresh} = SessionAuthority.renew(nil)
    assert {:current, ^fresh} = SessionAuthority.renew(fresh)

    missing_at_zero = absent_claim(0)
    assert {:current, ^missing_at_zero} = SessionAuthority.renew(missing_at_zero)
    assert row!(missing_at_zero.lineage).generation == 0

    {:ok, :bind, bound} = SessionAuthority.sign_in(fresh, account.id)
    assert {:current, ^bound} = SessionAuthority.renew(bound)
    assert SessionAuthority.renew(fresh) == {:error, :superseded}
    assert SessionAuthority.renew(%{bound | generation: bound.generation + 1}) == {:error, :reset}

    missing_above_zero = absent_claim(3)
    handler = attach_absent_row_telemetry()
    assert SessionAuthority.renew(missing_above_zero) == {:error, :reset}
    refute Repo.exists?(digest_query(missing_above_zero.lineage))
    assert_receive {:absent_row, %{count: 1}, %{generation: 3}}
    :telemetry.detach(handler)

    assert SessionAuthority.revoke(bound)
    assert SessionAuthority.renew(bound) == {:error, :reset}
  end

  test "CENTRAL_CURRENT_ACTOR: resolution names a lineage only while its claim is current" do
    account = account!("resolve")
    claim = SessionAuthority.bootstrap()

    assert {lineage, nil} = SessionAuthority.resolve(claim)
    assert lineage == claim.lineage

    {:ok, :bind, bound} = SessionAuthority.sign_in(claim, account.id)
    assert {bound_lineage, resolved} = SessionAuthority.resolve(bound)
    assert bound_lineage == bound.lineage
    assert resolved.id == account.id

    assert SessionAuthority.resolve(claim) == {nil, nil}
    assert SessionAuthority.resolve(nil) == {nil, nil}

    expire_provider_evidence!(account)
    assert SessionAuthority.resolve(bound) == {bound.lineage, nil}
  end

  test "MOUNTED_LEASE_POLICY_C: a lease survives drift and lapses with the account or the row" do
    account = account!("lease")
    other = account!("lease-other")
    {:ok, :bind, bound} = SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id)

    assert SessionAuthority.leased_account(bound.lineage, account.id).id == account.id
    refute SessionAuthority.leased_account(bound.lineage, other.id)

    assert {:ok, :refresh, _drifted} = SessionAuthority.sign_in(bound, account.id)
    assert SessionAuthority.leased_account(bound.lineage, account.id).id == account.id

    expire_provider_evidence!(account)
    refute SessionAuthority.leased_account(bound.lineage, account.id)

    assert SessionAuthority.revoke(bound)
    refute SessionAuthority.leased_account(bound.lineage, account.id)
  end

  test "TRANSACTION_CURRENTNESS_PRIMITIVES: the exact primitive requires the generation it names" do
    account = account!("transact-exact")
    {:ok, :bind, bound} = SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id)

    assert {:ok, resolved} = SessionAuthority.transact_exact(bound, &{:ok, &1.id})
    assert resolved == account.id

    for stale <- [
          %{bound | generation: bound.generation - 1},
          %{bound | generation: bound.generation + 1},
          absent_claim(1),
          nil
        ] do
      assert SessionAuthority.transact_exact(stale, fn _account -> flunk("stale reached it") end) ==
               {:error, :stale_authority}
    end

    assert {:ok, :refresh, drifted} = SessionAuthority.sign_in(bound, account.id)

    assert SessionAuthority.transact_exact(bound, fn _account -> flunk("drift reached it") end) ==
             {:error, :stale_authority}

    assert {:ok, _resolved} = SessionAuthority.transact_exact(drifted, &{:ok, &1.id})
  end

  test "TRANSACTION_CURRENTNESS_PRIMITIVES: the lease primitive allows drift and refuses lapses" do
    account = account!("transact-lease")
    other = account!("transact-lease-other")
    {:ok, :bind, bound} = SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id)

    assert {:ok, :refresh, _drifted} = SessionAuthority.sign_in(bound, account.id)

    assert {:ok, resolved} =
             SessionAuthority.transact_lease(bound.lineage, account.id, &{:ok, &1.id})

    assert resolved == account.id

    assert SessionAuthority.transact_lease(bound.lineage, other.id, fn _account ->
             flunk("another account reached it")
           end) == {:error, :stale_authority}

    expire_provider_evidence!(account)

    assert SessionAuthority.transact_lease(bound.lineage, account.id, fn _account ->
             flunk("expired provider evidence reached it")
           end) == {:error, :stale_authority}

    restore_provider_evidence!(account)

    assert {:ok, _resolved} =
             SessionAuthority.transact_lease(bound.lineage, account.id, &{:ok, &1.id})

    assert SessionAuthority.revoke(bound)

    assert SessionAuthority.transact_lease(bound.lineage, account.id, fn _account ->
             flunk("revoked authority reached it")
           end) == {:error, :stale_authority}
  end

  test "TRANSACTION_CURRENTNESS_PRIMITIVES: a refused, raising or rolled-back write persists nothing" do
    account = account!("rollback")
    {:ok, :bind, bound} = SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id)

    assert SessionAuthority.transact_exact(bound, fn _account ->
             send(self(), {:written, SessionAuthority.bootstrap()})
             {:error, :refused}
           end) == {:error, :refused}

    assert_received {:written, refused}

    assert_raise RuntimeError, "callback failed", fn ->
      SessionAuthority.transact_lease(bound.lineage, account.id, fn _account ->
        send(self(), {:written, SessionAuthority.bootstrap()})
        raise "callback failed"
      end)
    end

    assert_received {:written, raised}

    assert {:error, :outer_rollback} =
             Repo.transaction(fn ->
               SessionAuthority.transact_exact(bound, fn _account ->
                 {:ok, send(self(), {:written, SessionAuthority.bootstrap()})}
               end)

               Repo.rollback(:outer_rollback)
             end)

    assert_received {:written, rolled_back}

    for discarded <- [refused, raised, rolled_back] do
      refute Repo.exists?(digest_query(discarded.lineage))
    end

    assert {:ok, committed} =
             SessionAuthority.transact_lease(bound.lineage, account.id, fn _account ->
               {:ok, SessionAuthority.bootstrap()}
             end)

    assert Repo.exists?(digest_query(committed.lineage))
  end

  test "SERIALIZED_ABSENT_AND_PRESENT_ROWS: an absent row serializes a bind that a revocation then ends" do
    account = shared_account!("absent-bind-first")
    claim = absent_claim(0)
    discard_on_exit([claim])

    binder = holding(fn -> SessionAuthority.sign_in(claim, account.id) end)
    revoker = contending(fn -> SessionAuthority.revoke(claim) end)
    assert_blocked_by(revoker, binder)

    assert {:ok, :bind, bound} = release(binder)
    assert bound.generation == 1
    assert settled(revoker) == SessionAuthority.topic(claim.lineage)
    assert unboxed(fn -> SessionAuthority.exact(bound) end) == {:error, :reset}
    assert unboxed(fn -> row!(claim.lineage) end).human_account_id == account.id
  end

  test "SERIALIZED_ABSENT_AND_PRESENT_ROWS: an absent row revoked first refuses the bind behind it" do
    account = shared_account!("absent-revoke-first")
    claim = absent_claim(0)
    discard_on_exit([claim])

    revoker = holding(fn -> SessionAuthority.revoke(claim) end)
    binder = contending(fn -> SessionAuthority.sign_in(claim, account.id) end)
    assert_blocked_by(binder, revoker)

    assert release(revoker) == SessionAuthority.topic(claim.lineage)
    assert settled(binder) == {:error, :reset}
    assert unboxed(fn -> row!(claim.lineage) end).human_account_id == nil
    assert unboxed(fn -> SessionAuthority.exact(claim) end) == {:error, :reset}
  end

  test "FIRST_BIND_AND_REFRESH_ROTATE: the refresh behind a refresh is superseded, never a second winner" do
    account = shared_account!("refresh-order")

    {:ok, :bind, bound} =
      unboxed(fn -> SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id) end)

    discard_on_exit([bound])

    winner = holding(fn -> SessionAuthority.sign_in(bound, account.id) end)
    loser = contending(fn -> SessionAuthority.sign_in(bound, account.id) end)
    assert_blocked_by(loser, winner)

    assert {:ok, :refresh, advanced} = release(winner)
    assert advanced.generation == bound.generation + 1
    assert settled(loser) == {:error, :superseded}
    assert unboxed(fn -> SessionAuthority.exact(advanced) end) == {:ok, account.id}
    assert unboxed(fn -> SessionAuthority.exact(bound) end) == {:error, :superseded}
    assert unboxed(fn -> row!(bound.lineage) end).generation == advanced.generation
  end

  test "TRANSACTION_CURRENTNESS_PRIMITIVES: a protected write ahead of logout commits and then dies" do
    account = shared_account!("write-first")

    {:ok, :bind, bound} =
      unboxed(fn -> SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id) end)

    test = self()

    writer =
      holding(fn ->
        SessionAuthority.transact_exact(bound, fn _account ->
          {:ok, send(test, {:written, SessionAuthority.bootstrap()}) && :written}
        end)
      end)

    logout = contending(fn -> SessionAuthority.revoke(bound) end)
    assert_blocked_by(logout, writer)

    assert release(writer) == {:ok, :written}
    assert settled(logout) == SessionAuthority.topic(bound.lineage)
    assert_received {:written, committed}
    assert unboxed(fn -> Repo.exists?(digest_query(committed.lineage)) end)
    assert unboxed(fn -> SessionAuthority.exact(bound) end) == {:error, :reset}
    discard_on_exit([bound, committed])
  end

  test "TRANSACTION_CURRENTNESS_PRIMITIVES: a protected write behind logout is refused and writes nothing" do
    account = shared_account!("logout-first")

    {:ok, :bind, bound} =
      unboxed(fn -> SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id) end)

    discard_on_exit([bound])
    test = self()

    logout = holding(fn -> SessionAuthority.revoke(bound) end)

    writer =
      contending(fn ->
        SessionAuthority.transact_lease(bound.lineage, account.id, fn _account ->
          {:ok, send(test, {:written, SessionAuthority.bootstrap()}) && :written}
        end)
      end)

    assert_blocked_by(writer, logout)

    assert release(logout) == SessionAuthority.topic(bound.lineage)
    assert settled(writer) == {:error, :stale_authority}
    refute_received {:written, _rolled_back}
    assert unboxed(fn -> SessionAuthority.exact(bound) end) == {:error, :reset}
  end

  test "TRANSACTION_CURRENTNESS_PRIMITIVES: a protected write ahead of an evidence lapse commits and then lapses" do
    account = shared_account!("evidence-write-first")

    {:ok, :bind, bound} =
      unboxed(fn -> SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id) end)

    discard_on_exit([bound])
    test = self()

    writer =
      holding(fn ->
        SessionAuthority.transact_exact(bound, fn _account ->
          {:ok, send(test, {:written, SessionAuthority.bootstrap()}) && :written}
        end)
      end)

    lapse = contending(fn -> expire_provider_evidence!(account) end)
    assert_blocked_by(lapse, writer)

    assert release(writer) == {:ok, :written}
    assert settled(lapse).id == account.id
    assert_received {:written, committed}
    discard_on_exit([committed])
    assert unboxed(fn -> Repo.exists?(digest_query(committed.lineage)) end)

    # The evidence the callback committed under is gone the moment the lapse it
    # held up commits, so the next protected write is refused.
    assert unboxed(fn ->
             SessionAuthority.transact_exact(bound, fn _account ->
               flunk("lapsed provider evidence reached it")
             end)
           end) == {:error, :stale_authority}
  end

  test "TRANSACTION_CURRENTNESS_PRIMITIVES: a protected write behind an evidence lapse is refused and writes nothing" do
    account = shared_account!("evidence-lapse-first")

    {:ok, :bind, bound} =
      unboxed(fn -> SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id) end)

    discard_on_exit([bound])
    test = self()

    lapse = holding(fn -> expire_provider_evidence!(account) end)

    writer =
      contending(fn ->
        SessionAuthority.transact_lease(bound.lineage, account.id, fn _account ->
          {:ok, send(test, {:written, SessionAuthority.bootstrap()}) && :written}
        end)
      end)

    # Nothing but the account row can be holding this writer up: its own lineage
    # row is uncontended, so the write is waiting on the evidence itself.
    assert_blocked_by(writer, lapse)

    assert release(lapse).id == account.id
    assert settled(writer) == {:error, :stale_authority}
    refute_received {:written, _never_ran}
    refute unboxed(fn -> SessionAuthority.leased_account(bound.lineage, account.id) end)
  end

  defp canonical_keys,
    do: Enum.sort(["live_socket_id", "session_generation", "session_lineage"])

  defp account!(suffix) do
    Accounts.register_verified!(
      "did:privy:session-authority:#{suffix}:#{Elixir.System.unique_integer([:positive])}",
      @wallet,
      [@wallet],
      actor: %System{}
    )
  end

  # A forced ordering needs an account its own visible connections can see, so it
  # reuses one committed row per name instead of committing a new one every run.
  defp shared_account!(suffix) do
    unboxed(fn ->
      "did:privy:regent-6eb-12:#{suffix}"
      |> Accounts.register_verified!(@wallet, [@wallet], actor: %System{})
      |> provider_evidence!(@wallet, [@wallet])
    end)
  end

  defp expire_provider_evidence!(account), do: provider_evidence!(account, nil, [])

  defp restore_provider_evidence!(account),
    do: provider_evidence!(account, @wallet, [@wallet])

  # Wallet evidence only moves from what the stored row holds now, so a reused
  # committed account is reloaded before its evidence is set or withdrawn.
  defp provider_evidence!(account, wallet, wallets) do
    {:ok, stored} =
      Accounts.get_human_account(account.id, actor: %Human{human_account_id: account.id})

    {:ok, _updated} = Accounts.refresh_verified(stored, wallet, wallets, actor: %System{})
    account
  end

  # Holds `attempt`'s row lock open on its own visible connection until the test
  # releases it, so the ordering under test is forced rather than raced.
  defp holding(attempt) do
    test = self()
    task = Task.async(fn -> unboxed(fn -> hold(attempt, test) end) end)

    assert_receive {:holding, holder, backend}, 5_000
    {task, holder, backend}
  end

  defp hold(attempt, test), do: Repo.transaction(fn -> hold_open(attempt, test) end)

  defp hold_open(attempt, test) do
    result = attempt.()
    send(test, {:holding, self(), backend_pid()})
    receive do: (:release -> result)
  end

  defp release({task, holder, _backend}) do
    send(holder, :release)
    {:ok, result} = Task.await(task, 15_000)
    result
  end

  # Starts `attempt` on a second visible connection and announces its backend, so
  # the test can ask PostgreSQL itself who is blocking whom.
  defp contending(attempt) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:contending, backend_pid()})
          send(test, {:settled, attempt.()})
        end)
      end)

    assert_receive {:contending, backend}, 5_000
    {task, backend}
  end

  defp settled({task, _backend}) do
    assert_receive {:settled, result}, 15_000
    Task.await(task, 15_000)
    result
  end

  # PostgreSQL reports the blocking backend, so the ordering is proven by lock
  # state; the attempt bound only turns a hang into a failure.
  defp assert_blocked_by({_task, contender}, {_holder_task, _holder, holder}) do
    assert Enum.reduce_while(1..2_000, false, fn _attempt, _blocked ->
             if holder in blocking_pids(contender), do: {:halt, true}, else: {:cont, false}
           end),
           "the contender never blocked on the held row lock"
  end

  defp blocking_pids(backend) do
    unboxed(fn ->
      %{rows: [[blockers]]} = Repo.query!("SELECT pg_blocking_pids($1)", [backend])
      blockers
    end)
  end

  defp backend_pid do
    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    backend
  end

  # Removes exactly the committed rows this test minted, so repeated runs leave
  # no tombstones behind.
  defp discard_on_exit(claims) do
    on_exit(fn ->
      # Ash is bypassed on purpose: the resource has no destroy action, and this cleanup
      # only has to remove the committed rows the test left outside the sandbox.
      unboxed(fn -> Enum.each(claims, &Repo.delete_all(digest_query(&1.lineage))) end)
    end)
  end

  defp attach_absent_row_telemetry do
    handler = "absent-row-#{Elixir.System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      handler,
      [:autolaunch, :session_authority, :absent_row],
      fn _event, measurements, metadata, _config ->
        send(test, {:absent_row, measurements, metadata})
      end,
      nil
    )

    handler
  end

  # A lineage this node has never committed a row for, built without touching a
  # single stored row.
  defp absent_claim(generation) do
    lineage = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    %{lineage: lineage, generation: generation}
  end

  defp unboxed(attempt), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, attempt)

  defp authority!(lineage) do
    SessionAuthority
    |> Ash.Query.for_read(:by_lineage_digest, %{lineage_digest: :crypto.hash(:sha256, lineage)},
      actor: %System{}
    )
    |> Ash.read_one!()
  end

  defp row!(lineage) do
    Repo.one!(
      from(authority in digest_query(lineage),
        select: %{
          lineage_digest: authority.lineage_digest,
          generation: authority.generation,
          revoked_at: authority.revoked_at,
          human_account_id: authority.human_account_id
        }
      )
    )
  end

  defp digest_query(lineage) do
    from(authority in "session_authorities",
      where: authority.lineage_digest == ^:crypto.hash(:sha256, lineage)
    )
  end

  defp active_rows_for(account_id) do
    from(authority in "session_authorities",
      where: authority.human_account_id == ^account_id and is_nil(authority.revoked_at)
    )
  end
end
