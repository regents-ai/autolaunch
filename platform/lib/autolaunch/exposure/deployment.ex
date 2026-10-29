defmodule Autolaunch.Exposure.Deployment do
  @moduledoc """
  Whether Exposure is on, and the description of its contracts:
  `AUTOLAUNCH_BASE_EXPOSURE_DEPLOYMENT` names a JSON file listing every
  `ExposureSeriesV1` the site offers, oldest first, with the USDC and the
  Aerodrome pool factory its legs trade against.

      {"chain_id": 8453,
       "usdc": "0x8335…",
       "pool_factory": "0x420D…",
       "series": ["0x77b8…"]}

  Exposure is on only when `AUTOLAUNCH_EXPOSURE=true`, and then the
  description is required (`config/runtime.exs`). It extends the Base
  deployment (`Autolaunch.Lab`): the description must name its chain, and every
  read and step goes through its RPC doors. Off, the page and the routes answer
  not found and no tool offers it. Everything else about a series (its stock,
  legs, oracle, schedule and terms) is read from the series itself.
  """

  alias Autolaunch.Lab
  alias RegentChain.Address

  @keys ~w(chain_id pool_factory series usdc)

  @doc "Whether this site offers Exposure."
  def enabled?, do: Application.get_env(:autolaunch, :exposure, :off) == :on

  @doc "The description, with the Base deployment it extends, or why there is none."
  @spec current() ::
          {:ok,
           %{
             chain_id: pos_integer(),
             usdc: String.t(),
             pool_factory: String.t(),
             series: [String.t()],
             lab: map()
           }}
          | {:error, atom()}
  def current do
    with true <- enabled?() || {:error, :exposure_off},
         path when is_binary(path) <-
           Application.get_env(:autolaunch, :autolaunch_base_exposure_deployment) ||
             {:error, :exposure_deployment_missing},
         {:ok, lab} <- Lab.current(),
         {:ok, config} <- Lab.loaded(__MODULE__, path),
         true <- config.chain_id == lab.chain_id || {:error, :base_deployment_mismatch} do
      {:ok, Map.put(config, :lab, lab)}
    end
  end

  @doc "`address` when it is one of the series the description lists, matched in any case."
  @spec series(String.t()) :: {:ok, String.t()} | {:error, :unknown_series | atom()}
  def series(address) when is_binary(address) do
    with {:ok, config} <- current() do
      case Enum.find(config.series, &Address.equal?(&1, address)) do
        nil -> {:error, :unknown_series}
        series -> {:ok, series}
      end
    end
  end

  def series(_address), do: {:error, :unknown_series}

  def load!(path) do
    case load(path) do
      {:ok, config} -> config
      {:error, reason} -> raise "Autolaunch Exposure description is invalid: #{reason}"
    end
  end

  # Founder-supplied startup input; this path never comes from an HTTP request.
  # sobelow_skip ["Traversal.FileModule"]
  def load(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         {:ok, body} <- File.read(path),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body),
         true <- Enum.sort(Map.keys(decoded)) == @keys || {:error, :invalid_shape},
         {:ok, chain_id} <- Lab.chain_id(decoded["chain_id"]),
         {:ok, usdc} <- address(decoded["usdc"]),
         {:ok, pool_factory} <- address(decoded["pool_factory"]),
         {:ok, series} <- series_list(decoded["series"]) do
      {:ok,
       %{path: path, chain_id: chain_id, usdc: usdc, pool_factory: pool_factory, series: series}}
    else
      false -> {:error, :absolute_path_required}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, :enoent} -> {:error, :missing_file}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_shape}
    end
  end

  def load(_path), do: {:error, :absolute_path_required}

  defp series_list([_ | _] = entries) do
    series = Enum.map(entries, &Address.normalize/1)

    if Enum.all?(series, &match?({:ok, _}, &1)) do
      series = Enum.map(series, &elem(&1, 1))
      if Enum.uniq(series) == series, do: {:ok, series}, else: {:error, :invalid_series}
    else
      {:error, :invalid_series}
    end
  end

  defp series_list(_entries), do: {:error, :invalid_series}

  defp address(value) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> {:error, :invalid_address}
    end
  end
end
