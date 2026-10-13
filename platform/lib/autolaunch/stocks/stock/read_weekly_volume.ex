defmodule Autolaunch.Stocks.Stock.ReadWeeklyVolume do
  @moduledoc """
  Reads a stock's trading volume over the last seven whole UTC days from
  GeckoTerminal, before the row is written and outside any transaction.

  The volume is that of the stock's pools against the chain's dollar token
  (USDC on Base, USDG on Robinhood), summed from each pool's daily candles: a
  pool against another token is mostly that token's trading, not the stock's.
  GeckoTerminal lists a token's pools twenty to a page, busiest first, and its
  free service shows the first ten pages. Pages are offsets into a list that
  can reorder while it is read, so only a list that ends on its first page is
  known whole; a longer read counts the pools it saw and is stored as a floor.

  A read that finds no dollar pool or no trade in the week, or any answer that
  is refused or not in the expected shape, fails the action and stores
  nothing; the trigger's next run tries again. Each read is bounded
  (`Autolaunch.Stocks.GeckoTerminal`), and one still going after the trigger's
  fifteen minutes is stopped and stores nothing.
  """

  use Ash.Resource.Change

  alias Autolaunch.Stocks.GeckoTerminal

  @page_size 20
  @last_free_page 10

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      stock = changeset.data
      through = Date.add(Date.utc_today(), -1)

      case volume(stock.chain_id, String.downcase(stock.address), through) do
        {:ok, usd, complete?} ->
          changeset
          |> Ash.Changeset.force_change_attribute(:weekly_volume_usd, usd)
          |> Ash.Changeset.force_change_attribute(:weekly_volume_complete, complete?)
          |> Ash.Changeset.force_change_attribute(:weekly_volume_through, through)

        {:error, reason} ->
          Ash.Changeset.add_error(changeset, "weekly volume read failed: #{inspect(reason)}")
      end
    end)
  end

  defp volume(chain_id, token, through) do
    {network, dollar} = GeckoTerminal.network(chain_id)
    first = Date.add(through, -6)

    with {:ok, pools, complete?} <- dollar_pools(network, token, dollar, 1, []),
         {:ok, sum} <-
           Enum.reduce_while(
             pools,
             {:ok, Decimal.new(0)},
             &add_pool(&1, &2, network, first, through)
           ),
         usd = Decimal.round(sum, 2),
         # Pools that answer with no trade all week, or with less than half a
         # cent, give no figure, not $0.00.
         true <- Decimal.gt?(usd, 0) || {:error, :no_trade_in_week} do
      {:ok, usd, complete?}
    end
  end

  # The list's pages in turn, until one comes back short or the last free one
  # is read. A pool that moves between pages while they are read counts once,
  # and one that moves onto a page already read is missed: only a short first
  # page lists every pool.
  defp dollar_pools(network, token, dollar, page, found) do
    case GeckoTerminal.get("/networks/#{network}/tokens/#{token}/pools?page=#{page}") do
      {:ok, %{"data" => pools}} when is_list(pools) ->
        found = found ++ Enum.filter(pools, &dollar_pool?(&1, network, token, dollar))

        cond do
          length(pools) < @page_size -> listed(found, page == 1)
          page == @last_free_page -> listed(found, false)
          true -> dollar_pools(network, token, dollar, page + 1, found)
        end

      {:ok, _body} ->
        {:error, {:unexpected_answer, page}}

      error ->
        error
    end
  end

  # No dollar pool listed means no figure, not a week without trades.
  defp listed([], _complete?), do: {:error, :no_dollar_pool}

  defp listed(pools, complete?),
    do: {:ok, Enum.uniq_by(pools, &get_in(&1, ["attributes", "address"])), complete?}

  # Every pool must answer: a sum missing one is not the stock's volume.
  defp add_pool(pool, {:ok, sum}, network, first, through) do
    case pool_volume(network, pool["attributes"]["address"], first, through) do
      {:ok, usd} -> {:cont, {:ok, Decimal.add(sum, usd)}}
      error -> {:halt, error}
    end
  end

  # A pool of the stock against the dollar token, either way round.
  defp dollar_pool?(pool, network, token, dollar),
    do: GeckoTerminal.pair(pool) == Enum.sort(["#{network}_#{token}", "#{network}_#{dollar}"])

  # Each candle is [start, open, high, low, close, volume in USD]; a day with
  # no trades has no candle. One candle of any other shape fails the read, and
  # so does a pool address that is not one: 20 bytes, a 32-byte pool id, or
  # Ekubo's core contract and 32-byte pool id joined by a dash.
  defp pool_volume(network, pool, first, through) when is_binary(pool) do
    if pool =~ ~r/\A0x[0-9a-f]{40}([0-9a-f]{24}|-0x[0-9a-f]{64})?\z/i,
      do: pool_candles(network, pool, first, through),
      else: {:error, :malformed_pool}
  end

  defp pool_volume(_network, _pool, _first, _through), do: {:error, :malformed_pool}

  defp pool_candles(network, pool, first, through) do
    path = "/networks/#{network}/pools/#{pool}/ohlcv/day?aggregate=1&limit=8&currency=usd"

    case GeckoTerminal.get(path) do
      {:ok, %{"data" => %{"attributes" => %{"ohlcv_list" => candles}}}} when is_list(candles) ->
        if Enum.all?(candles, &candle?/1),
          do: {:ok, week_volume(candles, first, through)},
          else: {:error, {:malformed_candles, pool}}

      {:ok, _body} ->
        {:error, {:unexpected_answer, pool}}

      error ->
        error
    end
  end

  defp candle?([start, open, high, low, close, usd]) when is_integer(start),
    do: Enum.all?([open, high, low, close, usd], &(is_number(&1) and &1 >= 0))

  defp candle?(_candle), do: false

  defp week_volume(candles, first, through) do
    for [start, _open, _high, _low, _close, usd] <- candles,
        day = start |> DateTime.from_unix!() |> DateTime.to_date(),
        Date.compare(day, first) != :lt and Date.compare(day, through) != :gt,
        reduce: Decimal.new(0) do
      sum -> usd |> to_decimal() |> Decimal.add(sum)
    end
  end

  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
end
