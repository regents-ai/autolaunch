defmodule Autolaunch.Robinhood.Lab do
  @moduledoc """
  The local Robinhood lab configuration: `site-config.json` written by
  `contracts/robinhood/bin/local-robinhood-lab.py start`.

  It is its own blank Anvil chain (31338) rather than a Base fork, loaded in
  development and test only, and refused unless it answers on a loopback door,
  names every address the review depends on and declares every function and
  event the site prepares against.
  """

  alias Autolaunch.Chain.Address
  alias Autolaunch.LabRpcUrl
  alias Autolaunch.Robinhood.LabAbi, as: RobinhoodLabAbi

  @chain_id 31_338
  @address_keys ~w(
    launchpad hook usdg inbox hook_factory pool_manager position_manager
    cca_factory uerc20_factory permit2 admin_safe
  )
  @abi_keys ~w(launchpad erc20)

  @type t :: %{
          path: String.t(),
          rpc_url: String.t(),
          chain_id: pos_integer(),
          run_id: String.t(),
          addresses: %{required(String.t()) => String.t()},
          abis: %{required(String.t()) => [map()]}
        }

  def enabled?,
    do: Application.get_env(:autolaunch, :autolaunch_robinhood_lab_enabled, false) == true

  def current do
    if enabled?(),
      do: Application.fetch_env!(:autolaunch, :autolaunch_robinhood_lab_config_path) |> load(),
      else: {:error, :robinhood_lab_disabled}
  end

  def load!(path) do
    case load(path) do
      {:ok, config} -> config
      {:error, reason} -> raise "Autolaunch Robinhood lab configuration is invalid: #{reason}"
    end
  end

  def load(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         # Founder-supplied startup input; this path never comes from an HTTP request.
         # sobelow_skip ["Traversal.FileModule"]
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, rpc_url} <- LabRpcUrl.admitted(decoded["rpc_url"], :base),
         @chain_id <- decoded["chain_id"],
         {:ok, run_id} <- run_id(decoded["run_id"]),
         {:ok, addresses} <- exact_addresses(decoded["addresses"]),
         {:ok, abis} <- exact_abis(decoded["abis"]),
         :ok <- RobinhoodLabAbi.validate(abis) do
      {:ok,
       %{
         path: path,
         rpc_url: rpc_url,
         chain_id: @chain_id,
         run_id: run_id,
         addresses: addresses,
         abis: abis
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

  @doc "The lab binding an envelope carries: the exact addresses a review depends on."
  def binding(%{run_id: run_id, rpc_url: rpc_url, chain_id: chain_id, addresses: addresses}, keys)
      when is_list(keys) do
    %{
      "run_id" => run_id,
      "rpc_url" => rpc_url,
      "chain_id" => chain_id,
      "addresses" => Map.take(addresses, Enum.map(keys, &to_string/1))
    }
  end

  def binding_matches?(binding, keys) when is_map(binding) and is_list(keys) do
    case current() do
      {:ok, config} -> binding(config, keys) == stringify(binding)
      {:error, _reason} -> false
    end
  end

  def binding_matches?(_binding, _keys), do: false

  def address!(config, key), do: Map.fetch!(config.addresses, to_string(key))
  def abi!(config, key), do: Map.fetch!(config.abis, to_string(key))
  def chain_id, do: @chain_id

  def rpc_opts(config) do
    [
      rpc_url: config.rpc_url,
      expected_chain_id: config.chain_id,
      client_key: :autolaunch_lab_http_client,
      log_scope: "autolaunch robinhood lab"
    ]
  end

  defp run_id(value) when is_binary(value) and value != "", do: {:ok, value}
  defp run_id(_value), do: {:error, :invalid_run_id}

  defp exact_addresses(addresses) when is_map(addresses) do
    with true <- Enum.sort(Map.keys(addresses)) == Enum.sort(@address_keys),
         true <- Enum.all?(addresses, fn {_key, value} -> valid_address?(value) end) do
      {:ok, Map.new(addresses, fn {key, value} -> {key, String.downcase(value)} end)}
    else
      _ -> {:error, :invalid_addresses}
    end
  end

  defp exact_addresses(_addresses), do: {:error, :invalid_addresses}

  defp exact_abis(abis) when is_map(abis) do
    with true <- Enum.sort(Map.keys(abis)) == Enum.sort(@abi_keys),
         true <- Enum.all?(abis, fn {_key, value} -> is_list(value) and value != [] end) do
      {:ok, abis}
    else
      _ -> {:error, :invalid_abis}
    end
  end

  defp exact_abis(_abis), do: {:error, :invalid_abis}

  defp valid_address?(value), do: match?({:ok, _address}, Address.normalize(value))

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)

  defp stringify(value), do: value
end
