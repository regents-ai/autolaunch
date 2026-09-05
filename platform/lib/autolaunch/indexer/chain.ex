defmodule Autolaunch.Indexer.Chain do
  @moduledoc """
  The exact public evidence this ledger will accept from a JSON-RPC provider.

  Nothing reaches a row before it is normalized here: the chain is Base mainnet,
  a header carries a well-formed hash, parent hash and nonnegative height, and a
  log carries a canonical emitter, topic set and payload. Anything else is
  malformed and advances nothing.

  The ingest edge is the provider's `safe` head, never `latest`, and finality is
  a separately obtained `finalized` header rather than a depth guess.
  """

  alias Autolaunch.Chain.Address
  alias Autolaunch.Indexer.Rpc

  @chain_id 8453

  @spec chain_id() :: pos_integer()
  def chain_id, do: @chain_id

  @spec verify_chain() :: :ok | {:error, atom()}
  def verify_chain do
    case Rpc.request("eth_chainId", []) do
      {:ok, result} -> base_mainnet(quantity(result))
      {:error, reason} -> {:error, reason}
    end
  end

  @spec address(term()) :: {:ok, String.t()} | {:error, :malformed}
  def address(value) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> {:error, :malformed}
    end
  end

  @doc "The header at a provider tag or an exact height."
  @spec header(String.t() | non_neg_integer()) :: {:ok, map()} | {:error, atom()}
  def header(tag) when tag in ["safe", "finalized"], do: block_by_number(tag)
  def header(number) when is_integer(number), do: block_by_number(hex(number))

  @doc """
  Every header in a contiguous inclusive range, in ascending height order.

  The first failure ends the range: a pass that cannot complete must not spend
  the rest of its request budget discovering that.
  """
  @spec headers(non_neg_integer(), non_neg_integer()) :: {:ok, [map()]} | {:error, atom()}
  def headers(from, to) do
    from..to//1
    |> Enum.reduce_while({:ok, []}, fn number, {:ok, headers} ->
      case header(number) do
        {:ok, header} -> {:cont, {:ok, [header | headers]}}
        error -> {:halt, error}
      end
    end)
    |> in_order()
  end

  @doc "Every log the admitted addresses emitted inside a contiguous range."
  @spec logs(non_neg_integer(), non_neg_integer(), [String.t()]) ::
          {:ok, [map()]} | {:error, atom()}
  def logs(from, to, addresses) do
    "eth_getLogs"
    |> Rpc.request([
      %{"fromBlock" => hex(from), "toBlock" => hex(to), "address" => addresses}
    ])
    |> normalize_logs()
  end

  defp base_mainnet({:ok, @chain_id}), do: :ok
  defp base_mainnet(_other), do: {:error, :wrong_chain}

  defp block_by_number(block) do
    case Rpc.request("eth_getBlockByNumber", [block, false]) do
      {:ok, result} -> normalize_header(result)
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_header(%{"number" => number, "hash" => hash, "parentHash" => parent}) do
    with {:ok, number} <- quantity(number),
         {:ok, hash} <- hash(hash),
         {:ok, parent} <- hash(parent) do
      {:ok, %{number: number, hash: hash, parent_hash: parent}}
    end
  end

  defp normalize_header(_malformed), do: {:error, :malformed}

  defp normalize_logs({:error, reason}), do: {:error, reason}
  defp normalize_logs({:ok, results}) when is_list(results), do: normalized(results)
  defp normalize_logs({:ok, _malformed}), do: {:error, :malformed}

  defp normalized(results), do: results |> Enum.map(&normalize_log/1) |> all_ok()

  defp normalize_log(result) when is_map(result) do
    with {:ok, placement} <- placement(result),
         {:ok, emission} <- emission(result) do
      {:ok, Map.merge(placement, emission)}
    end
  end

  defp normalize_log(_malformed), do: {:error, :malformed}

  defp placement(%{
         "blockHash" => block_hash,
         "logIndex" => log_index,
         "transactionHash" => transaction_hash,
         "transactionIndex" => transaction_index
       }) do
    with {:ok, block_hash} <- hash(block_hash),
         {:ok, log_index} <- quantity(log_index),
         {:ok, transaction_hash} <- hash(transaction_hash),
         {:ok, transaction_index} <- quantity(transaction_index) do
      {:ok,
       %{
         block_hash: block_hash,
         log_index: log_index,
         transaction_hash: transaction_hash,
         transaction_index: transaction_index
       }}
    end
  end

  defp placement(_malformed), do: {:error, :malformed}

  # A log the provider has retracted is not evidence of anything, so a pass that
  # is handed one stops rather than storing it or quietly dropping it.
  defp emission(%{"removed" => true}), do: {:error, :removed_log}

  defp emission(%{"address" => address, "topics" => topics, "data" => data, "removed" => false})
       when is_list(topics) and length(topics) <= 4 do
    with {:ok, address} <- address(address),
         {:ok, topics} <- topics |> Enum.map(&hash/1) |> all_ok(),
         {:ok, data} <- payload(data) do
      {:ok, %{address: address, topics: topics, data: data}}
    end
  end

  defp emission(_malformed), do: {:error, :malformed}

  defp hash("0x" <> digits = value) when byte_size(digits) == 64 do
    if String.match?(digits, ~r/\A[0-9a-fA-F]+\z/),
      do: {:ok, String.downcase(value)},
      else: {:error, :malformed}
  end

  defp hash(_value), do: {:error, :malformed}

  defp payload("0x" <> digits = value) when rem(byte_size(digits), 2) == 0 do
    if String.match?(digits, ~r/\A[0-9a-fA-F]*\z/),
      do: {:ok, String.downcase(value)},
      else: {:error, :malformed}
  end

  defp payload(_value), do: {:error, :malformed}

  defp quantity("0x" <> digits) when digits != "" do
    case Integer.parse(digits, 16) do
      {value, ""} -> {:ok, value}
      _malformed -> {:error, :malformed}
    end
  end

  defp quantity(_value), do: {:error, :malformed}

  defp hex(number), do: "0x" <> String.downcase(Integer.to_string(number, 16))

  defp all_ok(results) do
    results
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, value}, {:ok, values} -> {:cont, {:ok, [value | values]}}
      error, _values -> {:halt, error}
    end)
    |> in_order()
  end

  defp in_order({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp in_order(error), do: error
end
