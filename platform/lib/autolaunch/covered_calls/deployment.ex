defmodule Autolaunch.CoveredCalls.Deployment do
  @moduledoc """
  Whether covered calls are on, and the description of their contracts:
  `AUTOLAUNCH_BASE_COVERED_CALLS_DEPLOYMENT` names a JSON file with one
  `CoveredCallsV1` contract per stock.

      {"chain_id": 8453,
       "markets": [{"symbol": "AMZNc",
                    "stock": "0xb2…",
                    "contract": "0x…",
                    "feed": "0x06A8…"}]}

  Covered calls are on only when `AUTOLAUNCH_COVERED_CALLS=true`, and then the
  description is required (`config/runtime.exs`). They extend the Base
  deployment (`Autolaunch.Lab`): the description must name its chain, and every
  read and step goes through its RPC doors. Off, the pages answer not found and
  no tool or route offers them.
  """

  alias Autolaunch.Lab
  alias RegentChain.Address

  @market_keys ~w(contract feed stock symbol)

  @type market :: %{
          symbol: String.t(),
          stock: String.t(),
          contract: String.t(),
          feed: String.t()
        }

  @doc "Whether this site offers covered calls."
  def enabled?, do: Application.get_env(:autolaunch, :covered_calls, :off) == :on

  @doc "The markets, each with the Base deployment's chain and doors, or why there are none."
  @spec current() ::
          {:ok, %{chain_id: pos_integer(), markets: [market()], lab: map()}}
          | {:error, atom()}
  def current do
    with true <- enabled?() || {:error, :covered_calls_off},
         path when is_binary(path) <-
           Application.get_env(:autolaunch, :autolaunch_base_covered_calls_deployment) ||
             {:error, :covered_calls_deployment_missing},
         {:ok, lab} <- Lab.current(),
         {:ok, config} <- Lab.loaded(__MODULE__, path),
         true <- config.chain_id == lab.chain_id || {:error, :base_deployment_mismatch} do
      {:ok, Map.put(config, :lab, lab)}
    end
  end

  @doc "The market for `symbol`, matched exactly as the description writes it."
  @spec market(String.t()) :: {:ok, market()} | {:error, :unknown_market | atom()}
  def market(symbol) when is_binary(symbol) do
    with {:ok, config} <- current() do
      case Enum.find(config.markets, &(&1.symbol == symbol)) do
        nil -> {:error, :unknown_market}
        market -> {:ok, market}
      end
    end
  end

  def market(_symbol), do: {:error, :unknown_market}

  def load!(path) do
    case load(path) do
      {:ok, config} -> config
      {:error, reason} -> raise "Autolaunch covered calls description is invalid: #{reason}"
    end
  end

  # Founder-supplied startup input; this path never comes from an HTTP request.
  # sobelow_skip ["Traversal.FileModule"]
  def load(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         {:ok, body} <- File.read(path),
         {:ok, %{"chain_id" => chain_id, "markets" => markets} = decoded}
         when map_size(decoded) == 2 <- Jason.decode(body),
         {:ok, chain_id} <- Lab.chain_id(chain_id),
         {:ok, markets} <- markets(markets) do
      {:ok, %{path: path, chain_id: chain_id, markets: markets}}
    else
      false -> {:error, :absolute_path_required}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, :enoent} -> {:error, :missing_file}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_shape}
    end
  end

  def load(_path), do: {:error, :absolute_path_required}

  defp markets([_ | _] = markets) do
    markets
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, kept} ->
      case market_entry(entry) do
        {:ok, market} -> {:cont, {:ok, [market | kept]}}
        :error -> {:halt, {:error, :invalid_markets}}
      end
    end)
    |> case do
      {:ok, kept} ->
        kept = Enum.reverse(kept)
        symbols = Enum.map(kept, & &1.symbol)
        if Enum.uniq(symbols) == symbols, do: {:ok, kept}, else: {:error, :invalid_markets}

      error ->
        error
    end
  end

  defp markets(_markets), do: {:error, :invalid_markets}

  defp market_entry(%{"symbol" => symbol} = entry) when is_binary(symbol) and symbol != "" do
    with true <- Enum.sort(Map.keys(entry)) == @market_keys,
         {:ok, stock} <- Address.normalize(entry["stock"]),
         {:ok, contract} <- Address.normalize(entry["contract"]),
         {:ok, feed} <- Address.normalize(entry["feed"]) do
      {:ok, %{symbol: symbol, stock: stock, contract: contract, feed: feed}}
    else
      _ -> :error
    end
  end

  defp market_entry(_entry), do: :error
end
