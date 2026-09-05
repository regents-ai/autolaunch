defmodule Autolaunch.LaunchOperationTest do
  @moduledoc """
  The durable launch's own lifecycle: which step is sendable, what a fresh read
  is allowed to do to an undispatched review, which hash may bind, and what stays
  true after a reload or a terminal outcome.
  """

  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch
  alias Autolaunch.LaunchFixture, as: Fixture
  alias Autolaunch.LaunchOperations
  alias Autolaunch.TestAutolaunchLaunchChainClient, as: ChainClient
  alias Autolaunch.TestAutolaunchTreasuryChainClient, as: TreasuryClient

  @approval_hash "0x" <> String.duplicate("a1", 32)
  @launch_hash "0x" <> String.duplicate("b2", 32)
  @other_hash "0x" <> String.duplicate("c3", 32)
  @other_wallet "0x9999999999999999999999999999999999999999"

  @unit Integer.pow(10, 18)
  @fee 1_000_000 * @unit

  setup do
    Fixture.install()
    context = Fixture.actor()
    TreasuryClient.seed_verified!(Fixture.treasury())

    on_exit(fn ->
      Application.delete_env(:autolaunch, :autolaunch_treasury_chain_client)
      Application.delete_env(:autolaunch, :test_autolaunch_treasury_observation)
    end)

    context
  end

  describe "EXACTLY_ONE_SENDABLE_STEP: a step is claimed once and its hash is durable before the next" do
    test "the correction settles, the launch becomes sendable, and the whole launch verifies",
         context do
      {:ok, operation} = review(context)
      assert operation.step == :approval

      assert {:ok, %{operation: claimed}} = claim(context, operation)
      assert claimed.state == :dispatched

      assert {:ok, %{operation: bound}} = bind(context, operation, :approval, @approval_hash)
      assert bound.state == :submitted
      assert bound.approval_transaction_hash == @approval_hash

      # An approval only advances the sequence once its own event holds, and the
      # allowance it left behind is stored as corroboration beside it.
      ChainClient.put(%{
        outcomes: %{approval: %{outcome: :confirmed, result: %{"allowance" => "1000000"}}}
      })

      assert {:ok, %{operation: advanced}} = verify(context, operation)
      assert advanced.step == :launch
      assert advanced.state == :prepared
      assert advanced.approval_transaction_hash == @approval_hash
      assert advanced.result == %{"allowance" => "1000000"}

      # The launch step is only ever dispatched on an allowance that is exactly
      # the fee, which is what the correction has just made true.
      ChainClient.put(Fixture.fixture(allowance: @fee))
      assert {:ok, _claimed} = claim(context, operation)
      assert {:ok, %{operation: sent}} = bind(context, operation, :launch, @launch_hash)
      assert sent.state == :submitted

      ChainClient.put(%{outcomes: %{launch: %{outcome: :confirmed, result: launch_result()}}})
      assert {:ok, %{operation: verified}} = verify(context, operation)

      assert verified.state == :chain_verified
      assert verified.result["launch_id"] == "42"
      assert verified.result["subject"] == subject()
      # The corroboration the correction recorded is kept, not overwritten.
      assert verified.result["allowance"] == "1000000"
      assert verified.terminal_at
    end

    test "a hash reported for a step the row is not on cannot bind", context do
      {:ok, operation} = review(context)
      assert {:ok, _claimed} = claim(context, operation)

      assert {:error, error} = bind(context, operation, :launch, @launch_hash)
      assert Fixture.refusal(error) == :submitted_step_mismatch
    end

    test "a pending read writes nothing, so the same hash stays readable", context do
      {:ok, operation} = submitted_approval(context)

      ChainClient.put(%{outcomes: %{approval: %{outcome: :pending}}})
      assert {:ok, %{operation: unchanged}} = verify(context, operation)

      assert unchanged.state == :submitted
      assert unchanged.step == :approval
      assert unchanged.approval_transaction_hash == @approval_hash
    end

    test "a read that fails outright writes no verdict at all", context do
      {:ok, operation} = submitted_approval(context)

      ChainClient.put(%{outcomes: %{approval: {:error, :chain_unavailable}}})
      assert Fixture.refusal(verify(context, operation)) == :chain_unavailable

      assert {:ok, %{state: :submitted}} = stored(context, operation)
    end

    test "no provider read ever happens inside the lease transaction", context do
      {:ok, operation} = submitted_approval(context)

      ChainClient.put(%{outcomes: %{approval: %{outcome: :confirmed}}})
      assert {:ok, _advanced} = verify(context, operation)

      refute ChainClient.state().read_in_transaction?
      refute ChainClient.state().snapshot_read_in_transaction?
    end
  end

  describe "A_FRESH_READ_GATES_EVERY_DISPATCH: Base decides again before a wallet opens" do
    test "a noncanonical treasury header invalidates before the wallet can receive a dispatch",
         context do
      {:ok, operation} = review(context)
      TreasuryClient.install(canonical?: false)

      assert {:ok, %{operation: invalidated}} = claim(context, operation)
      assert invalidated.state == :invalidated
      assert invalidated.reason == "the treasury security state changed"
      assert invalidated.terminal_at
      assert is_nil(invalidated.approval_transaction_hash)
      assert {:ok, %{operation: nil}} = open(context)
    end

    test "a fee that moved after the review ends it rather than handing over its bytes",
         context do
      {:ok, operation} = review(context)

      ChainClient.put(Fixture.fixture(fee: 2_000_000 * @unit))
      assert {:ok, %{operation: invalidated}} = claim(context, operation)

      assert invalidated.state == :invalidated
      assert invalidated.reason == "the launch fee changed after this review"
      assert invalidated.terminal_at
      # Nothing was ever claimed, so nothing is sendable and the slot is free.
      assert {:ok, %{operation: nil}} = open(context)
    end

    test "a pause, a moved binding, a short balance and a moved allowance each end it",
         context do
      for {overrides, reason} <- [
            {[paused: true], "launches were paused after this review"},
            {[factory: @other_wallet], "the reviewed factory binding changed"},
            {[strategy: @other_wallet], "the reviewed factory binding changed"},
            {[strategy_factory: @other_wallet], "the reviewed factory binding changed"},
            {[balance: @fee - 1], "this wallet no longer holds the launch fee"},
            {[allowance: 1], "the REGENT allowance changed after this review"}
          ] do
        ChainClient.put(Fixture.fixture())
        {:ok, operation} = review(context)

        ChainClient.put(Fixture.fixture(overrides))
        assert {:ok, %{operation: ended}} = claim(context, operation)

        assert ended.state == :invalidated
        assert ended.reason == reason
      end
    end

    # A launch is only ever handed over on an allowance that is exactly the fee.
    # `allowance >= fee` would let a residue through, and the factory refuses one.
    test "a launch step whose allowance is not exactly the fee is never dispatched", context do
      ChainClient.put(Fixture.fixture(allowance: @fee))
      {:ok, operation} = review(context)
      assert operation.step == :launch

      ChainClient.put(Fixture.fixture(allowance: @fee + 1))
      assert {:ok, %{operation: ended}} = claim(context, operation)
      assert ended.state == :invalidated
    end

    test "a review Base still agrees with dispatches normally", context do
      ChainClient.put(Fixture.fixture(allowance: @fee))
      {:ok, operation} = review(context)

      assert {:ok, %{operation: claimed}} = claim(context, operation)
      assert claimed.state == :dispatched
    end
  end

  describe "REVIEW_IS_BOUND_TO_ITS_SIGNER: a wallet switch cannot retarget anything" do
    test "another wallet cannot dispatch a review prepared for this signer", context do
      {:ok, operation} = review(context)

      assert Fixture.refusal(
               Autolaunch.claim_launch_dispatch(operation.action_id, @other_wallet, opts(context))
             ) == :wrong_signer

      assert {:ok, %{state: :prepared}} = stored(context, operation)
    end

    test "an in-flight launch stays bound to the wallet it was reviewed for", context do
      {:ok, operation} = submitted_approval(context)

      assert {:error, _refused} =
               Autolaunch.claim_launch_dispatch(operation.action_id, @other_wallet, opts(context))

      assert {:ok, %{state: :submitted, signer: signer}} = stored(context, operation)
      assert signer == Fixture.wallet()
    end
  end

  describe "ONE_OPEN_LAUNCH_PER_ACCOUNT: a new prepare replaces whatever is open" do
    test "a second prepare while one is claimed cancels the first as replaced", context do
      {:ok, first} = review(context)
      {:ok, second} = review(context)
      refute first.action_id == second.action_id

      assert {:ok, %{operation: claimed}} = claim(context, second)
      assert {:ok, third} = review(context)
      refute third.action_id == claimed.action_id
      assert third.state == :prepared

      assert {:ok, replaced} = stored(context, claimed)
      assert replaced.reason == "replaced by a newer review"
      assert replaced.terminal_at
    end

    test "ending an unresolved launch releases the slot without resending anything", context do
      {:ok, operation} = submitted_approval(context)

      assert {:ok, %{operation: closed}} =
               Autolaunch.start_new_launch(operation.action_id, opts(context))

      assert closed.state == :submission_unknown
      assert closed.approval_transaction_hash == @approval_hash
      assert {:ok, %{operation: nil}} = open(context)
      assert {:ok, _fresh} = review(context)
    end

    test "another account's open launch is completely independent", context do
      {:ok, held} = review(context)
      assert {:ok, _claimed} = claim(context, held)

      other = Fixture.actor()

      assert {:ok, %{operation: %{state: :prepared}}} =
               Autolaunch.prepare_launch(other[:draft].id, Fixture.wallet(), other[:opts])
    end
  end

  describe "A_RELOAD_RESTORES_THE_ROW: recovery is a server fact, never a browser one" do
    test "the current lease recovers the exact operation and both bound hashes", context do
      {:ok, operation} = submitted_approval(context)

      ChainClient.put(%{outcomes: %{approval: %{outcome: :confirmed}}})
      assert {:ok, _advanced} = verify(context, operation)

      ChainClient.put(Fixture.fixture(allowance: @fee))
      assert {:ok, _claimed} = claim(context, operation)
      assert {:ok, _bound} = bind(context, operation, :launch, @launch_hash)

      assert {:ok, %{operation: recovered}} = open(context)
      assert recovered.action_id == operation.action_id
      assert recovered.approval_transaction_hash == @approval_hash
      assert recovered.launch_transaction_hash == @launch_hash
      assert recovered.step == :launch
      assert recovered.state == :submitted
    end

    test "an exact replay is a no-op while a different hash conflicts", context do
      {:ok, operation} = submitted_approval(context)

      assert {:ok, %{operation: replayed}} = bind(context, operation, :approval, @approval_hash)
      assert replayed.approval_transaction_hash == @approval_hash

      assert Fixture.refusal(bind(context, operation, :approval, @other_hash)) ==
               :submitted_hash_conflict
    end

    test "a hash already bound by another launch can never be reused", context do
      {:ok, first} = submitted_approval(context)
      assert {:ok, _closed} = Autolaunch.start_new_launch(first.action_id, opts(context))

      {:ok, second} = review(context)
      assert {:ok, _claimed} = claim(context, second)
      assert {:error, _conflict} = bind(context, second, :approval, @approval_hash)
    end
  end

  describe "TERMINAL_STAYS_TERMINAL: nothing reopens a finished launch" do
    test "a revert and a contradiction are both terminal and never resent", context do
      for {outcome, hash} <- [{:reverted, @approval_hash}, {:unverified, @other_hash}] do
        ChainClient.put(Fixture.fixture())
        {:ok, operation} = submitted_approval(context, hash)
        ChainClient.put(%{outcomes: %{approval: %{outcome: outcome}}})

        assert {:ok, %{operation: settled}} = verify(context, operation)
        assert settled.state == outcome
        assert settled.terminal_at

        # A terminal row is never claimable again, whatever the browser asks.
        assert {:error, _refused} = claim(context, operation)
      end
    end

    test "a late hash attaches without reopening a terminal launch", context do
      {:ok, operation} = submitted_approval(context)

      ChainClient.put(%{outcomes: %{approval: %{outcome: :reverted}}})
      assert {:ok, %{operation: reverted}} = verify(context, operation)
      assert reverted.state == :reverted

      assert {:ok, %{operation: replayed}} = bind(context, operation, :approval, @approval_hash)
      assert replayed.state == :reverted
      assert replayed.terminal_at == reverted.terminal_at
    end

    test "an explicit wallet rejection ends a claimed step that never sent", context do
      {:ok, operation} = review(context)
      assert {:ok, _claimed} = claim(context, operation)

      assert {:ok, %{operation: closed}} =
               Autolaunch.close_launch_not_sent(operation.action_id, opts(context))

      assert closed.state == :not_sent
      assert closed.terminal_at
      assert is_nil(closed.approval_transaction_hash)
    end

    test "a claim the browser never started is released and stays sendable", context do
      {:ok, operation} = review(context)
      assert {:ok, _claimed} = claim(context, operation)

      assert {:ok, %{operation: released}} =
               Autolaunch.release_unstarted_launch_dispatch(operation.action_id, opts(context))

      assert released.state == :prepared
      assert is_nil(released.terminal_at)
      assert {:ok, %{operation: %{state: :dispatched}}} = claim(context, operation)
    end

    test "a review nobody dispatched expires once its own window closes", context do
      {:ok, operation} = review(context)

      elapsed = fn -> DateTime.add(DateTime.utc_now(), 3_600, :second) end
      Application.put_env(:autolaunch, :wallet_action_clock, elapsed)
      on_exit(fn -> Application.delete_env(:autolaunch, :wallet_action_clock) end)

      assert {:ok, %{operation: expired}} = claim(context, operation)
      assert expired.state == :expired
      assert expired.reason == "the reviewed launch expired before it was sent"
    end
  end

  # Helpers

  defp review(context) do
    with {:ok, %{operation: operation}} <-
           Autolaunch.prepare_launch(context[:draft].id, Fixture.wallet(), opts(context)),
         do: {:ok, operation}
  end

  defp claim(context, operation),
    do: Autolaunch.claim_launch_dispatch(operation.action_id, Fixture.wallet(), opts(context))

  defp bind(context, operation, step, hash),
    do: Autolaunch.bind_launch_hash(operation.action_id, step, hash, opts(context))

  defp verify(context, operation),
    do: Autolaunch.verify_launch_step(operation.action_id, opts(context))

  defp open(context), do: Autolaunch.open_launch_operation(opts(context))

  defp stored(context, operation),
    do: LaunchOperations.fetch(context[:account].id, operation.action_id, false)

  defp submitted_approval(context, hash \\ @approval_hash) do
    {:ok, operation} = review(context)
    {:ok, _claimed} = claim(context, operation)
    {:ok, _bound} = bind(context, operation, :approval, hash)
    {:ok, operation}
  end

  defp opts(context), do: context[:opts]

  defp subject, do: "0x4444444444444444444444444444444444444444"

  defp launch_result do
    %{
      "launch_id" => "42",
      "subject" => subject(),
      "auction" => "0x2222222222222222222222222222222222222222",
      "escrow" => "0x3333333333333333333333333333333333333333",
      "start_block" => "30001800",
      "end_block" => "30088201"
    }
  end
end
