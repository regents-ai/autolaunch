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
