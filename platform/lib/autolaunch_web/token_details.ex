defmodule AutolaunchWeb.TokenDetails do
  @moduledoc """
  Everything a graduated token's page keeps out of sight, as structured plain
  text a person copies for their agent: the token and its pool, how its
  staking pays out, the fee each trade pays and where it has gone so far, the
  Uniswap Liquidity Pool's locked positions, the treasury of a Revstake
  launch, and the copying wallet's own stake and rewards when they are known.

  `details` is what the page has read:

    * `:name`, `:symbol`, `:url` - the token as the page presents it;
    * `:auction` - the launch's auction record;
    * `:pool` - its pool facts (`Autolaunch.Pool` or
      `Autolaunch.Robinhood.Pool`);
    * `:fees` - `Autolaunch.PoolFees.totals/2` for the pool;
    * `:supply` - the whole supply in whole tokens, or nil;
    * `:price` - the stored price to every digit, or nil;
    * `:treasury` - a Revstake treasury's public security view, `:unverified`
      on a local fork, or nil for a Memestock launch;
    * `:raised` - what its auction raised, when the page has read it.

  Every figure is one the page already read; nothing here reads the chain.
  """

  alias Autolaunch.Stocks.{Amounts, FeeSchedule}
  alias AutolaunchWeb.Components.{AutolaunchHelpers, LaunchTrust}

  @bps 10_000
  # RegentFeeHook's Regent lane on every Revstake trade, beside the stakers' lane.
  @revstake_regent_bps 100

  @doc """
  The reward assets a launch's staking pays by design, as the keys of a
  wallet's claimable figures: a Memestock splitter is paid the stock (its
  hook's staker lane and the locked liquidity's fees) and the token (the
  locked liquidity's fees); a Revstake splitter is paid REGENT and the token
  by every trade and the locked liquidity, and the dollar its launcher sends.
  """
  def paid_assets(%{kind: :stocks}), do: [:token, :stock]
  def paid_assets(%{kind: :agent}), do: [:token, :stock, :dollar]

  @doc "The text copied for `details`, with `wallet`'s position when it has been read."
  def text(details, wallet, position) do
    %{pool: pool} = details

    [
      head(details),
      token(details),
      supply(details),
      staking(details),
      trade_fees(pool),
      liquidity(pool),
      settlements(pool),
      treasury(details),
      yours(pool, wallet, position)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp head(%{pool: pool} = details) do
    [
      "#{details.name} (#{details.symbol}) on Autolaunch",
      "Page: #{details.url}",
      "Kind: #{kind_name(pool)}",
      "Network: #{network(pool)}",
      "Read from the chain at block #{grouped(pool.block.number)}.",
      ""
    ]
  end

  defp token(%{pool: pool} = details) do
    [
      "## Token",
      "- Token address: #{pool.token.address}",
      "- Trades against: #{pool.currency.symbol} #{pool.currency.address} (#{pool.currency.decimals} decimal places)",
      "- Price now: " <> price(pool.current && pool.current.price, pool),
      pool[:graduation_price] &&
        "- Price when the pool opened: " <> price(pool.graduation_price, pool),
      details.price && "- Price to 18 decimals: #{details.price} #{pool.currency.symbol}",
      details.supply && "- Total supply: #{whole(details.supply)} #{pool.token.symbol}",
      details[:raised] && "- Raised in its auction: #{details.raised} #{pool.currency.symbol}",
      pool[:unsold] &&
        "- Unsold tokens: #{pool.unsold.amount} #{pool.token.symbol}, #{unsold(pool.unsold)} #{pool.unsold.address}",
      ""
    ]
  end

  # How the launch's supply is split, as its launch type fixes it.
  defp supply(%{auction: auction} = details) do
    %{name: name, rows: rows, explained_at: path} = LaunchTrust.supply_rows(auction)

    [
      "## Supply",
      Enum.map(rows, fn {label, amount, after_auction} ->
        "- #{label}: #{amount}; #{after_auction}"
      end),
      "- How every #{name} token is split: #{URI.merge(details.url, path)}",
      ""
    ]
  end

  defp staking(%{pool: pool} = details) do
    splitter = pool.fees.splitter

    [
      "## Staking",
      "- Staking contract: #{splitter.address}",
      "- Staked by everyone: #{splitter.total_staked} #{pool.token.symbol}" <>
        of_supply(splitter.total_staked_atomic, details.supply, pool),
      "- Pays rewards in: " <>
        Enum.map_join(paid_assets(pool), ", ", &asset(pool, &1).symbol),
      "- How rewards are split: " <> split_rule(pool),
      "- Trading fees charged, last 24 hours: " <>
        fee_total(details.fees && details.fees.day, pool),
      "- Trading fees charged, all time: " <>
        fee_total(details.fees && details.fees.all_time, pool),
      "- Tokens are not locked: unstake any time after the block you staked in. Claiming opens from that block too, and staking more starts the wait again.",
      "- Claim rewards sends every reward the staking contract has counted for you, in one transaction. Settle contract moves trading fees still waiting in the pool into the staking contract first; anyone can press it.",
      ""
    ]
  end

  defp trade_fees(%{kind: :agent} = pool) do
    [
      "## Fees on each trade",
      "- Stakers: #{bps_percent(pool.fees.lane_bps)} of every trade, paid into the staking contract with the trade itself, in #{pool.currency.symbol} or #{pool.token.symbol} depending on the side. Sent so far: #{pool.fees.per_lane.currency} #{pool.currency.symbol} and #{pool.fees.per_lane.token} #{pool.token.symbol} over #{pool.fees.swaps} trades.",
      "- Regent: #{bps_percent(@revstake_regent_bps)} of every trade: REGENT goes directly to REGENT staking, #{pool.token.symbol} to the Regent Safe. Not part of #{pool.token.symbol} staking rewards.",
      "- Uniswap pool fee: #{pool.lp_fee}, earned by the Uniswap Liquidity Pool and sent to stakers when collected.",
      "- Pool fee contract: #{pool.hook}",
      ""
    ]
  end

  defp trade_fees(%{kind: :stocks} = pool) do
    lane = &FeeSchedule.lane(pool.chain, pool.version, &1)
    %{stakers: stakers, regent: regent} = pool.fees

    [
      "## Fees on each trade",
      "- Stakers: #{lane.(:stakers).rate} of the #{pool.currency.symbol} side of every trade. Waiting in the pool now: #{stakers.accrued} #{pool.currency.symbol}. Sent to the staking contract so far: #{stakers.settled_currency} #{pool.currency.symbol}.",
      "- REGENT stakers: #{lane.(:regent).rate} of the #{pool.currency.symbol} side. Waiting in the pool: #{regent.accrued} #{pool.currency.symbol}; swapped so far: #{regent.settled_currency} #{pool.currency.symbol}; " <>
        regent_paid(pool) <> " Not part of #{pool.token.symbol} staking rewards.",
      creator_lane(pool),
      "- Uniswap pool fee: #{lane.(:pool).rate}, earned by the Uniswap Liquidity Pool and sent to stakers when collected.",
      "- Pool fee contract: #{pool.hook}",
      ""
    ]
  end

  defp regent_paid(%{chain: :base} = pool),
    do: "paid into REGENT staking on Base: #{pool.fees.regent.settled_usdc} USDC."

  defp regent_paid(pool),
    do:
      "sent on as USDG: #{pool.fees.regent.settled_usdc} USDG, held on Robinhood Chain until the transfer to Base is set up."

  defp creator_lane(%{version: :v2} = pool) do
    creator = pool.fees.creator
    rate = FeeSchedule.lane(pool.chain, :v2, :creator).rate

    [
      "- Creator: #{rate} of the #{pool.currency.symbol} side, paid to the wallet that launched it. Waiting: #{creator.accrued} #{pool.currency.symbol}; paid so far: #{creator.settled_currency} #{pool.currency.symbol}.",
      pool.vesting &&
        "- Creator's #{pool.token.symbol}: #{pool.vesting.released} released so far, #{pool.vesting.releasable} ready to release to #{pool.vesting.creator}."
    ]
  end

  defp creator_lane(_pool), do: nil

  defp liquidity(pool) do
    [
      "## Uniswap Liquidity Pool",
      "- Pool id: #{pool.pool_id}",
      "- Pool manager: #{pool.pool_manager}",
      pool[:uniswap_url] && "- Uniswap: #{pool.uniswap_url}",
      pool.current &&
        "- Current tick #{pool.current.tick}, current liquidity #{grouped(pool.current.liquidity)}",
      "- Locked forever: the launch's locker holds every position and can never take it out. It is not a price floor.",
      "- Uniswap shows the pool as it is now. Trades move the amounts on each side and other people can add their own liquidity, so Uniswap's numbers can differ from what was deposited at opening.",
      Enum.map(pool.positions, &position(&1, pool)),
      ""
    ]
  end

  defp position(position, pool) do
    [
      "- #{position.label} position ##{position.token_id}",
      "  - Placed at opening: #{position.token_amount} #{pool.token.symbol} and #{position.currency_amount} #{pool.currency.symbol}",
      position.holds &&
        "  - Holds now: #{position.holds.token_amount} #{pool.token.symbol} and #{position.holds.currency_amount} #{pool.currency.symbol}; " <>
          if(position.holds.in_range?,
            do: "earning fees now (the price is inside its range)",
            else: "not earning fees now (the price is outside its range)"
          ),
      "  - Fees waiting to collect: " <> uncollected(position.uncollected, pool),
      "  - " <>
        if(position.locked?,
          do: "Locked by the launch's locker",
          else: "Not held by the launch's locker; owner #{position.owner}"
        )
    ]
  end

  defp settlements(%{kind: :stocks, fees: %{settlements: [_ | _] = settlements}} = pool) do
    [
      "## Settlements so far",
      Enum.map(settlements, fn settlement ->
        "- #{lane_name(settlement.lane)}: #{settlement.currency} #{pool.currency.symbol}" <>
          if(settlement.usdc, do: ", #{settlement.usdc} USDC deposited", else: "") <>
          " at block #{grouped(settlement.block)}, transaction #{settlement.transaction_hash}"
      end),
      ""
    ]
  end

  defp settlements(_pool), do: nil

  defp treasury(%{pool: %{kind: :agent} = pool} = details) do
    vesting = pool.treasury_vesting

    [
      "## Treasury",
      "- Vesting escrow: #{vesting.address}, #{vesting_state(vesting)}",
      "- Sent to the treasury: #{units(vesting.released, vesting)} #{pool.token.symbol}; ready to send: #{units(vesting.releasable, vesting)}; still locked: #{units(vesting.locked, vesting)}",
      security(details.treasury),
      ""
    ]
  end

  defp treasury(_details), do: nil

  defp vesting_state(%{state: :graduated} = vesting),
    do: "vesting in a straight line from #{date(vesting.starts_at)} to #{date(vesting.ends_at)}"

  defp vesting_state(%{state: :pending}), do: "vesting starts when the auction graduates"
  defp vesting_state(%{state: :failed}), do: "nothing vests: the launch did not graduate"

  defp security(:unverified),
    do: "- Treasury security: not available on this local network; custody is unverified here."

  defp security(nil),
    do: "- Treasury security: no current treasury report; custody is unverified."

  defp security(view) do
    "- Treasury security: immutable recipient #{view.address}, " <>
      "#{AutolaunchHelpers.display_action(view.classification)}, awaiting current chain confirmation"
  end

  defp yours(_pool, nil, _position), do: nil
  defp yours(_pool, _wallet, nil), do: nil

  defp yours(pool, wallet, %{} = position) do
    [
      "## Your wallet",
      "- Wallet: #{wallet}",
      "- In your wallet: #{position.balance.shown} #{pool.token.symbol}",
      "- Your stake: #{position.staked.shown} #{pool.token.symbol}",
      Enum.map([:token, :stock, :dollar], fn key ->
        symbol = asset(pool, key).symbol

        "- #{symbol}: #{position.claimable[key].shown} to claim now, #{position.claimed[key].shown} claimed so far"
      end)
    ]
  end

  defp yours(_pool, wallet, :unread),
    do: ["## Your wallet", "- Wallet: #{wallet}", "- Its figures could not be read just now."]

  defp asset(pool, :token), do: pool.token
  defp asset(pool, :stock), do: pool.currency
  defp asset(pool, :dollar), do: pool.fees.splitter.dollar

  defp kind_name(%{kind: :agent}),
    do: "Revstake (stakers share the revenue the launch sends and its trading fees)"

  defp kind_name(%{kind: :stocks}),
    do: "Memestock (a memecoin paired with an onchain stock; stakers earn the stock)"

  defp network(%{chain: :robinhood}), do: "Robinhood Chain"
  defp network(_pool), do: "Base"

  defp split_rule(%{kind: :stocks} = pool),
    do:
      "Regent keeps #{bps_percent(pool.fees.splitter.skim_bps)}; the rest is split by stake between everyone staked when it arrives. With nobody staking, all of it goes to Regent."

  defp split_rule(%{kind: :agent} = pool),
    do:
      "Regent keeps #{bps_percent(pool.fees.splitter.skim_bps)}; stakers get the rest in line with the share of the whole supply that is staked, and the part for unstaked #{pool.token.symbol} goes to the token's treasury."

  defp of_supply(_staked, nil, _pool), do: ""

  defp of_supply(staked, supply, pool) do
    whole = supply |> Decimal.mult(Integer.pow(10, pool.token.decimals)) |> Decimal.to_integer()

    if whole > 0,
      do: " (#{percent(Decimal.div(staked, whole))} of #{whole(supply)})",
      else: ""
  end

  defp fee_total(nil, _pool), do: "still being counted"

  defp fee_total(amount, pool),
    do: "#{amount.currency} #{pool.currency.symbol} and #{amount.token} #{pool.token.symbol}"

  defp price(nil, _pool), do: "not readable right now"

  defp price(%{value: value}, pool),
    do: "#{value} #{pool.currency.symbol} per #{pool.token.symbol}"

  defp uncollected(nil, _pool), do: "not readable right now"

  defp uncollected(fees, pool),
    do:
      "#{fees.token_amount} #{pool.token.symbol} and #{fees.currency_amount} #{pool.currency.symbol}"

  defp unsold(%{disposition: :retired}), do: "retired forever at"
  defp unsold(%{disposition: :escrow}), do: "held by the launch's vesting escrow at"

  defp lane_name(:creator), do: "Paid to the creator"
  defp lane_name(:regent), do: "Converted for REGENT stakers"
  defp lane_name(:stakers), do: "Sent to stakers"

  defp units(amount, %{decimals: decimals}),
    do: Autolaunch.Chain.Rpc.format_units(amount, decimals)

  defp date(unix), do: unix |> DateTime.from_unix!() |> Calendar.strftime("%-d %b %Y")

  defp whole(supply),
    do: supply |> Decimal.round(0, :down) |> Decimal.to_string(:normal) |> Amounts.grouped()

  defp grouped(number), do: Amounts.grouped(Integer.to_string(number))

  defp bps_percent(bps), do: percent(Decimal.div(bps, @bps))

  defp percent(fraction),
    do:
      fraction
      |> Decimal.mult(100)
      |> Decimal.round(4)
      |> Decimal.normalize()
      |> Decimal.to_string(:normal)
      |> Kernel.<>("%")
end
