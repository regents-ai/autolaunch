defmodule Autolaunch.Stocks.Stock.ReadWeeklyVolume do
  @moduledoc """
  Reads a stock's trading volume over the last seven whole UTC days from
  GeckoTerminal, before the row is written and outside any transaction.

  The volume is that of the stock's pools against the chain's dollar token
  (USDC on Base, USDG on Robinhood), summed from each pool's daily candles: a
  pool against another token is mostly that token's trading, not the stock's.
  The pools are the first page GeckoTerminal lists for the token, which holds
  its deepest ones. A failed read fails the action, and the trigger's next run
  tries again.
  """

  use Ash.Resource.Change

  @api "https://api.geckoterminal.com/api/v2"

  # GeckoTerminal's network name and the launchpad's dollar token, by chain.
  @networks %{
    8453 => {"base", "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"},
    4663 => {"robinhood", "0x5fc5360d0400a0fd4f2af552add042d716f1d168"}
  }

  @doc "The chains GeckoTerminal reports on."
  def chain_ids, do: Map.keys(@networks)

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      stock = changeset.data
      through = Date.add(Date.utc_today(), -1)

      case volume(stock.chain_id, String.downcase(stock.address), through) do
        {:ok, usd} ->
          changeset
          |> Ash.Changeset.force_change_attribute(:weekly_volume_usd, usd)
          |> Ash.Changeset.force_change_attribute(:weekly_volume_through, through)

        {:error, reason} ->
          Ash.Changeset.add_error(changeset, "weekly volume read failed: #{inspect(reason)}")
      end
    end)
  end

  defp volume(chain_id, token, through) do
    {network, dollar} = Map.fetch!(@networks, chain_id)
    first = Date.add(through, -6)

    with {:ok, %{"data" => pools}} <- get("/networks/#{network}/tokens/#{token}/pools?page=1"),
         {:ok, sum} <-
           pools
           |> Enum.filter(&dollar_pool?(&1, network, token, dollar))
           |> Enum.reduce_while({:ok, Decimal.new(0)}, &add_pool(&1, &2, network, first, through)) do
      {:ok, Decimal.round(sum, 2)}
    end
  end

  # Every pool must answer: a sum missing one is not the stock's volume.
  defp add_pool(pool, {:ok, sum}, network, first, through) do
    case pool_volume(network, pool["attributes"]["address"], first, through) do
      {:ok, usd} -> {:cont, {:ok, Decimal.add(sum, usd)}}
      error -> {:halt, error}
    end
  end

  # A pool of the stock against the dollar token, either way round.
  defp dollar_pool?(%{"relationships" => relationships}, network, token, dollar) do
    sides =
      Enum.map(~w(base_token quote_token), fn side ->
        relationships |> get_in([side, "data", "id"]) |> to_string() |> String.downcase()
      end)

    Enum.sort(sides) == Enum.sort(["#{network}_#{token}", "#{network}_#{dollar}"])
  end

  defp dollar_pool?(_pool, _network, _token, _dollar), do: false

  # Each candle is [start, open, high, low, close, volume in USD]; a day with
  # no trades has no candle.
  defp pool_volume(network, pool, first, through) do
    path = "/networks/#{network}/pools/#{pool}/ohlcv/day?aggregate=1&limit=8&currency=usd"

    with {:ok, %{"data" => %{"attributes" => %{"ohlcv_list" => candles}}}} <- get(path) do
      {:ok,
       for [start | rest] <- candles,
           day = start |> DateTime.from_unix!() |> DateTime.to_date(),
           Date.compare(day, first) != :lt and Date.compare(day, through) != :gt,
           reduce: Decimal.new(0) do
         sum -> rest |> List.last() |> to_decimal() |> Decimal.add(sum)
       end}
    end
  end

  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)

  # GeckoTerminal's free service allows about ten reads a minute, so a refusal
  # waits half a minute, then a minute. A stock's few reads stay well inside
  # the ten minutes after which a running job counts as stuck.
  defp get(path) do
    case Req.get(@api <> path,
           headers: [accept: "application/json"],
           connect_options: [timeout: 5_000],
           receive_timeout: 15_000,
           retry: :transient,
           retry_delay: &(&1 * 30_000 + 30_000),
           max_retries: 2,
           retry_log_level: false
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end
end
