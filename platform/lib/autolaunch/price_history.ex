defmodule Autolaunch.PriceHistory do
  @moduledoc """
  A graduated token's price since its pool opened, for its chart, read from
  the chain's own logs each time a page asks.

  The PoolManager's `Initialize` log for the pool gives the opening price and
  each `Swap` log the price the trade left behind. The history holds two lines
  of the same prices. `points` has one `[block, price]` pair per log, the last
  price carried to the block the page read at, thinned to 400 evenly spaced
  points that always keep the first and the last. `times` has 100 `[unix
  seconds, price]` pairs evenly spaced from the first log's time to the read
  block's time, each the price the last trade at or before it left. Beside the
  lines come the lowest and highest price and the number of trades, taken from
  every log.

  The figures are floats: they draw the line and give the low and the high to
  a few digits, while every exact price a page states keeps coming from its
  exact reads.
  """

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.LabAbi

  @max_points 400
  @time_points 100
  @q96 Integer.pow(2, 96)
  @token_decimals 18
  @initialize "Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)"
  @swap "Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"

  @type point :: [number()]
  @type history :: %{
          points: [point()],
          times: [point()],
          low: float(),
          high: float(),
          trades: non_neg_integer()
        }

  @doc """
  A pool's price after every trade from `from_block` to the pinned block: the
  line by trade, the line by time, the low, the high and the number of trades.
  `pool` names the PoolManager, the pool id, which side the token is on and
  the currency's decimals. A pool with no logs yet has no history.
  """
  @spec pool(map(), non_neg_integer(), Rpc.block(), keyword()) ::
          {:ok, history() | nil} | {:error, atom()}
  def pool(pool, from_block, block, opts) do
    topics = [[LabAbi.topic(@initialize), LabAbi.topic(@swap)], pool.pool_id]

    with {:ok, logs} <- Rpc.logs(pool.pool_manager, topics, from_block, block.number, opts),
         {:ok, moments} <-
           moments(logs, block, fn log, words ->
             pool_price(sqrt_price(log, words), pool.token_is_currency0?, pool.currency_decimals)
           end) do
      {:ok, history(moments, block, Enum.count(logs, &(topic0(&1) == LabAbi.topic(@swap))))}
    end
  end

  defp history([], _block, _trades), do: nil

  defp history(moments, block, trades) do
    {low, high} = moments |> Enum.map(fn {_number, _at, price} -> price end) |> Enum.min_max()
    {_number, _at, last} = List.last(moments)
    points = Enum.map(moments, fn {number, _at, price} -> [number, price] end)

    %{
      points: thin(points ++ [[block.number, last]]),
      times: times(moments, block.timestamp),
      low: low,
      high: high,
      trades: trades
    }
  end

  # `Initialize` carries the opening price in its fourth data word, `Swap` the
  # price after the trade in its third.
  defp sqrt_price(log, words) do
    if topic0(log) == LabAbi.topic(@initialize), do: Enum.at(words, 3), else: Enum.at(words, 2)
  end

  # `sqrtPriceX96` squared is currency1 base units per currency0 base unit.
  defp pool_price(sqrt_price, token_is_currency0?, currency_decimals) do
    ratio = :math.pow(sqrt_price / @q96, 2)
    per_base_unit = if token_is_currency0?, do: ratio, else: 1 / ratio
    per_base_unit * :math.pow(10, @token_decimals - currency_decimals)
  end

  # Each log's block, time and price, in chain order. A removed log, one past
  # the pinned block, or one without its block's time means the history moved
  # under the read.
  defp moments(logs, block, price) do
    Enum.reduce_while(logs, {:ok, []}, fn log, {:ok, found} ->
      with %{
             "removed" => false,
             "blockNumber" => "0x" <> number,
             "blockTimestamp" => "0x" <> at,
             "data" => "0x" <> data
           } <- log,
           {number, ""} when number <= block.number <- Integer.parse(number, 16),
           {at, ""} <- Integer.parse(at, 16) do
        {:cont, {:ok, [{number, at, price.(log, words(data))} | found]}}
      else
        _invalid -> {:halt, {:error, :invalid_chain_response}}
      end
    end)
    |> case do
      {:ok, found} -> {:ok, Enum.reverse(found)}
      error -> error
    end
  end

  # The price at evenly spaced moments from the first log to `now`.
  defp times([{_number, opened, _price} | _rest] = moments, now) do
    span = max(now - opened, 0)

    0..(@time_points - 1)
    |> Enum.map(&(opened + div(span * &1, @time_points - 1)))
    |> sample(moments, nil, [])
  end

  defp sample([], _moments, _price, found), do: Enum.reverse(found)

  defp sample([at | _later] = moments_at, [{_number, time, price} | rest], _last, found)
       when time <= at,
       do: sample(moments_at, rest, price, found)

  defp sample([at | later], moments, price, found),
    do: sample(later, moments, price, [[at, price] | found])

  defp thin(points) when length(points) <= @max_points, do: points

  defp thin(points) do
    count = length(points)
    indexed = List.to_tuple(points)

    for step <- 0..(@max_points - 1),
        do: elem(indexed, div(step * (count - 1), @max_points - 1))
  end

  defp topic0(%{"topics" => [topic | _rest]}), do: String.downcase(topic)

  defp words(hex), do: for(<<word::binary-size(64) <- hex>>, do: String.to_integer(word, 16))
end
