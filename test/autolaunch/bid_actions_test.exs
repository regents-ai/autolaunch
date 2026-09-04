defmodule Autolaunch.BidActionsTest do
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture

  alias Autolaunch
  alias Autolaunch.Chain.{Abi, Permit2Abi}

  @q96 79_228_162_514_264_337_593_543_950_336
  @other "0x2222222222222222222222222222222222222222"

  setup :bidder
  setup :verified_treasury

  test "PRODUCTION_STAYS_CLOSED: preparation is unavailable with no bounded predecessor source",
       %{auction: auction, wallet: wallet, opts: opts} do
    Application.delete_env(:autolaunch, :autolaunch_bid_chain_client)

    assert {:error, error} = Autolaunch.prepare_bid(auction.id, wallet, "12.5", "3", opts)
    assert refusal(error) == :bid_preparation_unavailable

    assert {:error, error} = Autolaunch.bid_position(auction.id, wallet, opts)
    assert refusal(error) == :bid_preparation_unavailable
  end

  test "PRODUCTION_STAYS_CLOSED: an unnamed or unreachable predecessor refuses instead of raising",
       %{auction: auction, wallet: wallet, opts: opts} do
    for unusable <- [
          [prev_tick_price_q96: nil],
          [prev_tick_price_q96: "2"],
          [prev_tick_price_q96: -1],
          [prev_tick_price_q96: Integer.pow(2, 256)],
          # The predecessor has to sit below the price this bid is reviewed at.
          [prev_tick_price_q96: 3 * @q96],
          [predecessor_source: ""],
          [predecessor_source: nil]
        ] do
      install(unusable)

      assert {:error, error} = Autolaunch.prepare_bid(auction.id, wallet, "12.5", "3", opts)
      assert refusal(error) == :bid_preparation_unavailable
    end
  end

  test "EXACT_STANDARD_SEQUENCE: one snapshot yields approve, Permit2 allowance, then the five-argument bid",
       %{auction: auction, wallet: wallet, opts: opts, regent: regent} do
    install(token_allowance: 0, permit2_amount: 0, permit2_expiration: 0)

    assert {:ok, %{operation: operation}} =
             Autolaunch.prepare_bid(auction.id, wallet, "12.5", "3", opts)

    arguments = operation.envelope["arguments"]
    amount = 12_500_000_000_000_000_000

    assert Enum.map(arguments["steps"], & &1["step"]) ==
             ~w(token_approval permit2_approval bid)

    [approve, permit2, bid] = arguments["steps"]

    assert approve["to"] == regent
    assert approve["data"] == Abi.encode_erc20("approve", [Permit2Abi.address(), amount])

    assert permit2["to"] == Permit2Abi.address()

    assert permit2["data"] ==
             Permit2Abi.encode_approve(
               regent,
               auction_address(),
               amount,
               String.to_integer(permit2["expiration"])
             )

    assert bid["to"] == auction_address()
    assert bid["data"] == operation.envelope["data"]
    assert String.starts_with?(bid["data"], "0xa52c8728")

    # maxPriceQ96, amount, owner, prevTickPriceQ96, then the offset of an empty
    # hookData past the five-word head and its zero length.
    assert byte_size(bid["data"]) == 10 + 6 * 64
    assert String.ends_with?(bid["data"], word(160) <> word(0))

    assert arguments["amount_atomic"] == Integer.to_string(amount)
    assert arguments["max_price_q96"] == Integer.to_string(3 * @q96)
    assert arguments["prev_tick_price_q96"] == Integer.to_string(2 * @q96)
    assert arguments["predecessor_source"] == "fixture"
    assert arguments["currency"] == regent
    assert operation.envelope["value"] == "0"
    assert operation.envelope["chain_id"] == 8453
    assert operation.step == :token_approval
  end

  test "EXACT_STANDARD_SEQUENCE: an allowance that already covers the review is not asked for again",
       %{auction: auction, wallet: wallet, opts: opts} do
    amount = 12_500_000_000_000_000_000

    install(
      token_allowance: amount,
      permit2_amount: amount,
      permit2_expiration: DateTime.to_unix(DateTime.utc_now()) + 3_600
    )

    assert {:ok, %{operation: operation}} =
             Autolaunch.prepare_bid(auction.id, wallet, "12.5", "3", opts)

    assert Enum.map(operation.envelope["arguments"]["steps"], & &1["step"]) == ["bid"]
    assert operation.step == :bid
  end

  test "EXACT_STANDARD_SEQUENCE: a canonical uint48 maximum expiration is an ordinary allowance",
       %{auction: auction, wallet: wallet, opts: opts} do
    amount = 12_500_000_000_000_000_000

    install(
      token_allowance: amount,
      permit2_amount: amount,
      permit2_expiration: Integer.pow(2, 48) - 1
    )

    assert {:ok, %{operation: operation}} =
             Autolaunch.prepare_bid(auction.id, wallet, "12.5", "3", opts)

    assert Enum.map(operation.envelope["arguments"]["steps"], & &1["step"]) == ["bid"]
  end

  test "EXACT_STANDARD_SEQUENCE: a Permit2 allowance lapsing inside the review is granted again",
       %{auction: auction, wallet: wallet, opts: opts} do
    amount = 12_500_000_000_000_000_000

    install(
      token_allowance: amount,
      permit2_amount: amount,
      permit2_expiration: DateTime.to_unix(DateTime.utc_now()) + 60
    )

    assert {:ok, %{operation: operation}} =
             Autolaunch.prepare_bid(auction.id, wallet, "12.5", "3", opts)

    assert Enum.map(operation.envelope["arguments"]["steps"], & &1["step"]) ==
             ~w(permit2_approval bid)
  end

  test "BOUND_REGENT_CURRENCY: an auction raising anything else can neither be read nor bid on",
       %{auction: auction, wallet: wallet, opts: opts} do
    install(currency: @other)

    assert {:error, error} = Autolaunch.prepare_bid(auction.id, wallet, "12.5", "3", opts)
    assert refusal(error) == :auction_currency_is_not_regent

    assert {:error, error} = Autolaunch.bid_position(auction.id, wallet, opts)
    assert refusal(error) == :auction_currency_is_not_regent
  end

  test "ACTIVE_WALLET_IS_THE_SIGNER: an unlinked wallet exposes nothing and prepares nothing", %{
    auction: auction,
    opts: opts
  } do
    install()

    assert {:error, error} = Autolaunch.bid_position(auction.id, @other, opts)
    assert refusal(error) == :wrong_signer

    assert {:error, error} = Autolaunch.prepare_bid(auction.id, @other, "1", "3", opts)
    assert refusal(error) == :wrong_signer
  end

  test "TREASURY_DRIFT_ENDS_THE_REVIEW_BEFORE_ANY_APPROVAL_OR_BID_DISPATCH", %{
    auction: auction,
    wallet: wallet,
    opts: opts
  } do
    install()

    assert {:ok, %{operation: operation}} =
             Autolaunch.prepare_bid(auction.id, wallet, "1", "3", opts)

    Autolaunch.TestAutolaunchTreasuryChainClient.install(
      block_number: 30_000_001,
      block_hash: "0x" <> String.duplicate("ef", 32),
      threshold: 1
    )

    assert {:ok, %{operation: ended}} =
             Autolaunch.claim_bid_dispatch(operation.action_id, opts)

    assert ended.state == :cancelled
    assert ended.terminal_at
  end

  test "A_NONCANONICAL_TREASURY_HEADER_CANCELS_BEFORE_ANY_WALLET_DISPATCH", %{
    auction: auction,
    wallet: wallet,
    opts: opts
  } do
    install()

    assert {:ok, %{operation: operation}} =
             Autolaunch.prepare_bid(auction.id, wallet, "1", "3", opts)

    Autolaunch.TestAutolaunchTreasuryChainClient.install(canonical?: false)

    assert {:ok, %{operation: cancelled}} =
             Autolaunch.claim_bid_dispatch(operation.action_id, opts)

    assert cancelled.state == :cancelled
    assert cancelled.terminal_at
    assert is_nil(cancelled.token_approval_transaction_hash)
  end

  test "A_RESTORED_SAFE_REMAINS_PERMANENTLY_DOWNGRADED_BEFORE_BID_ADMISSION", %{
    auction: auction,
    wallet: wallet,
    opts: opts
  } do
    install()
    treasury = "0x9999999999999999999999999999999999999999"

    Autolaunch.TestAutolaunchTreasuryChainClient.install(
      block_number: 30_000_001,
      block_hash: "0x" <> String.duplicate("ef", 32),
      threshold: 1
    )

    assert {:ok, _changed} =
             Autolaunch.observe_treasury_security(treasury, %{}, actor: system())

    restored =
      Autolaunch.TestAutolaunchTreasuryChainClient.seed_verified!(treasury,
        block_number: 30_000_002,
        block_hash: "0x" <> String.duplicate("ee", 32)
      )

    Autolaunch.set_auction_treasury_security_report!(auction, restored.id, actor: system())

    assert restored.downgrade_state == :downgraded

    assert {:error, _refused} = Autolaunch.prepare_bid(auction.id, wallet, "1", "3", opts)
    assert {:ok, %{operation: nil}} = Autolaunch.open_bid_operation(opts)
  end

  test "ACTIVE_WALLET_IS_THE_SIGNER: a socket with no session lease cannot prepare", %{
    auction: auction,
    wallet: wallet,
    actor: actor
  } do
    install()

    assert {:error, error} =
             Autolaunch.prepare_bid(auction.id, wallet, "1", "3", actor: actor)

    assert refusal(error) == :session_lease_required
  end

  test "EXACT_AMOUNTS_AND_PRICES: only exact eighteen-decimal amounts and positive prices review",
       %{auction: auction, wallet: wallet, opts: opts} do
    install(prev_tick_price_q96: div(@q96, 4))

    for invalid <- ["0", "-1", "garbage", "1e3", "1.", ".5", "1.0000000000000000001"] do
      assert {:error, error} = Autolaunch.prepare_bid(auction.id, wallet, invalid, "3", opts)
      assert refusal(error) == :invalid_amount
    end

    for invalid <- ["0", "-1", "garbage", "1e3"] do
      assert {:error, error} = Autolaunch.prepare_bid(auction.id, wallet, "1", invalid, opts)
      assert refusal(error) == :invalid_decimal
    end

    # An empty field is refused by the action's own required argument, before
    # any amount language is consulted.
    assert {:error, _required} = Autolaunch.prepare_bid(auction.id, wallet, "", "3", opts)
    assert {:error, _required} = Autolaunch.prepare_bid(auction.id, wallet, "1", "", opts)

    assert {:ok, %{operation: half}} =
             Autolaunch.prepare_bid(auction.id, wallet, "1", "0.5", opts)

    assert half.envelope["arguments"]["max_price_q96"] == Integer.to_string(div(@q96, 2))

    assert {:error, error} =
             Autolaunch.prepare_bid(auction.id, wallet, "1", tiny_price(), opts)

    assert refusal(error) == :invalid_price
  end

  test "AFFORDABLE_ONLY: an amount above the active wallet's REGENT never reviews", %{
    auction: auction,
    wallet: wallet,
    opts: opts
  } do
    install(regent_balance: 1_000_000_000_000_000_000)

    assert {:error, error} = Autolaunch.prepare_bid(auction.id, wallet, "2", "3", opts)
    assert refusal(error) == :amount_above_balance
  end

  test "CLOSED_AUCTIONS_TAKE_NO_BIDS: a graduated auction refuses preparation", %{
    auction: auction,
    wallet: wallet,
    opts: opts
  } do
    install()

    Autolaunch.TestSupport.project_auction(title: "Closed", featured: false, state: :graduated)
    |> Autolaunch.set_auction_bid_terms!(auction_address(), regent(), "REGENT", 18, "2.5",
      actor: system()
    )
    |> then(fn closed ->
      assert {:error, error} = Autolaunch.prepare_bid(closed.id, wallet, "1", "3", opts)
      assert refusal(error) == :auction_not_biddable
    end)

    assert {:ok, _open} = Autolaunch.prepare_bid(auction.id, wallet, "1", "3", opts)
  end

  test "PUBLIC_QUOTE_IS_STORED_ONLY: the estimate reads the snapshot and prepares nothing", %{
    auction: auction
  } do
    assert {:ok, quote} = Autolaunch.quote_auction_bid(auction.id, "12.5", "3")
    assert quote.estimated_tokens_if_end_now == "5"
    assert quote.current_clearing_price == "2.5"
    assert quote.status_band == "active"
  end

  defp tiny_price, do: "0." <> String.duplicate("0", 79) <> "1"

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

  defp word(value),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")
end
