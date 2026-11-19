defmodule Autolaunch.RobinhoodBidChain do
  @moduledoc """
  Robinhood Chain for one test, as a USDG bid on one of its auctions and that
  bid's return and claim read it: a JSON-RPC double answering at one latest
  block (100, its clock 50) for the fixture deployment
  (test/fixtures/robinhood-deployment.json), whose bid adapter is bound to its
  launchpad and USDG. The launchpad's one launch (`launch_id`) made the
  auction at `auction/0`, still bidding, which sells for the stock at
  `stock/0`, admitted with 18 decimals and a route, which the site lists as
  TSLA. The launch's record holds it running (`lifecycle` 1) until its
  `migration_block`, 95, the rollup block finishing opens at. Bid 7 on it
  (`bid_id`) is the bid fixture's wallet's
  (`Autolaunch.BidFixture.wallet/0`) and the last the auction issued: an
  earlier id holds no bid, and asking for a later one reverts
  `BidIdDoesNotExist`, as the auction does. The auction's logs hold that
  bid's `BidSubmitted`, so a wallet's positions read it. The launchpad takes
  new launches unless `launches_paused`, so a launch's review reads it too.

  Once the record says the launch graduated (`lifecycle` 2), it names its pool,
  its staking contract (`splitter/0`) and its two locked positions, a full
  range one and a token-only one above the opening price, each of whose
  simulated `collect` gives 2 of the stock and 1 of the token; the pool has had
  no trade and its hook no fee or settlement, and the hook holds `lanes` (what
  waits for the creator, REGENT and the stakers). One wallet, the bid
  fixture's, holds `token_balance` of the token, lets the staking contract
  take `token_allowance` of it, has `staked` everything staked there and can
  claim `claimable` of each asset (`:dollar`, USDG; `:token`; `:currency`, the
  stock); any other wallet holds, has staked and can claim nothing.

  The token page's swap panel reads the same wallet too: it holds
  `stock_balance` of the stock and lets every spender take `stock_allowance`
  of it, as it does `token_allowance` of the token, and the deployment's
  Permit2 lets its router take `permit2` of whatever the wallet spends
  (`amount` until `expiration`). The deployment's quoter quotes any trade on
  the pool at `swap_quote` of what it buys.

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
  # Its letters name the case an address is read and listed in.
  @auction "0x3000000000000000000000000000000000000abc"
  @stock "0x2000000000000000000000000000000000000002"
  @route "0x4444444444444444444444444444444444444444"
  @token "0x6000000000000000000000000000000000000006"
  @launcher "0x7000000000000000000000000000000000000007"
  @splitter "0x8000000000000000000000000000000000000008"
  @executor "0x9000000000000000000000000000000000000009"
  @lp_token_id 61
  @new_only_token_id 62
  @arb_sys "0x0000000000000000000000000000000000000064"
  @hash "0x" <> String.duplicate("6c", 32)
  @last_block Integer.pow(2, 64) - 1
  @deployment Path.expand("../fixtures/robinhood-deployment.json", __DIR__)
  @owner_of "0x6352211e"
  @extsload "0x1e2eaeaf"
  # What a graduated launch's record adds to a running one's: its pool, its
  # staking contract, its two locked positions and when its creator's vesting
  # starts.
  @graduated %{
    pool_id: 29,
    final_sqrt_price_x96: @q96,
    splitter: String.to_integer(String.trim_leading(@splitter, "0x"), 16),
    lp_token_id: @lp_token_id,
    lp_currency_used: 5 * 10 ** 18,
    lp_new_used: 7 * 10 ** 18,
    new_only_token_id: @new_only_token_id,
    new_only_used: 10 ** 18,
    vesting_start_block: 95
  }
  # A full range for a 60 tick spacing, and the token-only position's range:
  # every price of the token above the opening one, ticks below the pool's,
  # the token being its currency1.
  @full_range {-887_220, 887_220}
  @above_opening {-887_220, -60}

  def chain_id, do: @chain_id
  def auction, do: @auction
  def stock, do: @stock
  def token, do: @token
  def splitter, do: @splitter

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
        launches_paused: false,
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
        lifecycle: 1,
        migration_block: 95,
        graduated: false,
        final_price: 2 * @q96,
        raised: 0,
        bid_id: 7,
        bid: bid(),
        exit: {:exited, 0, 12 * 10 ** 18},
        claim: {:reverted, "NotGraduated()"},
        checkpoints: :final,
        lanes: [0, 0, 0],
        token_balance: 0,
        token_allowance: 0,
        staked: 0,
        claimable: %{dollar: 0, token: 0, currency: 0},
        stock_balance: 0,
        stock_allowance: 0,
        permit2: %{amount: 0, expiration: 0},
        swap_quote: 0
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
      else: {:ok, %{status: 200, body: body(answer(method, params, state))}}
  end

  # A call the contract reverts is the node's error, carrying the revert data.
  defp body({:reverted, data}),
    do: %{"error" => %{"code" => 3, "message" => "execution reverted", "data" => data}}

  defp body(result), do: %{"result" => result}

  defp answer("eth_chainId", [], state), do: state.chain_id

  defp answer("eth_getBlockByNumber", [block, false], _state) when block in ["latest", "0x64"],
    do: %{"number" => "0x64", "hash" => @hash, "timestamp" => "0x6700"}

  defp answer("eth_getBlockByHash", [@hash, false], _state),
    do: %{"number" => "0x64", "hash" => @hash, "timestamp" => "0x6700"}

  defp answer("eth_getCode", [_address, _block], state), do: state.code

  defp answer("eth_call", [%{to: to, data: data}, _block], state) do
    {:ok, config} = Lab.current()
    read(contract(to, config), String.slice(data, 0, 10), arguments(data), state)
  end

  defp answer("eth_simulateV1", [%{blockStateCalls: [%{calls: calls}]}, _block], state),
    do: [%{"calls" => Enum.map(calls, &simulated(String.slice(&1.data, 0, 10), &1, state))}]

  # The auction's bids for one owner: the one it holds, when that owner placed it.
  defp answer("eth_getLogs", [%{address: @auction, topics: [submitted, nil, owner]}], state) do
    if submitted == LabAbi.topic(RobinhoodLabAbi.bid_submitted_signature()) and
         number(owner) == number(state.bid.owner),
       do: [bid_submitted(state)],
       else: []
  end

  # The pool has had no trade, and its hook has charged no fee and settled no lane.
  defp answer("eth_getLogs", [%{address: address}], _state) do
    {:ok, config} = Lab.current()
    true = contract(address, config) in [:hook, :pool_manager]
    []
  end

  defp contract(@arb_sys, _config), do: :clock
  defp contract(@auction, _config), do: :auction
  defp contract(@route, _config), do: :route
  defp contract(@token, _config), do: :token
  defp contract(@stock, _config), do: :stock
  defp contract(@splitter, _config), do: :splitter

  # The swap panel's quoter and Permit2, then the deployment's other contracts.
  defp contract(address, config) do
    {:ok, swap} = Lab.swap_addresses(config)

    cond do
      address == swap.quoter -> :quoter
      address == Lab.address!(config, :permit2) -> :permit2
      true -> deployed(address, config)
    end
  end

  defp deployed(address, config) do
    {:ok, v1} = Lab.contracts(config, :v1)

    cond do
      address == Lab.address!(config, :bid_adapter) -> :adapter
      address == Lab.address!(config, :stocks_launchpad) -> :launchpad
      address == Lab.address!(config, :stocks_hook) -> :hook
      address == Lab.address!(config, :stocks_locker) -> :locker
      address == Lab.address!(config, :pool_manager) -> :pool_manager
      address == Lab.address!(config, :position_manager) -> :position_manager
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

      selector == LabAbi.selector("nextLaunchId()") ->
        uint(state.launch_id + 1)

      selector == LabAbi.selector("launches(uint256)") ->
        :v2
        |> RobinhoodLabAbi.shape()
        |> Map.fetch!(:record_fields)
        |> Enum.map(&launch(&1, state))
        |> words()

      selector == LabAbi.selector("stockAdmission(address)") ->
        words(state.admission)

      selector == LabAbi.selector("launchesPaused()") ->
        bool(state.launches_paused)

      selector == LabAbi.selector("creatorReleasable(uint256)") ->
        uint(0)
    end
  end

  # The first Memestock launchpad made no auction here.
  defp read(:first_launchpad, selector, _argument, _state) do
    cond do
      selector == LabAbi.selector("launchIdOfAuction(address)") -> uint(0)
      selector == LabAbi.selector("nextLaunchId()") -> uint(1)
    end
  end

  defp read(:token, selector, arguments, state) do
    cond do
      selector == LabAbi.selector("name()") ->
        string("Robinhood Dog")

      selector == LabAbi.selector("symbol()") ->
        string("RDOG")

      selector == LabAbi.selector("tokenURI()") ->
        string("data:application/json;base64,e30=")

      selector == LabAbi.selector("balanceOf(address)") ->
        uint(own(arguments, state.token_balance))

      selector == LabAbi.selector("allowance(address,address)") ->
        uint(own(arguments, state.token_allowance))
    end
  end

  defp read(:stock, selector, arguments, state) do
    cond do
      selector == LabAbi.selector("balanceOf(address)") ->
        uint(own(arguments, state.stock_balance))

      selector == LabAbi.selector("allowance(address,address)") ->
        uint(own(arguments, state.stock_allowance))
    end
  end

  defp read(:permit2, selector, [owner, _token, _router], state) do
    if selector == LabAbi.selector("allowance(address,address,address)"),
      do: words([own([owner], state.permit2.amount), own([owner], state.permit2.expiration), 0])
  end

  defp read(:quoter, selector, _trade, state) do
    if selector ==
         LabAbi.selector(
           "quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))"
         ),
       do: words([state.swap_quote, 0])
  end

  # Both pool slots the site reads answer one word: a price of one stock per
  # token, at tick 0, and as much liquidity.
  defp read(:pool_manager, @extsload, _slot, _state), do: uint(@q96)

  defp read(:position_manager, selector, [id], _state) do
    {:ok, config} = Lab.current()

    cond do
      selector == @owner_of -> address(Lab.address!(config, :stocks_locker))
      selector == LabAbi.selector("positionInfo(uint256)") -> uint(range(id))
      selector == LabAbi.selector("getPositionLiquidity(uint256)") -> uint(0)
    end
  end

  # Collecting either position deposits 2 of the stock (currency0) and 1 of the token.
  defp read(:locker, selector, [id], _state) when id in [@lp_token_id, @new_only_token_id] do
    if selector == LabAbi.selector("collect(uint256)"), do: words([2 * 10 ** 18, 10 ** 18])
  end

  defp read(:hook, selector, arguments, state) do
    cond do
      selector == LabAbi.selector("accrued(bytes32)") and arguments == [@graduated.pool_id] ->
        words(state.lanes)

      selector == LabAbi.selector("settled(bytes32)") and arguments == [@graduated.pool_id] ->
        words([0, 0, 0, 0])

      selector == LabAbi.selector("executor()") ->
        address(@executor)
    end
  end

  # The staking contract, with the fixture's wallet its only staker.
  defp read(:splitter, selector, arguments, state) do
    {:ok, config} = Lab.current()

    cond do
      selector == LabAbi.selector("totalStaked()") ->
        uint(state.staked)

      selector == LabAbi.selector("SKIM_BPS()") ->
        uint(200)

      selector == LabAbi.selector("dollar()") ->
        address(Lab.address!(config, :usdg))

      selector == LabAbi.selector("stakedOf(address)") ->
        uint(own(arguments, state.staked))

      selector == LabAbi.selector("claimable(address,address)") ->
        [asset, holder] = arguments
        uint(own([holder], Map.fetch!(state.claimable, asset(asset, config, state))))
    end
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

  defp read(:auction, selector, arguments, state) do
    Enum.find_value(auction_reads(List.first(arguments), state), fn {signature, answer} ->
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
      {"bids(uint256)", fn -> bid_record(argument, state) end},
      {"nextBidId()", fn -> uint(state.bid_id + 1) end},
      {"checkpoints(uint64)", fn -> checkpoint(state.checkpoints, argument, state.bid) end}
    ]
  end

  # startBlock, startCumulativeMps, exitedBlock, maxPrice, owner, amountQ96, tokensFilled
  defp bid_record(id, %{bid_id: id, bid: bid}),
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

  defp bid_record(id, %{bid_id: last}) when id > last,
    do: {:reverted, LabAbi.selector("BidIdDoesNotExist(uint256)") <> BaseRpcStub.hex_word(id)}

  defp bid_record(_earlier, _state), do: words(List.duplicate(0, 7))

  # `BidSubmitted(bidId, owner, priceQ96, amount)`, the amount in the stock.
  defp bid_submitted(%{bid_id: id, bid: bid}),
    do: %{
      "address" => @auction,
      "topics" => [
        LabAbi.topic(RobinhoodLabAbi.bid_submitted_signature()),
        uint(id),
        BaseRpcStub.address_topic(bid.owner)
      ],
      "data" => words([bid.max_price_q96, bid.amount])
    }

  # One launch record's field: a launch on the auction's own schedule, in the
  # lifecycle the test names.
  defp launch(:launcher, _state), do: number(@launcher)
  defp launch(:new_token, _state), do: number(@token)
  defp launch(:currency, state), do: number(state.stock)
  defp launch(:auction, _state), do: number(@auction)
  defp launch(:start_block, state), do: state.start_block
  defp launch(:end_block, state), do: state.end_block
  defp launch(:claim_block, state), do: state.claim_block
  defp launch(:migration_block, state), do: state.migration_block
  defp launch(:lifecycle, state), do: state.lifecycle

  defp launch(field, %{lifecycle: 2}) when is_map_key(@graduated, field),
    do: Map.fetch!(@graduated, field)

  defp launch(_unset, _state), do: 0

  # A wallet's own figure for the fixture's wallet, and nothing for any other.
  defp own([holder | _rest], amount),
    do: if(holder == number(BidFixture.wallet()), do: amount, else: 0)

  defp asset(address, config, state) do
    cond do
      address == number(Lab.address!(config, :usdg)) -> :dollar
      address == number(@token) -> :token
      address == number(state.stock) -> :currency
      true -> raise "the staking contract holds no asset at 0x#{BaseRpcStub.hex_word(address)}"
    end
  end

  defp range(@new_only_token_id), do: packed(@above_opening)
  defp range(@lp_token_id), do: packed(@full_range)

  # PositionInfo packs `tickUpper` at bit 32 and `tickLower` at bit 8, each a
  # 24-bit two's complement tick.
  defp packed({lower, upper}) do
    import Bitwise
    (upper &&& 0xFFFFFF) <<< 32 ||| (lower &&& 0xFFFFFF) <<< 8
  end

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

  # Every argument of a call, a whole word each.
  defp arguments(data),
    do:
      for(<<word::binary-size(64) <- String.slice(data, 10..-1//1)>>,
        do: String.to_integer(word, 16)
      )

  defp ok(data), do: %{"status" => "0x1", "returnData" => data, "logs" => []}
  defp uint(value), do: BaseRpcStub.uint(value)
  defp bool(value), do: uint(if(value, do: 1, else: 0))
  defp address(value), do: "0x" <> BaseRpcStub.address_word(value)
  defp words(values), do: "0x" <> Enum.map_join(values, &BaseRpcStub.hex_word/1)
  defp number("0x" <> hex), do: String.to_integer(hex, 16)

  defp string(value) do
    hex = Base.encode16(value, case: :lower)
    padded = String.pad_trailing(hex, div(byte_size(hex) + 63, 64) * 64, "0")
    "0x" <> BaseRpcStub.hex_word(32) <> BaseRpcStub.hex_word(byte_size(value)) <> padded
  end

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
