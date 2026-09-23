defmodule Autolaunch.PriceHistory do
  @moduledoc """
  A graduated token's price since its pool opened, for its chart, read from
  the chain's own logs each time a page asks.

  The PoolManager's `Initialize` log for the pool gives the opening price and
  each `Swap` log the price the trade left behind. Every point is the block its
  log landed in and the price in whole currency per whole token, and the last
  known price is carried to the block the page read at, so the line runs up to
  now. Beside the line come the lowest and highest price and the number of
  trades, all taken before a long history is thinned to 400 evenly spaced
  points, always keeping the first and the last.

  The figures are floats: they draw the line and give the low and the high to
  a few digits, while every exact price a page states keeps coming from its
  exact reads.
  """

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.LabAbi

  @max_points 400
  @q96 Integer.pow(2, 96)
  @token_decimals 18
  @initialize "Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)"
  @swap "Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"

  @type point :: [number()]
  @type history :: %{points: [point()], low: float(), high: float(), trades: non_neg_integer()}

  @doc """
  A pool's price after every trade from `from_block` to the pinned block:
  `[block, price]` pairs for the line, the low, the high and the number of
  trades. `pool` names the PoolManager, the pool id, which side the token is on
  and the currency's decimals. A pool with no logs yet has no history.
  """
  @spec pool(map(), non_neg_integer(), Rpc.block(), keyword()) ::
          {:ok, history() | nil} | {:error, atom()}
  def pool(pool, from_block, block, opts) do
    topics = [[LabAbi.topic(@initialize), LabAbi.topic(@swap)], pool.pool_id]

    with {:ok, logs} <- logs(pool.pool_manager, from_block, block, topics, opts),
         {:ok, points} <-
           points(logs, block, fn log, words ->
             pool_price(sqrt_price(log, words), pool.token_is_currency0?, pool.currency_decimals)
           end) do
      {:ok, history(points, Enum.count(logs, &(topic0(&1) == LabAbi.topic(@swap))))}
    end
  end

  defp history([], _trades), do: nil

  defp history(points, trades) do
    {low, high} = points |> Enum.map(&List.last/1) |> Enum.min_max()
    %{points: thin(points), low: low, high: high, trades: trades}
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

  defp logs(address, from_block, block, topics, opts) do
    filter = %{
      address: address,
      fromBlock: hex(from_block),
      toBlock: hex(block.number),
      topics: topics
    }

    case Rpc.request("eth_getLogs", [filter], opts) do
      {:ok, logs} when is_list(logs) -> {:ok, logs}
      {:ok, _other} -> {:error, :invalid_chain_response}
      error -> error
    end
  end

  # Each log's block and price, in chain order, then the last price carried to
  # the pinned block. A removed log, or one past the pinned block, means the
  # history moved under the read.
  defp points([], _block, _price), do: {:ok, []}

  defp points(logs, block, price) do
    Enum.reduce_while(logs, {:ok, []}, fn log, {:ok, found} ->
      with %{"removed" => false, "blockNumber" => "0x" <> number, "data" => "0x" <> data} <- log,
           {number, ""} when number <= block.number <- Integer.parse(number, 16) do
        {:cont, {:ok, [[number, price.(log, words(data))] | found]}}
      else
        _invalid -> {:halt, {:error, :invalid_chain_response}}
      end
    end)
    |> case do
      {:ok, [[_number, last] | _rest] = found} ->
        {:ok, Enum.reverse([[block.number, last] | found])}

      error ->
        error
    end
  end

  defp thin(points) when length(points) <= @max_points, do: points

  defp thin(points) do
    count = length(points)
    indexed = List.to_tuple(points)

    for step <- 0..(@max_points - 1),
        do: elem(indexed, div(step * (count - 1), @max_points - 1))
  end

  defp topic0(%{"topics" => [topic | _rest]}), do: String.downcase(topic)

  defp words(hex), do: for(<<word::binary-size(64) <- hex>>, do: String.to_integer(word, 16))

  defp hex(value), do: "0x" <> Integer.to_string(value, 16)
end
