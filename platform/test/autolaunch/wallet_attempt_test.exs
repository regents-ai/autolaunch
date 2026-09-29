defmodule Autolaunch.WalletAttemptTest do
  use AutolaunchWeb.ConnCase, async: false
  require Ash.Query
  alias Autolaunch.WalletAttempt
  alias Autolaunch.TestAutolaunchBidChainClient, as: Chain
  alias Autolaunch.BidFixture, as: Bid
  @hash "0x" <> String.duplicate("a1", 32)
  @other "0x" <> String.duplicate("b2", 32)

  setup do
    Bid.install(
      token_allowance: 100 * Integer.pow(10, 18),
      permit2_amount: 100 * Integer.pow(10, 18),
      permit2_expiration: Integer.pow(2, 48) - 1
    )

    {:ok, context} = Bid.bidder()
    auction = context[:auction]

    report =
      Autolaunch.TestAutolaunchTreasuryChainClient.seed_verified!(
        "0x9999999999999999999999999999999999999999"
      )

    Autolaunch.set_auction_treasury_security_report!(auction, report.id, actor: Bid.system())

    on_exit(fn ->
      Application.delete_env(:autolaunch, :autolaunch_treasury_chain_client)
      Application.delete_env(:autolaunch, :test_autolaunch_treasury_observation)
    end)

    context
  end

  test "distinct pending presses preserve two hashes and two canonical bid IDs after parent closes",
       ctx do
    op = review(ctx)
    a = press(ctx, op)
    b = press(ctx, op)
    assert a.id != b.id

    assert {:ok, %{dispatch?: false}} =
             Autolaunch.dispatch_wallet_press(
               :bid,
               op.action_id,
               :bid,
               a.id,
               ctx.wallet,
               ctx.opts
             )

    bind(ctx, op, a, @hash)
    bind(ctx, op, b, @other)
    Chain.put(%{outcomes: %{bid: %{outcome: :confirmed, onchain_bid_id: "41"}}})

    assert {:ok, %{attempt: %{state: :confirmed}, operation: %{onchain_bid_id: "41"}}} =
             verify(ctx, op, a)

    Chain.put(%{outcomes: %{bid: %{outcome: :confirmed, onchain_bid_id: "42"}}})

    assert {:ok,
            %{attempt: %{result: %{"onchain_bid_id" => "42"}}, operation: %{onchain_bid_id: "41"}}} =
             verify(ctx, op, b)

    assert {:ok, %{operation: %{attempts: attempts}}} =
             Autolaunch.wallet_presses(:bid, op.action_id, ctx.opts)

    assert MapSet.new(Enum.map(attempts, & &1.transaction_hash)) == MapSet.new([@hash, @other])
    refute Chain.state().read_in_transaction?
  end

  test "late A after new B and withdrawal ingests and verifies only A", ctx do
    old = review(ctx)
    a = press(ctx, old)
    current = review(ctx)
    b = press(ctx, current)
    bind(ctx, old, a, @hash)

    assert {:ok, _} =
             Autolaunch.report_wallet_press(
               :bid,
               current.action_id,
               b.id,
               %{"outcome" => "not_sent"},
               ctx.opts
             )

    Chain.put(%{outcomes: %{bid: %{outcome: :confirmed, onchain_bid_id: "7"}}})
    assert {:ok, %{attempt: %{state: :confirmed}}} = verify(ctx, old, a)

    assert {:ok, %{operation: %{action_id: id, attempts: [%{state: :not_sent}]}}} =
             Autolaunch.wallet_presses(:bid, current.action_id, ctx.opts)

    assert id == current.action_id
    assert {:ok, %{operation: %{action_id: ^id}}} = Autolaunch.open_bid_operation(ctx.opts)
  end

  test "rejection, uncertainty and duplicate hash reports never overwrite a sibling success",
       ctx do
    op = review(ctx)
    a = press(ctx, op)
    b = press(ctx, op)
    bind(ctx, op, a, @hash)

    assert {:error, _} =
             Autolaunch.report_wallet_press(
               :bid,
               op.action_id,
               a.id,
               %{"transaction_hash" => @other},
               ctx.opts
             )

    assert {:ok, _} =
             Autolaunch.report_wallet_press(
               :bid,
               op.action_id,
               b.id,
               %{"outcome" => "submission_unknown"},
               ctx.opts
             )

    Chain.put(%{outcomes: %{bid: %{outcome: :confirmed, onchain_bid_id: "8"}}})
    verify(ctx, op, a)

    assert {:ok, %{operation: %{state: :confirmed}, attempt: %{state: :not_sent}}} =
             Autolaunch.report_wallet_press(
               :bid,
               op.action_id,
               b.id,
               %{"outcome" => "not_sent"},
               ctx.opts
             )

    # A genuine late hash is retained even after a browser's rejection report.
    bind(ctx, op, b, @other)
    Chain.put(%{outcomes: %{bid: %{outcome: :reverted}}})

    assert {:ok, %{operation: %{state: :confirmed}, attempt: %{state: :reverted}}} =
             verify(ctx, op, b)
  end

  test "revoked/mismatched lease and foreign account cannot read or mutate a press", ctx do
    op = review(ctx)
    a = press(ctx, op)
    {:ok, other} = Bid.bidder()
    assert {:error, _} = Autolaunch.wallet_presses(:bid, op.action_id, other[:opts])

    assert {:error, _} =
             Autolaunch.report_wallet_press(
               :bid,
               op.action_id,
               a.id,
               %{"transaction_hash" => @hash},
               other[:opts]
             )

    assert {:error, _} =
             Autolaunch.wallet_presses(
               :bid,
               op.action_id,
               Keyword.put(ctx.opts, :actor, other[:actor])
             )

    assert {:ok, %{operation: %{attempts: [%{transaction_hash: nil}]}}} =
             Autolaunch.wallet_presses(:bid, op.action_id, ctx.opts)

    assert {:error, _} = Ash.read(WalletAttempt, actor: ctx.actor)
  end

  test "SQL requires exactly one parent and the parent's own step language", ctx do
    op = review(ctx)
    a = press(ctx, op)

    assert_raise Postgrex.Error, fn ->
      Autolaunch.Repo.query!("UPDATE wallet_attempts SET step = 'launch' WHERE id = $1", [
        Ecto.UUID.dump!(a.id)
      ])
    end
  end

  test "expiry blocks a new press but cannot swallow an issued hash or receipt", ctx do
    now = Autolaunch.Chain.Envelope.current_time()
    op = review(ctx)
    a = press(ctx, op)
    previous = Application.get_env(:autolaunch, :wallet_action_clock)
    # The envelope clock fixture is inspected in the existing operation tests;
    # advance via that clock rather than rewriting signed review bytes.
    Application.put_env(:autolaunch, :wallet_action_clock, fn ->
      DateTime.add(now, 601, :second)
    end)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:autolaunch, :wallet_action_clock, previous),
        else: Application.delete_env(:autolaunch, :wallet_action_clock)
    end)

    assert {:error, _} =
             Autolaunch.dispatch_wallet_press(
               :bid,
               op.action_id,
               :bid,
               Ecto.UUID.generate(),
               ctx.wallet,
               ctx.opts
             )

    bind(ctx, op, a, @hash)
    Chain.put(%{outcomes: %{bid: %{outcome: :confirmed, onchain_bid_id: "9"}}})
    assert {:ok, %{attempt: %{state: :confirmed}}} = verify(ctx, op, a)
  end

  test "additive migration backfills every legacy hash and unresolved step without rewriting parents",
       ctx do
    op = review(ctx)
    {:ok, _} = Autolaunch.claim_bid_dispatch(op.action_id, ctx.opts)
    {:ok, _} = Autolaunch.bind_bid_hash(op.action_id, :bid, @hash, ctx.opts)
    # Fixture-only historical per-step observations. No new press is invented.
    Autolaunch.Repo.query!(
      "UPDATE bid_operations SET token_approval_transaction_hash = $1, permit2_approval_transaction_hash = $2 WHERE action_id = $3",
      [@other, "0x" <> String.duplicate("c3", 32), op.action_id]
    )

    Autolaunch.LaunchFixture.install()
    launch = Autolaunch.LaunchFixture.actor()

    Autolaunch.TestAutolaunchTreasuryChainClient.seed_verified!(
      Autolaunch.LaunchFixture.treasury()
    )

    {:ok, %{operation: launch_op}} =
      Autolaunch.prepare_launch(
        launch[:draft].id,
        Autolaunch.LaunchFixture.wallet(),
        launch[:opts]
      )

    {:ok, _} =
      Autolaunch.claim_launch_dispatch(
        launch_op.action_id,
        Autolaunch.LaunchFixture.wallet(),
        launch[:opts]
      )

    {:ok, _} = Autolaunch.bind_launch_hash(launch_op.action_id, :approval, @hash, launch[:opts])

    Autolaunch.Repo.query!(
      "UPDATE launch_operations SET launch_transaction_hash = $1 WHERE action_id = $2",
      [@other, launch_op.action_id]
    )

    Autolaunch.SubjectWalletFixture.install()
    subject = Autolaunch.SubjectWalletFixture.actor()

    {:ok, %{operation: subject_op}} =
      Autolaunch.prepare_subject_wallet_action(
        subject[:subject].subject_id,
        Autolaunch.SubjectWalletFixture.wallet(),
        :stake,
        %{"amount" => "10"},
        subject[:opts]
      )

    {:ok, _} =
      Autolaunch.claim_subject_wallet_dispatch(
        subject_op.subject_id,
        subject_op.action_id,
        Autolaunch.SubjectWalletFixture.wallet(),
        subject[:opts]
      )

    parents = fn ->
      for table <- ["bid_operations", "launch_operations", "subject_wallet_operations"],
          do: Autolaunch.Repo.query!("SELECT to_jsonb(t) FROM #{table} t ORDER BY id").rows
    end

    before = parents.()
    # Execute the actual migration's backfill statements, not a second SQL
    # implementation of them; DDL was already exercised by isolated ash.setup.
    migration =
      "priv/repo/migrations/20260907175423_wallet_attempts.exs"
      |> File.read!()
      |> Code.string_to_quoted!()

    {_, statements} =
      Macro.prewalk(migration, [], fn
        {:execute, _, [sql]} = node, acc when is_binary(sql) -> {node, [sql | acc]}
        node, acc -> {node, acc}
      end)

    Enum.each(statements, &Autolaunch.Repo.query!/1)
    attempts = Ash.read!(WalletAttempt, actor: Bid.system())
    assert length(attempts) == 6
    assert Enum.count(attempts, &(&1.state == :submitted)) == 5
    assert [unresolved] = Enum.filter(attempts, &(&1.state == :submission_unknown))
    assert unresolved.step == :approval
    assert unresolved.transaction_hash == nil
    assert unresolved.resolved_at == nil
    assert Enum.all?(attempts, &(&1.legacy and &1.evidence["dispatch_time"] == "unknown"))
    assert parents.() == before
    Enum.each(statements, &Autolaunch.Repo.query!/1)

    assert Ash.read!(WalletAttempt, actor: Bid.system()) |> Enum.sort_by(& &1.id) ==
             Enum.sort_by(attempts, & &1.id)

    assert parents.() == before
    # Old recovery chooses its one explicit legacy step, never a newer press.
    assert {:ok, %{attempt: %{id: id}}} =
             Autolaunch.WalletAttempts.report_legacy(
               :subject,
               subject_op.action_id,
               :approval,
               @other,
               subject[:opts]
             )

    assert id == unresolved.id
  end

  test "revocation during receipt IO prevents settlement under stale authority", ctx do
    op = review(ctx)
    a = press(ctx, op)

    assert {:error, _} =
             Autolaunch.report_wallet_press(
               :bid,
               op.action_id,
               a.id,
               %{"step" => "token_approval", "transaction_hash" => @hash},
               ctx.opts
             )

    bind(ctx, op, a, @hash)
    lease = ctx.opts[:context][:session_lease]

    Chain.put(%{
      outcomes: %{bid: %{outcome: :confirmed, onchain_bid_id: "99"}},
      raced: fn ->
        Autolaunch.Accounts.SessionAuthority.revoke(%{lineage: lease.lineage, generation: 0})
      end
    })

    assert {:error, _} = verify(ctx, op, a)
    [attempt] = Ash.read!(WalletAttempt, actor: Bid.system())
    assert attempt.state == :submitted
    assert attempt.result == %{}
    assert {:error, _} = Autolaunch.wallet_presses(:bid, op.action_id, ctx.opts)

    assert {:error, _} =
             Autolaunch.report_wallet_press(
               :bid,
               op.action_id,
               a.id,
               %{"transaction_hash" => @hash},
               ctx.opts
             )
  end

  defp review(ctx) do
    {:ok, %{operation: op}} =
      Autolaunch.prepare_bid(ctx.auction.id, ctx.wallet, "10", "3", ctx.opts)

    op
  end

  defp press(ctx, op) do
    {:ok, %{attempt: attempt, dispatch?: true}} =
      Autolaunch.dispatch_wallet_press(
        :bid,
        op.action_id,
        op.step,
        Ecto.UUID.generate(),
        ctx.wallet,
        ctx.opts
      )

    attempt
  end

  defp bind(ctx, op, attempt, hash) do
    assert {:ok, _} =
             Autolaunch.report_wallet_press(
               :bid,
               op.action_id,
               attempt.id,
               %{"transaction_hash" => hash},
               ctx.opts
             )
  end

  defp verify(ctx, op, attempt),
    do: Autolaunch.verify_wallet_press(:bid, op.action_id, attempt.id, ctx.opts)
end
