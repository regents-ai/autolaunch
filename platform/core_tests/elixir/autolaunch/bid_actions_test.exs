defmodule Autolaunch.BidActionsTest do
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture

  alias Autolaunch

  @q96 79_228_162_514_264_337_593_543_950_336
  @other "0x2222222222222222222222222222222222222222"

  setup :bidder
  setup :verified_treasury

  test "BOUND_REGENT_CURRENCY: an auction raising anything else can neither be read nor bid on",
       %{auction: auction, wallet: wallet, opts: opts} do
    install(currency: @other)

    assert {:error, error} = Autolaunch.prepare_bid(auction.id, wallet, "12.5", "3", opts)
    assert refusal(error) == :auction_currency_changed

    assert {:error, error} = Autolaunch.bid_position(auction.id, wallet, opts)
    assert refusal(error) == :auction_currency_changed
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

  test "TREASURY_DRIFT_REFUSES_EVERY_PRESS_OF_THE_REVIEW", %{
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

    assert {:error, error} =
             Autolaunch.dispatch_wallet_press(
               :bid,
               operation.action_id,
               Atom.to_string(operation.step),
               Ecto.UUID.generate(),
               wallet,
               opts
             )

    assert refusal(error) == :treasury_security_changed
  end

  test "a Base launch recorded from its reviewed launch binds its treasury report, so it can be bid on",
       %{account: account, wallet: wallet, opts: opts} do
    install()
    treasury = "0x8888888888888888888888888888888888888888"
    report = Autolaunch.TestAutolaunchTreasuryChainClient.seed_verified!(treasury)

    assert {:ok, _notifications} =
             Autolaunch.LabProjection.project_launch(
               %{
                 human_account_id: account.id,
                 envelope: %{
                   "chain_id" => 8453,
                   "expected_signer" => wallet,
                   "arguments" => %{
                     "name" => "Base launch",
                     "symbol" => "BASE",
                     "required_regent_raised_atomic" => "1000",
                     "regent" => regent(),
                     "factory" => @other,
                     "treasury_security" => %{"report_id" => report.id, "address" => treasury}
                   }
                 }
               },
               %{
                 "launch_id" => "1",
                 "subject" => "0x6666666666666666666666666666666666666666",
                 "auction" => "0x5555555555555555555555555555555555555555",
                 "escrow" => "0x7777777777777777777777777777777777777777",
                 "treasury" => treasury
               }
             )

    {:ok, launched} =
      Autolaunch.get_auction_by_chain_address(
        8453,
        "0x5555555555555555555555555555555555555555",
        actor: system()
      )

    assert launched.treasury_security_report_id == report.id

    assert {:ok, %{operation: _operation}} =
             Autolaunch.prepare_bid(launched.id, wallet, "1", "3", opts)
  end

  test "a Base Memestake auction is bid on against the launchpad its deployment admits, and no other",
       %{wallet: wallet, opts: opts} do
    install()
    # The launchpad the fixture Base Stocks deployment description admits.
    launchpad = "0x1d36a95112835f81b1b499a808e556020c64cac2"

    admitted = memestake_auction!("0x5555555555555555555555555555555555555555", launchpad)

    assert {:ok, %{operation: operation}} =
             Autolaunch.prepare_bid(admitted.id, wallet, "1", "3", opts)

    assert operation.envelope["arguments"]["treasury_security"]["address"] == launchpad

    elsewhere = memestake_auction!("0x6666666666666666666666666666666666666666", @other)
    assert {:error, error} = Autolaunch.prepare_bid(elsewhere.id, wallet, "1", "3", opts)
    assert refusal(error) == :treasury_security_changed
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

  test "exact maximum is floored to the pinned zero-based grid without decimal rounding", ctx do
    spacing = 792_281_625_142_643_375_935_439

    install(
      tick_spacing_q96: spacing,
      floor_price_q96: spacing,
      clearing_price_q96: spacing,
      prev_tick_price_q96: spacing
    )

    for {requested, expected} <- [
          {"0.004", 316_912_650_057_057_350_374_175_600},
          {"0.002", 158_456_325_028_528_675_187_087_800}
        ] do
      assert {:ok, %{operation: op}} =
               Autolaunch.prepare_bid(ctx.auction.id, ctx.wallet, "1", requested, ctx.opts)

      args = op.envelope["arguments"]
      assert args["requested_max_price"] == requested
      assert args["max_price_q96"] == Integer.to_string(expected)
      assert rem(expected, spacing) == 0

      assert Decimal.compare(Decimal.new(args["max_price"], max_digits: :infinity), requested) ==
               :lt

      assert op.envelope["data"] ==
               Autolaunch.LabAbi.encode(
                 Autolaunch.Lab.abi!(Autolaunch.Lab.current!(), :auction),
                 "submitBid(uint256,uint128,address,uint256,bytes)",
                 [expected, Integer.pow(10, 18), ctx.wallet, spacing, "0x"]
               )
    end

    assert {:error, error} =
             Autolaunch.prepare_bid(ctx.auction.id, ctx.wallet, "1", "0.000001", ctx.opts)

    assert refusal(error) == :price_below_admissible_tick
  end

  test "tick boundaries, clearing floor, cap and huge precision use exact integer bounds" do
    limits = %{
      tick_spacing_q96: 10,
      floor_price_q96: 10,
      clearing_price_q96: 20,
      max_bid_price_q96: 95
    }

    for {requested, expected} <- [
          {29, :refused},
          {30, 30},
          {31, 30},
          {89, 80},
          {90, 90},
          {100, 90}
        ] do
      if expected == :refused,
        do:
          assert(
            {:error, :price_below_admissible_tick} == Autolaunch.BidPrice.align(requested, limits)
          ),
        else: assert({:ok, expected} == Autolaunch.BidPrice.align(requested, limits))
    end

    assert {:error, _} = Autolaunch.BidPrice.align(Integer.pow(2, 256), limits)
    assert {:error, _} = Autolaunch.BidPrice.align(40, %{limits | tick_spacing_q96: 0})
    assert {:error, _} = Autolaunch.BidActions.price_q96(String.duplicate("9", 100), 18)
    exact = Autolaunch.BidPrice.decimal(30, 18)
    assert {:ok, 30} = Autolaunch.BidActions.price_q96(exact, 18)

    assert {:ok, 29} =
             Autolaunch.BidActions.price_q96(
               Decimal.new(1, 30 * Integer.pow(5, 96) - 1, -96)
               |> Decimal.to_string(:normal),
               18
             )
  end

  defp memestake_auction!(address, launchpad) do
    %{
      kind: :stocks,
      origin: :site,
      chain_id: 8453,
      auction_address: address,
      title: "Memestake auction",
      creator_human_account_id: Autolaunch.TestSupport.register_creator!().id,
      creator_address: "0x1414141414141414141414141414141414141414",
      featured: false,
      state: :active,
      current_clearing_price: "0",
      required_currency_raised: "1000",
      treasury_address: launchpad
    }
    |> Autolaunch.record_launch_auction!(actor: system())
    |> Autolaunch.set_auction_bid_terms!(address, regent(), "STOCK", 18, "2.5", actor: system())
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
end
