defmodule Autolaunch.PriceHistory do
  @moduledoc """
  A launch's price over time, for its chart, read from the chain's own logs
  each time a page asks.

  A graduated token's price is its pool's price after every trade: the
  PoolManager's `Initialize` log for the pool gives the opening price and each
  `Swap` log the price the trade left behind. An auction's price is its
  clearing price, which it logs as `CheckpointUpdated` whenever a checkpoint
  moves it. Every point is the block its log landed in and the price in whole
  currency per whole token, and the last known price is carried to the block
  the page read at, so the line runs up to now.

  The figures only draw a line: they are floats, and every price a page states
  in words keeps coming from its exact reads. A long history is thinned to
  400 evenly spaced points, always keeping the first and the last.
  """

  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.Lab
  alias Autolaunch.LabAbi
  alias Autolaunch.LabRpc
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Stocks.Lab, as: StocksLab

  @max_points 400
  @q96 Integer.pow(2, 96)
  @token_decimals 18
  @initialize "Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)"
  @swap "Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"
  @checkpoint "CheckpointUpdated(uint256,uint256,uint24)"

  @type point :: [number()]

  @doc """
  A pool's price after every trade from `from_block` to the pinned block, as
  `[block, price]` pairs. `pool` names the PoolManager, the pool id, which side
  the token is on and the currency's decimals.
  """
  @spec pool(map(), non_neg_integer(), Rpc.block(), keyword()) ::
          {:ok, [point()]} | {:error, atom()}
  def pool(pool, from_block, block, opts) do
    topics = [[LabAbi.topic(@initialize), LabAbi.topic(@swap)], pool.pool_id]

    with {:ok, logs} <- logs(pool.pool_manager, from_block, block, topics, opts) do
      points(logs, block, fn log, words ->
        pool_price(sqrt_price(log, words), pool.token_is_currency0?, pool.currency_decimals)
      end)
    end
  end

  @doc "A Base auction's clearing price since bidding opened, read at the latest block."
  @spec base_auction(map()) :: {:ok, [point()]} | {:error, atom()}
  def base_auction(%{auction_address: address, quote_token_decimals: decimals} = auction)
      when is_binary(address) do
    with {:ok, opts} <- base_opts(auction),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, start} <- Rpc.call_uint(address, LabAbi.selector("startBlock()"), block, opts),
         do: auction(address, decimals, start, block, opts)
  end

  def base_auction(_auction), do: {:error, :no_auction_contract}

  @doc """
  A Robinhood auction's clearing price since it was created, read at the
  latest block by its address alone: the auction names its currency, and the
  currency its decimals. Its contracts keep time by the rollup clock, not by
  the block numbers logs carry, so its logs are read from the chain's start.
  """
  @spec robinhood_auction(String.t()) :: {:ok, [point()]} | {:error, atom()}
  def robinhood_auction(address) when is_binary(address) do
    with {:ok, config} <- RobinhoodLab.current(),
         opts = RobinhoodLab.rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, currency} <- Rpc.call_uint(address, LabAbi.selector("currency()"), block, opts),
         {:ok, currency} <- Abi.word_address(currency),
         {:ok, decimals} <- Rpc.call_uint(currency, LabAbi.selector("decimals()"), block, opts) do
      auction(address, decimals, 0, block, opts)
    else
      :error -> {:error, :invalid_chain_response}
      error -> error
    end
  end

  defp auction(address, currency_decimals, from_block, block, opts) do
    with {:ok, logs} <- logs(address, from_block, block, [LabAbi.topic(@checkpoint)], opts) do
      points(logs, block, fn _log, [_block, clearing_q96, _mps] ->
        clearing_q96 / @q96 * :math.pow(10, @token_decimals - currency_decimals)
      end)
    end
  end

  defp base_opts(%{kind: :agent}) do
    with {:ok, config} <- Lab.current(),
         do: {:ok, LabRpc.opts(config, "autolaunch price chart")}
  end

  defp base_opts(%{kind: :stocks}) do
    with {:ok, config} <- StocksLab.current(),
         do: {:ok, StocksLab.rpc_opts(config, "autolaunch price chart")}
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
        {:ok, thin(Enum.reverse([[block.number, last] | found]))}

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
