defmodule Autolaunch.BidActionsTest do
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture

  alias Autolaunch
  alias Autolaunch.BidActions

  @q96 79_228_162_514_264_337_593_543_950_336
  @other "0x2222222222222222222222222222222222222222"

  setup :bidder
  setup :verified_treasury

  test "BOUND_REGENT_CURRENCY: an auction raising anything else can neither be read nor bid on",
       %{auction: auction, wallet: wallet, opts: opts} do
    install(currency: @other)

    assert {:error, error} = prepare(auction.id, wallet, "12.5", "3", opts)
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

    assert {:error, error} = prepare(auction.id, @other, "1", "3", opts)
    assert refusal(error) == :wrong_signer
  end

  test "TREASURY_DRIFT_ENDS_EVERY_NEW_REVIEW", %{
    auction: auction,
    wallet: wallet,
    opts: opts
  } do
    install()

    assert {:ok, %{steps: _steps}} = prepare(auction.id, wallet, "1", "3", opts)

    Autolaunch.TestAutolaunchTreasuryChainClient.install(threshold: 1)

    assert {:error, error} = prepare(auction.id, wallet, "1", "3", opts)
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
                 review: %{
                   "chain" => %{"chain_id" => 8453},
                   "signer" => wallet,
                   "facts" => %{
                     "name" => "Base launch",
                     "symbol" => "BASE",
                     "links" => [],
                     "terms" => %{"required_regent_raised" => "19999999999999999999989"},
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

    assert {:ok, %{steps: _steps}} = prepare(launched.id, wallet, "1", "3", opts)
  end

  test "a Base Memestock auction is bid on against the launchpad its deployment admits, and no other",
       %{wallet: wallet, opts: opts} do
    install()
    # The launchpad the fixture Base Stocks deployment description admits.
    launchpad = "0x0f8955a7f09ec713bb71c30e07b512ecee69a044"

    admitted = memestock_auction!("0x5555555555555555555555555555555555555555", launchpad)

    assert {:ok, %{steps: _steps}} = prepare(admitted.id, wallet, "1", "3", opts)

    elsewhere = memestock_auction!("0x6666666666666666666666666666666666666666", @other)
    assert {:error, error} = prepare(elsewhere.id, wallet, "1", "3", opts)
    assert refusal(error) == :treasury_security_changed
  end

  test "EXACT_AMOUNTS_AND_PRICES: only exact eighteen-decimal amounts and positive prices review",
       %{auction: auction, wallet: wallet, opts: opts} do
    install(prev_tick_price_q96: div(@q96, 4))

    for invalid <- ["0", "-1", "garbage", "1e3", "1.", ".5", "1.0000000000000000001"] do
      assert {:error, error} = prepare(auction.id, wallet, invalid, "3", opts)
      assert refusal(error) == :invalid_amount
    end

    for invalid <- ["0", "-1", "garbage", "1e3"] do
      assert {:error, error} = prepare(auction.id, wallet, "1", invalid, opts)
      assert refusal(error) == :invalid_decimal
    end

    assert {:error, error} = prepare(auction.id, wallet, "", "3", opts)
    assert refusal(error) == :invalid_amount
    assert {:error, error} = prepare(auction.id, wallet, "1", "", opts)
    assert refusal(error) == :invalid_decimal

    assert {:ok, 12_345_678_901_234_567_890_123_456_789_012_345_678} =
             BidActions.atomic_amount("12345678901234567890.123456789012345678", 18)

    assert {:ok, %{context: half}} = prepare(auction.id, wallet, "1", "0.5", opts)
    assert half.max_price_q96 == div(@q96, 2)

    assert {:error, error} =
             prepare(auction.id, wallet, "1", tiny_price(), opts)

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
      assert {:ok, %{steps: steps, facts: facts, context: context}} =
               prepare(ctx.auction.id, ctx.wallet, "1", requested, ctx.opts)

      assert context.max_price_q96 == expected
      assert rem(expected, spacing) == 0

      assert Decimal.compare(Decimal.new(facts.max_price, max_digits: :infinity), requested) ==
               :lt

      assert Enum.find(steps, &(&1.step == "bid")).data ==
               Autolaunch.LabAbi.encode(
                 Autolaunch.Lab.abi!(Autolaunch.Lab.current!(), :auction),
                 "submitBid(uint256,uint128,address,uint256,bytes)",
                 [expected, Integer.pow(10, 18), ctx.wallet, spacing, "0x"]
               )
    end

    assert {:error, error} =
             prepare(ctx.auction.id, ctx.wallet, "1", "0.000001", ctx.opts)

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
    assert {:error, _} = BidActions.price_q96(String.duplicate("9", 100), 18)
    exact = Autolaunch.BidPrice.decimal(30, 18)
    assert {:ok, 30} = BidActions.price_q96(exact, 18)

    assert {:ok, 29} =
             BidActions.price_q96(
               Decimal.new(1, 30 * Integer.pow(5, 96) - 1, -96)
               |> Decimal.to_string(:normal),
               18
             )
  end

  test "LONG_STORED_PRICE: a bid estimate reads the whole stored price, never zero" do
    price =
      "0." <>
        String.duplicate("0", 6) <>
        "15833990919455422282092917151435809523796205411372284288518130779266357421875"

    auction =
      Autolaunch.TestSupport.project_auction(state: :active, current_clearing_price: price)

    assert {:ok, below} = Autolaunch.quote_auction_bid(auction.id, "1", "0.0000001")
    assert below.current_clearing_price == price
    refute below.would_be_active_now
    assert "max_price_below_current_clearing_price" in below.warnings

    assert {:ok, at} = Autolaunch.quote_auction_bid(auction.id, "1", price)
    assert at.would_be_active_now
    assert at.status_band == "borderline"
  end

  defmodule StockQuoteRpc do
    def post(_url, options) do
      %{method: method, params: params} = options[:json]
      result = answer(method, params)
      {:ok, %{status: 200, body: %{"result" => result}}}
    end

    defp answer("eth_chainId", _), do: "0x2105"
    defp answer("eth_getCode", _), do: "0x6080"

    defp answer("eth_getBlockByNumber", _),
      do: %{
        "number" => "0x96",
        "hash" => "0x" <> String.duplicate("ab", 32),
        "timestamp" => "0x6700"
      }

    defp answer("eth_call", [%{data: data}, _block]) do
      words = %{
        Autolaunch.LabAbi.selector("stockAdmission(address)") => [
          1,
          18,
          0x2222222222222222222222222222222222222222
        ],
        Autolaunch.LabAbi.selector("balanceOf(address)") => [100_000_000],
        Autolaunch.LabAbi.selector("allowance(address,address)") => [100_000_000],
        Autolaunch.LabAbi.selector("quoteExactIn(address,address,uint256)") => [
          Integer.pow(2, 128) - 1
        ]
      }

      "0x" <>
        Enum.map_join(
          Map.fetch!(words, String.slice(data, 0, 10)),
          &Autolaunch.BaseRpcStub.hex_word/1
        )
    end
  end

  test "the displayed stock minimum equals the signed calldata, for default and edited slippage",
       %{wallet: wallet, opts: opts} do
    install()
    previous = Application.get_env(:autolaunch, :autolaunch_lab_http_client)
    Application.put_env(:autolaunch, :autolaunch_lab_http_client, StockQuoteRpc)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:autolaunch, :autolaunch_lab_http_client, previous),
        else: Application.delete_env(:autolaunch, :autolaunch_lab_http_client)
    end)

    auction =
      memestock_auction!(
        "0x5555555555555555555555555555555555555555",
        "0x0f8955a7f09ec713bb71c30e07b512ecee69a044"
      )

    request = %{auction_id: auction.id, amount: "10", max_price: "3", pay_with: "USDC"}

    for {input, bps} <- [{request, 500}, {Map.put(request, :slippage_percent, "12.50"), 1250}] do
      assert {:ok, prepared} = BidActions.prepare(input, wallet, opts)
      bid = Enum.find(prepared.steps, &(&1.step == "usdc_bid"))
      minimum = bid.data |> String.slice(138, 64) |> String.to_integer(16)

      assert {:ok, ^minimum} =
               Autolaunch.Stocks.Amounts.parse_units(prepared.facts.min_stock_out, 18)

      assert minimum == Autolaunch.BidSlippage.minimum(Integer.pow(2, 128) - 1, bps)
      assert prepared.facts.slippage_percent == Autolaunch.BidSlippage.percent(bps)
    end

    assert {:error, error} =
             BidActions.prepare(Map.put(request, :slippage_percent, "100"), wallet, opts)

    assert refusal(error) == :invalid_slippage
  end

  defp prepare(auction_id, wallet, amount, max_price, opts),
    do:
      BidActions.prepare(
        %{auction_id: auction_id, amount: amount, max_price: max_price},
        wallet,
        opts
      )

  defp memestock_auction!(address, launchpad) do
    %{
      kind: :stocks,
      origin: :site,
      chain_id: 8453,
      auction_address: address,
      title: "Memestock auction",
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
