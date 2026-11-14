defmodule Autolaunch.Exposure.Deployment do
  @moduledoc """
  Whether Exposure is on, and the description of its contracts:
  `AUTOLAUNCH_BASE_EXPOSURE_DEPLOYMENT` names a JSON file naming the
  `ExposureFactoryV2` that opens one series a week, the first week the site
  lists, the USDC each week's tokens trade against and the Aerodrome pool
  factory and router they trade through.

      {"chain_id": 8453,
       "factory": "0x…",
       "first_week": 2968,
       "usdc": "0x8335…",
       "pool_factory": "0x420D…",
       "router": "0xcF77…"}

  Exposure is on only when `AUTOLAUNCH_EXPOSURE=true`, and then the
  description is required (`config/runtime.exs`). It extends the Base
  deployment (`Autolaunch.Lab`): the description must name its chain, and every
  read and step goes through its RPC doors. Off, the page and the routes answer
  not found and no tool offers it. Everything else (each week's series, stock,
  tokens, feed, dates and terms) is read from the factory and the series.
  """

  alias Autolaunch.Lab
  alias RegentChain.Address

  @keys ~w(chain_id factory first_week pool_factory router usdc)

  @doc "Whether this site offers Exposure."
  def enabled?, do: Application.get_env(:autolaunch, :exposure, :off) == :on

  @doc "The description, with the Base deployment it extends, or why there is none."
  @spec current() ::
          {:ok,
           %{
             chain_id: pos_integer(),
             factory: String.t(),
             first_week: pos_integer(),
             usdc: String.t(),
             pool_factory: String.t(),
             router: String.t(),
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
         {:ok, factory} <- address(decoded["factory"]),
         {:ok, first_week} <- week(decoded["first_week"]),
         {:ok, usdc} <- address(decoded["usdc"]),
         {:ok, pool_factory} <- address(decoded["pool_factory"]),
         {:ok, router} <- address(decoded["router"]) do
      {:ok,
       %{
         path: path,
         chain_id: chain_id,
         factory: factory,
         first_week: first_week,
         usdc: usdc,
         pool_factory: pool_factory,
         router: router
       }}
    else
      false -> {:error, :absolute_path_required}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, :enoent} -> {:error, :missing_file}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_shape}
    end
  end

  def load(_path), do: {:error, :absolute_path_required}

  defp week(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp week(_value), do: {:error, :invalid_week}

  defp address(value) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> {:error, :invalid_address}
    end
  end
end
