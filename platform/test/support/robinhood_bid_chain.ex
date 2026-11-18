defmodule Autolaunch.RobinhoodBidChain do
  @moduledoc """
  Robinhood Chain for one test, as a USDG bid on one of its auctions and that
  bid's return and claim read it: a JSON-RPC double answering at one latest
  block (100, its clock 50) for the fixture deployment
  (test/fixtures/robinhood-deployment.json), whose bid adapter is bound to its
  launchpad and USDG. The launchpad made the auction at `auction/0`, which
  sells for the stock at `stock/0`, admitted with 18 decimals and a route,
  which the site lists as TSLA. Bid 7 on it is the bid fixture's wallet's
  (`Autolaunch.BidFixture.wallet/0`); any other id holds no bid.

  `install/1` points the site at it and `put/1` replaces what it answers
  mid-test, each as overrides over the defaults; both are undone when the test
  exits. Prices are Q96, the stock's
  amounts in its smallest units, USDG's in its own (6 decimals). A
  settlement's simulated block answers each call by the function it calls:
  `exit` and `claim` say what `exitBid` (or `exitPartiallyFilledBid`) and
  `claimTokens` do, `{:reverted, signature}` reverting with that error or
  with none for `nil`. `checkpoints` shapes the auction's stored price
  history: `:final`, one checkpoint below the bid's maximum and none after it;
  `:long`, a checkpoint below it at every block. `unreadable` names one method
  the node refuses.

  Each request it answers tells the calling process `{:robinhood_read, method}`.
  """

  alias Autolaunch.Actors.System
  alias Autolaunch.{BaseRpcStub, BidFixture, LabAbi}
  alias Autolaunch.Robinhood.Lab
  alias Autolaunch.Robinhood.LabAbi, as: RobinhoodLabAbi

  @chain_id 4_663
  @q96 79_228_162_514_264_337_593_543_950_336
  @auction "0x3000000000000000000000000000000000000003"
  @stock "0x2000000000000000000000000000000000000002"
  @route "0x4444444444444444444444444444444444444444"
  @arb_sys "0x0000000000000000000000000000000000000064"
  @hash "0x" <> String.duplicate("6c", 32)
  @last_block Integer.pow(2, 64) - 1
  @deployment Path.expand("../fixtures/robinhood-deployment.json", __DIR__)

  def chain_id, do: @chain_id
  def auction, do: @auction
  def stock, do: @stock

  @doc "Bid 7 as the auction holds it unless a test says otherwise: 12 of the stock at most 3 per token."
  def bid,
    do: %{
      start_block: 10,
      exited_block: 0,
      max_price_q96: 3 * @q96,
      owner: BidFixture.wallet(),
      amount: 12 * 10 ** 18,
      tokens_filled: 0
    }

  @doc "Robinhood Chain as `overrides` over the defaults, for this test."
  def install(overrides \\ %{}) do
    for key <- [
          :autolaunch_robinhood_chain_id,
          :autolaunch_robinhood_deployment,
          :autolaunch_lab_http_client,
          __MODULE__
        ],
        do: keep(key)

    Application.put_env(:autolaunch, :autolaunch_robinhood_chain_id, @chain_id)
    Application.put_env(:autolaunch, :autolaunch_robinhood_deployment, @deployment)
    Application.put_env(:autolaunch, :autolaunch_lab_http_client, __MODULE__)
    # A settlement walk keeps where it reached, which must not reach the next case.
    Cachex.clear(Autolaunch.Chain.CcaLists.cache())

    {:ok, _stock} =
      Autolaunch.record_stock_admission(
        %{
          chain_id: @chain_id,
          address: @stock,
          symbol: "TSLA",
          name: "Tesla",
          decimals: 18,
          route: @route,
          feed: "0x" <> String.duplicate("55", 20),
          admitted: true
        },
        actor: %System{}
      )

    put(overrides)
  end

  @doc "The chain from now on: `overrides` over the defaults."
  def put(overrides), do: Application.put_env(:autolaunch, __MODULE__, Map.new(overrides))

  defp state do
    Map.merge(
      %{
        chain_id: "0x1237",
        clock: 50,
        code: "0x6000",
        unreadable: nil,
        adapter_launchpad: nil,
        launch_id: 1,
        stock: @stock,
        admission: [1, 18, number(@route)],
        usdg_balance: 100 * 10 ** 6,
        usdg_allowance: 0,
        quote: 10 ** 21,
        tick_spacing: 1,
        floor_price: @q96,
        max_bid_price: Integer.pow(2, 255),
        clearing_price: 0,
        checkpoint_price: 0,
        next_active_tick: 2 * @q96,
        tick_next: Integer.pow(2, 255),
        start_block: 10,
        end_block: 90,
        claim_block: 95,
        graduated: false,
        final_price: 2 * @q96,
        raised: 0,
        bid: bid(),
        exit: {:exited, 0, 12 * 10 ** 18},
        claim: {:reverted, "NotGraduated()"},
        checkpoints: :final
      },
      Application.get_env(:autolaunch, __MODULE__, %{})
    )
  end

  def post(_url, options) do
    %{method: method, params: params} = options[:json]
    state = state()
    send(self(), {:robinhood_read, method})

    if method == state.unreadable,
      do: {:ok, %{status: 200, body: %{"error" => %{"message" => "unavailable"}}}},
      else: {:ok, %{status: 200, body: %{"result" => answer(method, params, state)}}}
  end

  defp answer("eth_chainId", [], state), do: state.chain_id

  defp answer("eth_getBlockByNumber", ["latest", false], _state),
    do: %{"number" => "0x64", "hash" => @hash, "timestamp" => "0x6700"}

  defp answer("eth_getBlockByHash", [@hash, false], _state),
    do: %{"number" => "0x64", "hash" => @hash, "timestamp" => "0x6700"}

  defp answer("eth_getCode", [_address, _block], state), do: state.code

  defp answer("eth_call", [%{to: to, data: data}, _block], state) do
    {:ok, config} = Lab.current()
    read(contract(to, config), String.slice(data, 0, 10), argument(data), state)
  end

  defp answer("eth_simulateV1", [%{blockStateCalls: [%{calls: calls}]}, _block], state),
    do: [%{"calls" => Enum.map(calls, &simulated(String.slice(&1.data, 0, 10), &1, state))}]

  defp contract(@arb_sys, _config), do: :clock
  defp contract(@auction, _config), do: :auction
  defp contract(@route, _config), do: :route

  defp contract(address, config) do
    {:ok, v1} = Lab.contracts(config, :v1)

    cond do
      address == Lab.address!(config, :bid_adapter) -> :adapter
      address == Lab.address!(config, :stocks_launchpad) -> :launchpad
      address == Lab.address!(config, :usdg) -> :usdg
      address == v1.launchpad -> :first_launchpad
    end
  end

  defp read(:clock, selector, _argument, state) do
    if selector == LabAbi.selector("arbBlockNumber()"), do: uint(state.clock)
  end

  defp read(:adapter, selector, _argument, state) do
    {:ok, config} = Lab.current()

    cond do
      selector == LabAbi.selector("launchpad()") ->
        address(state.adapter_launchpad || Lab.address!(config, :stocks_launchpad))

      selector == LabAbi.selector("usdg()") ->
        address(Lab.address!(config, :usdg))
    end
  end

  defp read(:launchpad, selector, _argument, state) do
    cond do
      selector == LabAbi.selector("launchIdOfAuction(address)") ->
        uint(state.launch_id)

      selector == LabAbi.selector("launches(uint256)") ->
        RobinhoodLabAbi.launch_record_words()
        |> then(&List.duplicate(0, &1))
        |> List.replace_at(2, number(state.stock))
        |> words()

      selector == LabAbi.selector("stockAdmission(address)") ->
        words(state.admission)
    end
  end

  # The first Memestock launchpad made no auction here.
  defp read(:first_launchpad, selector, _argument, _state) do
    if selector == LabAbi.selector("launchIdOfAuction(address)"), do: uint(0)
  end

  defp read(:usdg, selector, _argument, state) do
    cond do
      selector == LabAbi.selector("balanceOf(address)") -> uint(state.usdg_balance)
      selector == LabAbi.selector("allowance(address,address)") -> uint(state.usdg_allowance)
    end
  end

  defp read(:route, selector, _argument, state) do
    if selector == LabAbi.selector("quoteExactIn(address,address,uint256)"),
      do: uint(state.quote)
  end

  defp read(:auction, selector, argument, state) do
    Enum.find_value(auction_reads(argument, state), fn {signature, answer} ->
      if LabAbi.selector(signature) == selector, do: answer.()
    end)
  end

  defp auction_reads(argument, state) do
    [
      {"currency()", fn -> address(state.stock) end},
      {"tickSpacing()", fn -> uint(state.tick_spacing) end},
      {"floorPrice()", fn -> uint(state.floor_price) end},
      {"MAX_BID_PRICE()", fn -> uint(state.max_bid_price) end},
      {"clearingPrice()", fn -> uint(state.clearing_price) end},
      {"startBlock()", fn -> uint(state.start_block) end},
      {"endBlock()", fn -> uint(state.end_block) end},
      {"claimBlock()", fn -> uint(state.claim_block) end},
      {"isGraduated()", fn -> bool(state.graduated) end},
      {"checkpoint()", fn -> words([state.checkpoint_price, 0, 0, 0, 0, 0]) end},
      {"nextActiveTickPrice()", fn -> uint(state.next_active_tick) end},
      {"ticks(uint256)", fn -> words([state.tick_next, 0]) end},
      {"bids(uint256)", fn -> bid_record(argument, state.bid) end},
      {"nextBidId()", fn -> uint(8) end},
      {"checkpoints(uint64)", fn -> checkpoint(state.checkpoints, argument, state.bid) end}
    ]
  end

  # startBlock, startCumulativeMps, exitedBlock, maxPrice, owner, amountQ96, tokensFilled
  defp bid_record(7, bid),
    do:
      words([
        bid.start_block,
        0,
        bid.exited_block,
        bid.max_price_q96,
        number(bid.owner),
        bid.amount * @q96,
        bid.tokens_filled
      ])

  defp bid_record(_none, _bid), do: words(List.duplicate(0, 7))

  # price, currencyRaised, mpsPerPrice, cumulativeMps, prev, next
  defp checkpoint(:final, _block, bid),
    do: words([bid.max_price_q96 - 1, 0, 0, 0, 0, @last_block])

  defp checkpoint(:long, block, _bid), do: words([1, 0, 0, 0, 0, block + 1])

  defp simulated(selector, call, state) do
    signature =
      Enum.find(
        [
          "checkpoint()",
          "isGraduated()",
          "clearingPrice()",
          "currencyRaised()",
          "exitBid(uint256)",
          "exitPartiallyFilledBid(uint256,uint64,uint64)",
          "claimTokens(uint256)"
        ],
        &(LabAbi.selector(&1) == selector)
      )

    case signature do
      "checkpoint()" -> ok("0x")
      "isGraduated()" -> ok(bool(state.graduated))
      "clearingPrice()" -> ok(uint(state.final_price))
      "currencyRaised()" -> ok(uint(state.raised))
      "claimTokens(uint256)" -> outcome(state.claim, call, state)
      "exit" <> _bid -> outcome(state.exit, call, state)
    end
  end

  defp outcome({:exited, filled, refunded}, call, state),
    do:
      Map.put(ok("0x"), "logs", [
        event("BidExited(uint256,address,uint256,uint256)", call, state, [filled, refunded])
      ])

  defp outcome({:claimed, tokens}, call, state),
    do:
      Map.put(ok("0x"), "logs", [
        event("TokensClaimed(uint256,address,uint256)", call, state, [tokens])
      ])

  # A claim that succeeds with nothing to deliver logs nothing.
  defp outcome(:nothing, _call, _state), do: ok("0x")

  defp outcome({:reverted, nil}, _call, _state),
    do: %{"status" => "0x0", "returnData" => "0x", "logs" => []}

  defp outcome({:reverted, error}, _call, _state),
    do: %{"status" => "0x0", "returnData" => LabAbi.selector(error), "logs" => []}

  defp event(signature, call, state, data),
    do: %{
      "address" => @auction,
      "topics" => [
        LabAbi.topic(signature),
        "0x" <> BaseRpcStub.hex_word(argument(call.data)),
        BaseRpcStub.address_topic(state.bid.owner)
      ],
      "data" => words(data)
    }

  # A call's first argument, a whole word.
  defp argument(data) when byte_size(data) >= 74,
    do: data |> String.slice(10, 64) |> String.to_integer(16)

  defp argument(_data), do: nil

  defp ok(data), do: %{"status" => "0x1", "returnData" => data, "logs" => []}
  defp uint(value), do: BaseRpcStub.uint(value)
  defp bool(value), do: uint(if(value, do: 1, else: 0))
  defp address(value), do: "0x" <> BaseRpcStub.address_word(value)
  defp words(values), do: "0x" <> Enum.map_join(values, &BaseRpcStub.hex_word/1)
  defp number("0x" <> hex), do: String.to_integer(hex, 16)

  defp keep(key) do
    old = Application.fetch_env(:autolaunch, key)

    ExUnit.Callbacks.on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:autolaunch, key, value)
        :error -> Application.delete_env(:autolaunch, key)
      end
    end)
  end
end
