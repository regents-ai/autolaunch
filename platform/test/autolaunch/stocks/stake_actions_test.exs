defmodule Autolaunch.Stocks.StakeActionsTest do
  @moduledoc """
  The token page's own way into the staking reviews, `StakeActions.prepare/3`,
  on `Autolaunch.StakeChain`'s two graduated Base launches:

    * settling the Revstake launch, which has no staker lane to settle, is
      exactly one step, `collect(<that launch's lp_token_id>)` on the
      `lp_locker` of the launch's own contracts version, showing the fees the
      locker itself says the call would deposit;
    * a review binds to one of the signed-in account's own wallets: any other
      wallet, or no session lease, is refused before any chain is read;
    * a review reads what the wallet holds but not what it has claimed so
      far, which only the page's own position shows;
    * an action no staking contract offers, or one the launch's does not, is
      refused;
    * converting the Memestock launch's REGENT lane, by the wallet its hook
      names, asks the stock's route what the amount is worth and settles for
      no less than 95% of that with the floor, asks nothing and names no
      minimum without it, and is no action with a floor that is neither.
  """

  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1]

  alias Autolaunch.{BaseRpcStub, Lab, LabAbi, StakeChain}
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias Autolaunch.Stocks.StakeActions
  alias RegentChain.{BuilderCode, Review}

  @other "0x2222222222222222222222222222222222222222"

  setup :bidder

  test "settle on a Base Revstake launch is one collect(lp_token_id) step on the lp_locker",
       %{opts: opts, wallet: wallet} do
    auction = revstake!()
    {:ok, config} = Lab.contracts(Lab.current!(), auction.contracts_version)
    lp_locker = Lab.address!(config, :lp_locker)
    StakeChain.install()

    request = %{kind: :settle, launch: %{chain: :base, auction: auction}}

    assert {:ok, %{kind: :settle, steps: steps, facts: facts, context: %{locker: ^lp_locker}}} =
             StakeActions.prepare(request, wallet, opts)

    assert [%{step: "collect_full_range", to: ^lp_locker, data: data}] = steps

    assert data ==
             BuilderCode.append(
               LabAbi.selector("collect(uint256)") <>
                 BaseRpcStub.hex_word(StakeChain.lp_token_id())
             )

    assert facts == [["Full range position", "1 LRVS · 2 REGENT"]]
  end

  test "a review binds to one of the signed-in account's own wallets: any other, or no session lease, is refused before any chain is read",
       %{opts: opts, wallet: wallet} do
    StakeChain.install()
    request = %{kind: :claim, launch: %{chain: :base, auction: revstake!()}}

    for {address, given, reason} <- [
          {@other, opts, :wrong_signer},
          {wallet, Keyword.delete(opts, :context), :session_lease_required}
        ] do
      assert {:error, %Ash.Error.Invalid.Unavailable{reason: ^reason}} =
               StakeActions.prepare(request, address, given)

      assert calls() == [], "#{reason}"
    end

    # The account's own wallet, with the lease, is reviewed from the chain.
    assert {:ok, %{kind: :claim}} = StakeActions.prepare(request, wallet, opts)
    assert calls() != []
  end

  test "a review reads what the wallet holds but not what it has claimed so far, which only the page's position shows",
       %{opts: opts, wallet: wallet} do
    StakeChain.install(%{balance: 5 * 10 ** 18, staked: 3 * 10 ** 18})
    auction = revstake!()
    splitter = StakeChain.splitter()

    for kind <- [:stake, :unstake, :claim, :settle] do
      calls()
      amount = if kind == :unstake, do: "1"
      request = %{kind: kind, launch: %{chain: :base, auction: auction}, amount: amount}
      assert {:ok, %{position: position}} = StakeActions.prepare(request, wallet, opts)
      refute Map.has_key?(position, :claimed), "#{kind}"
      refute splitter in logs(), "#{kind}"
    end

    {:ok, pool} = Autolaunch.Pool.read(auction)
    calls()
    assert {:ok, %{claimed: %{token: %{atomic: 0}}}} = StakeActions.position(pool, wallet)
    assert splitter in logs()
  end

  test "an action no staking contract offers, or one the launch's does not, is refused",
       %{opts: opts, wallet: wallet} do
    StakeChain.install()
    launch = %{chain: :base, auction: revstake!()}

    # No such action anywhere, and the two only a Memestock launch offers.
    for kind <- [:bogus, :convert, :release] do
      assert {:error, %Ash.Error.Invalid.Unavailable{reason: :unknown_action}} =
               StakeActions.prepare(
                 %{kind: kind, launch: launch, amount: "1", floor: true},
                 wallet,
                 opts
               ),
             "#{kind}"
    end
  end

  test "converting the Memestock launch's REGENT lane settles for 95% of the route's quote with the floor, and for any price without it, unasked",
       %{opts: opts, wallet: wallet} do
    {:ok, stocks} = StocksLab.contracts(StocksLab.current!(), :v2)
    quote_exact_in = LabAbi.selector("quoteExactIn(address,address,uint256)")
    # 5 AAPLc waiting in REGENT's lane, which this wallet converts; the route
    # quotes 400 USDC for the 2 AAPLc sold.
    StakeChain.install(%{converter: wallet, lanes: [0, 5 * 10 ** 8, 0], quote: 400 * 10 ** 6})
    request = %{kind: :convert, launch: %{chain: :base, auction: memestock!()}, amount: "2"}

    convert = fn least ->
      Review.step(
        "convert",
        stocks.hook,
        LabAbi.encode(stocks.abis["hook"], "settleRegentLane(bytes32,uint256,uint256)", [
          StakeChain.memestock_pool_id(),
          2 * 10 ** 8,
          least
        ])
      )
    end

    calls()

    assert {:ok, %{steps: [floored], facts: facts}} =
             StakeActions.prepare(Map.put(request, :floor, true), wallet, opts)

    assert floored == convert.(380 * 10 ** 6)
    assert {StakeChain.route(), quote_exact_in} in calls()

    assert facts == [
             ["Waiting in REGENT's share", "5 AAPLc"],
             ["You convert", "2 AAPLc"],
             ["Worth at the Chainlink price", "400 USDC"],
             ["Least accepted", "380 USDC"]
           ]

    assert {:ok, %{steps: [unfloored], facts: facts}} =
             StakeActions.prepare(Map.put(request, :floor, false), wallet, opts)

    assert unfloored == convert.(0)
    refute Enum.any?(calls(), &(elem(&1, 1) == quote_exact_in))
    assert List.last(facts) == ["Least accepted", "No minimum"]

    for floor <- [nil, "true"] do
      assert {:error, %Ash.Error.Invalid.Unavailable{reason: :unknown_action}} =
               StakeActions.prepare(Map.put(request, :floor, floor), wallet, opts),
             inspect(floor)
    end

    assert {:error, %Ash.Error.Invalid.Unavailable{reason: :unknown_action}} =
             StakeActions.prepare(request, wallet, opts)
  end

  # The site's graduated Revstake launch on Base, `Autolaunch.StakeChain`'s.
  defp revstake!,
    do:
      Autolaunch.TestSupport.project_auction(
        chain_id: 8453,
        state: :graduated,
        symbol: "LRVS",
        token_address: StakeChain.subject()
      )

  # The site's graduated Memestock launch on Base, `Autolaunch.StakeChain`'s,
  # trading against AAPLc.
  defp memestock!,
    do:
      Autolaunch.TestSupport.project_auction(
        chain_id: 8453,
        kind: :stocks,
        state: :graduated,
        symbol: "LRVS",
        address: StakeChain.auction(),
        token_address: StakeChain.subject(),
        quote_token_address: StakeChain.stock(),
        quote_token_symbol: "AAPLc",
        quote_token_decimals: 8
      )

  # Every contract whose logs were asked for since the last look.
  defp logs(found \\ []) do
    receive do
      {:rpc, "eth_getLogs", [%{address: address}]} -> logs([String.downcase(address) | found])
    after
      0 -> Enum.reverse(found)
    end
  end

  # Every contract read since the last look, as the contract and the function asked.
  defp calls(found \\ []) do
    receive do
      {:rpc, "eth_call", [%{to: to, data: data}, _block]} ->
        calls([{String.downcase(to), String.slice(data, 0, 10)} | found])

      {:rpc, _method, _params} ->
        calls(found)
    after
      0 -> Enum.reverse(found)
    end
  end
end
