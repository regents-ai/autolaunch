defmodule AutolaunchWeb.ShareVideo.Story do
  @moduledoc """
  What a share video tells, read once before it is drawn: the launch's
  clearing price through its auction, its pool price since graduation, and,
  for a wallet, that wallet's own bids, buys, sells, first stake and
  earnings.

  Prices are whole currency per whole token, as floats; they only draw the
  line and count the figures. Every moment is a unix time. Records and
  logs name blocks, so each block is placed in time between the nearest blocks
  the site knows the time of: its bids, its trades and the block the pool was
  read at.

  The site keeps no history of a wallet's earnings, only what it has claimed
  and what it can claim now. The earnings line ends at exactly that sum and
  rises between the stake and now in step with the pool's trading, the
  volume that paid it.
  """

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.{Pool, TokenTrades, WalletHistory}
  alias Autolaunch.Robinhood.Pool, as: RobinhoodPool
  alias Autolaunch.Stocks.StakeActions
  alias AutolaunchWeb.ShareCard.Draw

  @token_decimals 18

  @type t :: map()

  @doc "The token's story as it stands now, for everyone."
  @spec token(struct(), struct()) :: {:ok, t()} | {:error, term()}
  def token(auction, token), do: read(auction, token, nil)

  @doc "The token's story with `wallet`'s own moves in it."
  @spec wallet(struct(), struct(), String.t()) :: {:ok, t()} | {:error, term()}
  def wallet(auction, token, wallet), do: read(auction, token, String.downcase(wallet))

  defp read(auction, token, wallet) do
    with {:ok, supply} <- supply(auction),
         {:ok, pool} <- pool(auction),
         %{points: [_ | _] = history} <- pool.prices || {:error, :no_trading_history},
         {:ok, venue} <- venue(auction),
         {:ok, opened} <- opened(pool, venue),
         {:ok, points} <- Autolaunch.auction_price_points(auction.id, actor: nil),
         {:ok, bids} <- Autolaunch.auction_bids(auction.id, actor: nil),
         {:ok, trades} <- Autolaunch.token_trades(token.id, actor: nil) do
      clock = clock(bids, trades, [opened, {pool.block.number, pool.block.timestamp}])

      story = %{
        auction: auction,
        ticker: Draw.ticker(auction),
        earn_symbol: pool.currency.symbol,
        token_symbol: pool.token.symbol,
        rate: Draw.rate(auction),
        supply: supply,
        auction_line: Enum.map(points, &{clock.(&1.block_number), float(&1.clearing_price)}),
        trade_line: Enum.map(history, fn [block, price] -> {clock.(block), price} end),
        now: pool.block.timestamp,
        marks: [],
        stake: nil
      }

      if wallet,
        do: with_wallet(story, pool, venue, wallet, bids, trades, clock),
        else: {:ok, story}
    end
  end

  defp supply(%{token_supply: %Decimal{} = supply}), do: {:ok, Decimal.to_float(supply)}
  defp supply(_auction), do: {:error, :supply_unknown}

  defp pool(auction) do
    if Draw.chain(auction) == :robinhood,
      do: RobinhoodPool.read(auction),
      else: Pool.read(auction)
  end

  # The wallet's bids on the auction's staircase, its buys and sells on the
  # pool's line, its first stake and what it has earned since.
  defp with_wallet(story, pool, venue, wallet, bids, trades, clock) do
    with {:ok, moved} <-
           WalletHistory.transfers(
             pool.token.address,
             wallet,
             pool.logs_from,
             pool.block,
             venue.opts
           ),
         {:ok, stakes} <-
           WalletHistory.stakes(
             pool.fees.splitter.address,
             wallet,
             pool.logs_from,
             pool.block,
             venue.opts
           ),
         {:ok, position} <- StakeActions.position(pool, wallet) do
      bid_marks =
        for bid <- bids, bid.bidder == wallet do
          %{at: clock.(bid.block_number), side: :buy, verb: "Bid", amount: bid_amount(bid, story)}
        end

      trade_marks =
        for trade <- trades, mark = trade_mark(trade, moved), mark do
          Map.merge(mark, %{
            at: clock.(trade.block_number),
            amount: Draw.money(trade.currency_amount, story.rate, story.auction)
          })
        end

      {:ok,
       %{
         story
         | marks: Enum.sort_by(bid_marks ++ trade_marks, & &1.at),
           stake: stake(stakes, position, trades, story, clock)
       }}
    end
  end

  defp venue(auction) do
    case TokenTrades.venue(auction) do
      {:ok, venue} -> {:ok, venue}
      _other -> {:error, :chain_unavailable}
    end
  end

  # The block the pool opened in, with its time.
  defp opened(pool, venue) do
    case Rpc.request(
           "eth_getBlockByNumber",
           ["0x" <> Integer.to_string(pool.logs_from, 16), false],
           venue.opts
         ) do
      {:ok, %{"timestamp" => "0x" <> seconds}} ->
        {:ok, {pool.logs_from, String.to_integer(seconds, 16)}}

      {:ok, _other} ->
        {:error, :invalid_chain_response}

      error ->
        error
    end
  end

  defp trade_mark(%{side: :buy, transaction_hash: hash}, moved),
    do: if(MapSet.member?(moved.received, hash), do: %{side: :buy, verb: "Bought"})

  defp trade_mark(%{side: :sell, transaction_hash: hash}, moved),
    do: if(MapSet.member?(moved.sent, hash), do: %{side: :sell, verb: "Sold"})

  # A bid paid in the auction's own currency reads like every other figure;
  # one paid through another currency is shown in that currency.
  defp bid_amount(bid, story) do
    cond do
      bid.display_symbol == story.auction.quote_token_symbol ->
        Draw.money(bid.display_amount, story.rate, story.auction)

      bid.display_symbol in ["USDC", "USDG"] ->
        "$" <> Draw.short(bid.display_amount)

      true ->
        Draw.short(bid.display_amount) <> " " <> bid.display_symbol
    end
  end

  defp stake([], _position, _trades, _story, _clock), do: nil

  defp stake([first | _later], position, trades, story, clock) do
    at = clock.(first.block_number)
    decimals = position.claimable.stock.decimals
    earned = (position.claimed.stock.atomic + position.claimable.stock.atomic) / 10 ** decimals

    %{
      at: at,
      first: tokens(first.amount),
      staked: tokens(position.staked.atomic),
      earned: earned,
      earned_curve: earned_curve(at, story.now, trades, clock)
    }
  end

  defp tokens(atomic), do: atomic / 10 ** @token_decimals

  # The share of the earnings reached at each trade after the stake: the
  # trading volume so far over the volume until now.
  defp earned_curve(from, now, trades, clock) do
    volumes =
      for trade <- trades,
          (at = clock.(trade.block_number)) > from,
          do: {at, Decimal.to_float(trade.currency_amount)}

    total = volumes |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    if total > 0 do
      {steps, _sum} =
        Enum.map_reduce(volumes, 0.0, fn {at, volume}, sum ->
          {{at, (sum + volume) / total}, sum + volume}
        end)

      [{from, 0.0} | steps] ++ [{now, 1.0}]
    else
      [{from, 0.0}, {now, 1.0}]
    end
  end

  # A block's time: between the two nearest blocks of known time, or along
  # the nearest two at either end. The pool's opening block and the block it
  # was read at are always known, and they are never the same block.
  defp clock(bids, trades, blocks) do
    known =
      (Enum.map(bids, &{&1.block_number, DateTime.to_unix(&1.occurred_at)}) ++
         Enum.map(trades, &{&1.block_number, DateTime.to_unix(&1.occurred_at)}) ++ blocks)
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.sort()
      |> List.to_tuple()

    fn number -> place(known, number) end
  end

  defp place(known, number) do
    last = tuple_size(known) - 1
    index = Enum.find(1..last, last, fn index -> elem(elem(known, index), 0) >= number end)
    {block_a, time_a} = elem(known, index - 1)
    {block_b, time_b} = elem(known, index)
    time_a + (number - block_a) * (time_b - time_a) / (block_b - block_a)
  end

  defp float(%Decimal{} = value), do: Decimal.to_float(value)
end
