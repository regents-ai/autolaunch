defmodule Autolaunch.BidOperationTest do
  @moduledoc """
  What the durable bid row guarantees.

  The barrier proofs run on real second connections and let PostgreSQL report
  the ordering through `pg_blocking_pids`, so no clock decides a race. They
  commit outside the sandbox, which is why the whole block clears its own
  committed rows before and after every test.
  """

  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture
  import Ecto.Query

  require Ash.Query

  alias Autolaunch
  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.Human
  alias Autolaunch.{Auction, BidOperation, TreasurySecurityReport}
  alias Autolaunch.Repo
  alias Autolaunch.TestAutolaunchBidChainClient, as: Chain

  @approval_hash "0x" <> String.duplicate("aa", 32)
  @permit2_hash "0x" <> String.duplicate("bb", 32)
  @bid_hash "0x" <> String.duplicate("cc", 32)
  @other_hash "0x" <> String.duplicate("dd", 32)
  @barrier_treasury "0x8888888888888888888888888888888888888888"

  setup :bidder
  setup :verified_treasury

  setup do
    install()
    :ok
  end

  defp verified_treasury(%{auction: auction}) do
    report =
      Autolaunch.TestAutolaunchTreasuryChainClient.seed_verified!(
        "0x9999999999999999999999999999999999999999"
      )

    Autolaunch.set_auction_treasury_security_report!(auction, report.id, actor: system())

    on_exit(fn ->
      Application.delete_env(:autolaunch, :autolaunch_treasury_chain_client)
      Application.delete_env(:autolaunch, :test_autolaunch_treasury_observation)
    end)

    :ok
  end

  test "ORDERED_SINGLE_SEND: each step binds its own hash before the next becomes sendable", %{
    auction: auction,
    wallet: wallet,
    opts: opts
  } do
    operation = review(auction, wallet, opts)
    assert {operation.step, operation.state} == {:token_approval, :prepared}

    operation = confirm_step(operation, :token_approval, @approval_hash, opts)
    assert {operation.step, operation.state} == {:permit2_approval, :prepared}
    assert operation.token_approval_transaction_hash == @approval_hash

    operation = confirm_step(operation, :permit2_approval, @permit2_hash, opts)
    assert {operation.step, operation.state} == {:bid, :prepared}
    assert operation.permit2_approval_transaction_hash == @permit2_hash

    Chain.put(%{outcomes: %{bid: %{outcome: :confirmed, onchain_bid_id: "42"}}})
    operation = confirm_step(operation, :bid, @bid_hash, opts)

    assert operation.state == :confirmed
    assert operation.onchain_bid_id == "42"
    assert operation.bid_transaction_hash == @bid_hash
    assert operation.terminal_at

    # The confirmed bid released the account's open slot.
    assert {:ok, %{operation: nil}} = Autolaunch.open_bid_operation(opts)
  end

  test "BID_ID_IS_ADOPTED_FROM_THE_EVENT: a receipt contradicting the review never confirms", %{
    auction: auction,
    wallet: wallet,
    opts: opts
  } do
    operation = sendable_bid(auction, wallet, opts)

    Chain.put(%{outcomes: %{bid: %{outcome: :unverified}}})
    operation = confirm_step(operation, :bid, @bid_hash, opts)

    assert operation.state == :unverified
    assert is_nil(operation.onchain_bid_id)
    assert operation.terminal_at
  end

  test "A_REVERT_IS_NEVER_SUCCESS: a canonical revert ends the operation", %{
    auction: auction,
    wallet: wallet,
    opts: opts
  } do
    operation = sendable_bid(auction, wallet, opts)

    Chain.put(%{outcomes: %{bid: %{outcome: :reverted}}})
    operation = confirm_step(operation, :bid, @bid_hash, opts)

    assert operation.state == :reverted
    assert operation.terminal_at
  end

  test "PENDING_WRITES_NOTHING: an unresolved hash stays bound and readable again", %{
    auction: auction,
    wallet: wallet,
    opts: opts
  } do
    operation = auction |> sendable_bid(wallet, opts) |> submitted(@bid_hash, opts)

    Chain.put(%{outcomes: %{}})
    {:ok, %{operation: pending}} = Autolaunch.verify_bid_step(operation.action_id, opts)

    assert pending.state == :submitted
    assert pending.bid_transaction_hash == @bid_hash
    assert is_nil(pending.terminal_at)

    Chain.put(%{outcomes: %{bid: %{outcome: :confirmed, onchain_bid_id: "7"}}})
    {:ok, %{operation: settled}} = Autolaunch.verify_bid_step(operation.action_id, opts)
    assert {settled.state, settled.onchain_bid_id} == {:confirmed, "7"}
  end

  test "NO_PROVIDER_READ_UNDER_A_LOCK: the bound hash is read before the lease transaction opens",
       %{auction: auction, wallet: wallet, opts: opts} do
    operation = submitted(review(auction, wallet, opts), @approval_hash, opts)

    Chain.put(%{outcomes: %{token_approval: %{outcome: :confirmed}}})

    assert {:ok, %{operation: settled}} = Autolaunch.verify_bid_step(operation.action_id, opts)
    assert {settled.step, settled.state} == {:permit2_approval, :prepared}
    refute Chain.state().read_in_transaction?
  end

  test "A_RECEIPT_NEVER_SETTLES_A_ROW_THAT_MOVED: a candidate raced mid-read applies nothing", %{
    auction: auction,
    wallet: wallet,
    opts: opts
  } do
    operation = submitted(review(auction, wallet, opts), @approval_hash, opts)

    Chain.put(%{
      outcomes: %{token_approval: %{outcome: :confirmed}},
      raced: fn -> Autolaunch.start_new_bid(operation.action_id, opts) end
    })

    assert {:ok, %{operation: unmoved}} = Autolaunch.verify_bid_step(operation.action_id, opts)
    assert {unmoved.step, unmoved.state} == {:token_approval, :submission_unknown}
    assert unmoved.token_approval_transaction_hash == @approval_hash
  end

  test "CLAIMED_STEPS_NEVER_RESEND: a duplicate hash replays and a different one is refused", %{
    auction: auction,
    wallet: wallet,
    opts: opts
  } do
    operation = review(auction, wallet, opts)
    {:ok, %{operation: operation}} = Autolaunch.claim_bid_dispatch(operation.action_id, opts)

    assert {:ok, %{operation: bound}} =
             Autolaunch.bind_bid_hash(operation.action_id, :token_approval, @approval_hash, opts)

    assert bound.state == :submitted

    assert {:ok, %{operation: replayed}} =
             Autolaunch.bind_bid_hash(
               operation.action_id,
               :token_approval,
               mixed_case(@approval_hash),
               opts
             )

    assert replayed.token_approval_transaction_hash == @approval_hash

    assert {:error, error} =
             Autolaunch.bind_bid_hash(operation.action_id, :token_approval, @other_hash, opts)

    assert refusal(error) == :submitted_hash_conflict

    # A claimed and submitted step is never offered a second dispatch.
    assert {:error, _claimed} = Autolaunch.claim_bid_dispatch(operation.action_id, opts)
  end

  test "A_LOST_CALLBACK_REPLAYS: a delayed hash binds to its own step and never a later one", %{
    auction: auction,
    wallet: wallet,
    opts: opts
  } do
    operation = confirm_step(review(auction, wallet, opts), :token_approval, @approval_hash, opts)
    assert {operation.step, operation.state} == {:permit2_approval, :prepared}

    # The browser replays the callback it never got an answer for. The row has
    # moved on, so the only column this hash can reach is its own, which already
    # holds it: the replay acknowledges and writes nothing.
    assert {:ok, %{operation: replayed}} =
             Autolaunch.bind_bid_hash(operation.action_id, :token_approval, @approval_hash, opts)

    assert {replayed.step, replayed.state} == {:permit2_approval, :prepared}
    assert replayed.token_approval_transaction_hash == @approval_hash
    assert is_nil(replayed.permit2_approval_transaction_hash)

    # A hash reported for a step this operation is not on reaches no column.
    assert {:error, error} =
             Autolaunch.bind_bid_hash(operation.action_id, :bid, @bid_hash, opts)

    assert refusal(error) == :submitted_step_mismatch
    assert {:ok, %{operation: %{bid_transaction_hash: nil}}} = Autolaunch.open_bid_operation(opts)
  end

  test "ONE_OPEN_BID_PER_ACCOUNT: a second prepare while one is claimed replaces it", %{
    auction: auction,
    wallet: wallet,
    opts: opts
  } do
    first = review(auction, wallet, opts)
    second = review(auction, wallet, opts)
    refute second.action_id == first.action_id

    {:ok, %{operation: claimed}} = Autolaunch.claim_bid_dispatch(second.action_id, opts)
    assert claimed.state == :dispatched

    assert {:ok, %{operation: third}} =
             Autolaunch.prepare_bid(auction.id, wallet, "1", "3", opts)

    refute third.action_id == claimed.action_id
    assert third.state == :prepared

    replaced = committed(claimed.action_id)
    assert replaced.reason == "replaced by a newer review"
    assert replaced.terminal_at
  end

  test "AN_UNKNOWN_CLAIM_NEVER_RESENDS: start-new-bid ends it without touching its calldata", %{
    auction: auction,
    wallet: wallet,
    opts: opts
  } do
    operation = review(auction, wallet, opts)
    {:ok, %{operation: claimed}} = Autolaunch.claim_bid_dispatch(operation.action_id, opts)

    {:ok, %{operation: ended}} = Autolaunch.start_new_bid(claimed.action_id, opts)
    assert ended.state == :submission_unknown
    assert ended.terminal_at
    assert ended.envelope == operation.envelope
    assert is_nil(ended.token_approval_transaction_hash)

    # The slot is released, so a new review is a new bid.
    assert {:ok, %{operation: fresh}} = Autolaunch.prepare_bid(auction.id, wallet, "1", "3", opts)
    refute fresh.action_id == operation.action_id
  end

  test "A_LATE_HASH_NEVER_REOPENS: it attaches to the operation it belongs to", %{
    auction: auction,
    wallet: wallet,
    opts: opts
  } do
    operation = review(auction, wallet, opts)
    {:ok, %{operation: claimed}} = Autolaunch.claim_bid_dispatch(operation.action_id, opts)
    {:ok, %{operation: ended}} = Autolaunch.start_new_bid(claimed.action_id, opts)

    assert {:ok, %{operation: attached}} =
             Autolaunch.bind_bid_hash(ended.action_id, :token_approval, @approval_hash, opts)

    assert attached.token_approval_transaction_hash == @approval_hash
    assert attached.state == :submission_unknown
    assert attached.terminal_at == ended.terminal_at

    # It attaches only to the step it was reported for, and never reopens it.
    assert {:error, error} = Autolaunch.bind_bid_hash(ended.action_id, :bid, @bid_hash, opts)
    assert refusal(error) == :submitted_step_mismatch
  end

  test "AN_EXPLICIT_REJECTION_ENDS_A_CLAIM: nothing was sent and nothing is bound", %{
    auction: auction,
    wallet: wallet,
    opts: opts
  } do
    operation = review(auction, wallet, opts)
    {:ok, %{operation: claimed}} = Autolaunch.claim_bid_dispatch(operation.action_id, opts)

    {:ok, %{operation: closed}} = Autolaunch.close_bid_not_sent(claimed.action_id, opts)
    assert closed.state == :not_sent
    assert closed.terminal_at
  end

  test "A_PROVEN_NON_START_RELEASES: the same review becomes sendable again", %{
    auction: auction,
    wallet: wallet,
    opts: opts
  } do
    operation = review(auction, wallet, opts)
    {:ok, %{operation: claimed}} = Autolaunch.claim_bid_dispatch(operation.action_id, opts)

    {:ok, %{operation: released}} =
      Autolaunch.release_unstarted_bid_dispatch(claimed.action_id, opts)

    assert released.state == :prepared

    assert {:ok, %{operation: %{state: :dispatched}}} =
             Autolaunch.claim_bid_dispatch(released.action_id, opts)
  end

  test "AN_UNDISPATCHED_REVIEW_MAY_BE_WITHDRAWN: a started one may not", %{
    auction: auction,
    wallet: wallet,
    opts: opts
  } do
    operation = review(auction, wallet, opts)
    {:ok, %{operation: cancelled}} = Autolaunch.cancel_bid_review(operation.action_id, opts)
    assert cancelled.state == :cancelled

    started = confirm_step(review(auction, wallet, opts), :token_approval, @approval_hash, opts)
    {:ok, %{operation: claimed}} = Autolaunch.claim_bid_dispatch(started.action_id, opts)
    assert {:error, _claimed} = Autolaunch.cancel_bid_review(claimed.action_id, opts)
  end

  test "A_STALE_REVIEW_NEVER_REACHES_THE_WALLET: the ten-minute envelope ends a part-done sequence",
       %{auction: auction, wallet: wallet, opts: opts} do
    operation = confirm_step(review(auction, wallet, opts), :token_approval, @approval_hash, opts)
    assert operation.step == :permit2_approval

    freeze(past(operation))

    assert {:ok, %{operation: %{state: :expired} = expired}} =
             Autolaunch.claim_bid_dispatch(operation.action_id, opts)

    assert expired.terminal_at
    assert expired.token_approval_transaction_hash == @approval_hash
    assert {:ok, %{operation: nil}} = Autolaunch.open_bid_operation(opts)

    assert {:ok, %{operation: fresh}} = Autolaunch.prepare_bid(auction.id, wallet, "1", "3", opts)
    refute fresh.action_id == operation.action_id
    assert fresh.state == :prepared
  end

  test "A_STALE_REVIEW_NEVER_REACHES_THE_WALLET: a lone bid on a long-lived allowance expires too",
       %{auction: auction, wallet: wallet, opts: opts} do
    amount = Integer.pow(10, 18)

    Chain.put(%{
      token_allowance: amount,
      permit2_amount: amount,
      permit2_expiration: Integer.pow(2, 48) - 1
    })

    operation = review(auction, wallet, opts)
    assert Enum.map(steps(operation), & &1["step"]) == ["bid"]

    freeze(past(operation))

    assert {:ok, %{operation: %{state: :expired, terminal_at: terminal_at}}} =
             Autolaunch.claim_bid_dispatch(operation.action_id, opts)

    assert terminal_at
  end

  test "RELOAD_RECOVERS_THE_ROW: browser storage restores nothing of its own", %{
    auction: auction,
    wallet: wallet,
    opts: opts
  } do
    operation = review(auction, wallet, opts)
    {:ok, %{operation: claimed}} = Autolaunch.claim_bid_dispatch(operation.action_id, opts)

    assert {:ok, %{operation: recovered}} = Autolaunch.open_bid_operation(opts)
    assert recovered.action_id == claimed.action_id
    assert recovered.state == :dispatched
    assert recovered.signer == wallet
  end

  test "REVOCATION_ENDS_EVERY_WRITE: a revoked lease claims, binds and settles nothing", %{
    auction: auction,
    wallet: wallet,
    opts: opts,
    account: account
  } do
    operation = review(auction, wallet, opts)
    assert SessionAuthority.revoke(%{lineage: opts[:context].session_lease.lineage})

    for refused <- [
          fn -> Autolaunch.claim_bid_dispatch(operation.action_id, opts) end,
          fn ->
            Autolaunch.bind_bid_hash(operation.action_id, :token_approval, @approval_hash, opts)
          end,
          fn -> Autolaunch.verify_bid_step(operation.action_id, opts) end,
          fn -> Autolaunch.cancel_bid_review(operation.action_id, opts) end,
          fn -> Autolaunch.prepare_bid(auction.id, wallet, "1", "3", opts) end
        ] do
      assert {:error, error} = refused.()
      assert refusal(error) == :session_unavailable
    end

    # The row the revoked session left is untouched and still that account's.
    {:ok, :bind, claim} = SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id)

    reauthenticated =
      Keyword.put(opts, :context, %{
        session_lease: %{lineage: claim.lineage, account_id: account.id}
      })

    assert {:ok, %{operation: %{state: :prepared, action_id: action_id}}} =
             Autolaunch.open_bid_operation(reauthenticated)

    assert action_id == operation.action_id
  end

  describe "second-connection barriers" do
    setup :clear_committed_bids

    test "BARRIER_AND_RESTART_PROOF: a logout that commits first leaves the bid write refused" do
      {lease, operation} = unboxed(&committed_review/0)
      claim = fn -> Autolaunch.claim_bid_dispatch(operation.action_id, barrier_opts(lease)) end

      unboxed(fn -> SessionAuthority.revoke(lease) end)

      assert {:error, error} = unboxed(claim)
      assert refusal(error) == :session_unavailable
      assert unboxed(fn -> committed(operation.action_id) end).state == :prepared
    end

    test "BARRIER_AND_RESTART_PROOF: a logout contending behind the write waits and does not undo it" do
      {lease, operation} = unboxed(&committed_review/0)
      claim = fn -> Autolaunch.claim_bid_dispatch(operation.action_id, barrier_opts(lease)) end

      writer = holding(claim)
      logout = contending(fn -> SessionAuthority.revoke(lease) end)

      assert_blocked_by(logout, writer)
      assert {:ok, %{operation: %{state: :dispatched}}} = release(writer)
      assert settled(logout)

      # The claim committed whole, and the lineage that ordered behind it can no
      # longer authorize the next step of the same operation.
      assert unboxed(fn -> committed(operation.action_id) end).state == :dispatched

      assert {:error, error} =
               unboxed(fn ->
                 Autolaunch.bind_bid_hash(
                   operation.action_id,
                   :token_approval,
                   @approval_hash,
                   barrier_opts(lease)
                 )
               end)

      assert refusal(error) == :session_unavailable
    end
  end

  ## Committed setup and barriers for the second-connection proofs

  defp committed_review do
    unique = Elixir.System.unique_integer([:positive])

    account =
      Accounts.register_verified!("did:privy:bid-barrier-#{unique}", wallet(), [wallet()],
        actor: system()
      )

    {:ok, :bind, claim} = SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id)
    lease = %{lineage: claim.lineage, account_id: account.id}
    auction = auction!("Barrier bid auction #{unique}")

    report = Autolaunch.TestAutolaunchTreasuryChainClient.seed_verified!(@barrier_treasury)
    Autolaunch.set_auction_treasury_security_report!(auction, report.id, actor: system())

    {:ok, %{operation: operation}} =
      Autolaunch.prepare_bid(auction.id, wallet(), "1", "3", barrier_opts(lease))

    {lease, operation}
  end

  defp barrier_opts(%{account_id: account_id} = lease),
    do: [actor: %Human{human_account_id: account_id}, context: %{session_lease: lease}]

  defp committed(action_id) do
    BidOperation
    |> Ash.Query.filter(action_id == ^action_id)
    |> Ash.read_one!(domain: Autolaunch, actor: system())
  end

  # Committed rows outlive the sandbox, so they are cleared for every test in
  # this block rather than only around the ones that mint them.
  defp clear_committed_bids(_context) do
    remove = fn ->
      # Ash is bypassed throughout this cleanup on purpose: it runs outside the sandbox
      # against rows that policies would hide, and the resources have no destroy actions.
      account_ids =
        Repo.all(
          from(account in Accounts.HumanAccount,
            where: like(account.privy_user_id, "did:privy:bid-barrier-%"),
            select: account.id
          )
        )

      Repo.delete_all(
        from(row in BidOperation,
          where: row.human_account_id in ^account_ids
        )
      )

      Repo.delete_all(from(row in SessionAuthority, where: row.human_account_id in ^account_ids))

      Repo.delete_all(
        from(auction in Auction,
          where: like(auction.title, "Barrier bid %")
        )
      )

      Repo.delete_all(
        from(report in TreasurySecurityReport,
          where: report.address == ^@barrier_treasury
        )
      )

      Repo.delete_all(
        from(account in Accounts.HumanAccount,
          where: like(account.privy_user_id, "did:privy:bid-barrier-%")
        )
      )
    end

    unboxed(remove)
    on_exit(fn -> unboxed(remove) end)
  end

  defp unboxed(attempt), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, attempt)

  defp holding(attempt) do
    test = self()
    task = Task.async(fn -> unboxed(fn -> hold(attempt, test) end) end)
    assert_receive {:holding, holder, backend}, 5_000
    {task, holder, backend}
  end

  defp release({task, holder, _backend}) do
    send(holder, :release)
    {:ok, result} = Task.await(task, 15_000)
    result
  end

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

  # PostgreSQL itself reports the ordering, so no sleep decides the race.
  defp assert_blocked_by({_rival, contender}, {_task, _holder, holder_backend}) do
    assert Enum.reduce_while(1..2_000, false, fn _attempt, _blocked ->
             if holder_backend in blocking_pids(contender),
               do: {:halt, true},
               else: {:cont, false}
           end),
           "the contender never blocked on the held authority row"
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

  defp hold(attempt, test) do
    Repo.transaction(fn ->
      result = attempt.()
      send(test, {:holding, self(), backend_pid()})

      receive do
        :release -> result
      after
        15_000 -> result
      end
    end)
  end

  defp review(auction, wallet, opts) do
    {:ok, %{operation: operation}} = Autolaunch.prepare_bid(auction.id, wallet, "1", "3", opts)
    operation
  end

  defp sendable_bid(auction, wallet, opts) do
    auction
    |> review(wallet, opts)
    |> confirm_step(:token_approval, @approval_hash, opts)
    |> confirm_step(:permit2_approval, @permit2_hash, opts)
  end

  defp confirm_step(operation, step, hash, opts) do
    Chain.put(%{outcomes: Map.put_new(Chain.state().outcomes, step, %{outcome: :confirmed})})
    submitted(operation, hash, opts)
    {:ok, %{operation: settled}} = Autolaunch.verify_bid_step(operation.action_id, opts)
    settled
  end

  defp submitted(operation, hash, opts) do
    {:ok, %{operation: claimed}} = Autolaunch.claim_bid_dispatch(operation.action_id, opts)

    {:ok, %{operation: bound}} =
      Autolaunch.bind_bid_hash(claimed.action_id, claimed.step, hash, opts)

    bound
  end

  defp steps(operation), do: operation.envelope["arguments"]["steps"]

  # One second past the deadline the reviewed envelope itself carries.
  defp past(%{envelope: envelope}) do
    {:ok, expires_at, _offset} = DateTime.from_iso8601(envelope["expires_at"])
    DateTime.add(expires_at, 1, :second)
  end

  defp freeze(instant) do
    previous = Application.get_env(:autolaunch, :wallet_action_clock)
    Application.put_env(:autolaunch, :wallet_action_clock, fn -> instant end)
    on_exit(fn -> restore(:wallet_action_clock, previous) end)
  end

  defp mixed_case("0x" <> hash), do: "0x" <> String.upcase(hash)

  defp restore(key, nil), do: Application.delete_env(:autolaunch, key)
  defp restore(key, value), do: Application.put_env(:autolaunch, key, value)
end
