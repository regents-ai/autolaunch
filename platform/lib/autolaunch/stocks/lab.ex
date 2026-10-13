defmodule Autolaunch.Stocks.Lab do
  @moduledoc """
  The Base Stocks deployment description: `stocks-site-config.json` as
  `contracts/stocks-v2/bin/local-stocks-lab.py deploy` writes it, and as the
  contracts thread writes it for Base mainnet. `AUTOLAUNCH_BASE_STOCKS_DEPLOYMENT`
  names the file.

  It extends the Base deployment (`Autolaunch.Lab`) and is refused unless it
  names the very Base description this site runs with, answers on the same
  chain through the same RPC doors (`Autolaunch.LabRpcUrl`), and declares
  every function and event the site prepares against. The stocks the launchpad
  admits are not listed here: the site reads them from the chain
  (`Autolaunch.Stocks.Stock`).

  A deployment with launches on the first Memestock launchpad (BITE, JollyB and
  AGI on Base) names that launchpad, its hook and its locker in a `v1`
  section with their ABIs; those launches read only those contracts.
  """

  alias Autolaunch.{Lab, LabRpcUrl}
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi
  alias RegentChain.Address

  @stock_chain_id 8453
  @test_chain_id 31_337

  @address_keys ~w(
    launchpad hook locker splitter_implementation bid_adapter usdc regent permit2
    cca_factory pool_manager position_manager live_staking governance_safe agent_factory
  )
  @abi_keys ~w(launchpad hook locker splitter bid_adapter route auction erc20 permit2)
  @faucet_keys ~w(regent_holder regent_amount stock_amount_units usdc_holder usdc_amount)
  @contract_keys ~w(hook launchpad locker)
  # A v1 section also names the bid adapter that version's USDC bids went through.
  @v1_address_keys ~w(bid_adapter hook launchpad locker)

  @type t :: %{
          path: String.t(),
          rpc_url: String.t(),
          public_rpc_url: String.t(),
          chain_id: pos_integer(),
          addresses: %{required(String.t()) => String.t()},
          faucet: %{required(String.t()) => String.t()} | nil,
          abis: %{required(String.t()) => [map()]},
          v1: map() | nil
        }

  @doc "Whether this site was given a Base Stocks deployment description."
  def configured?,
    do: is_binary(Application.get_env(:autolaunch, :autolaunch_base_stocks_deployment))

  @doc "The loaded description, refused unless the Base description it extends is the current one."
  def current do
    with path when is_binary(path) <-
           Application.get_env(:autolaunch, :autolaunch_base_stocks_deployment) ||
             {:error, :stocks_deployment_missing},
         {:ok, agent} <- Lab.current(),
         {:ok, config} <- Lab.loaded(__MODULE__, path),
         true <- config.chain_id == agent.chain_id || {:error, :agent_lab_mismatch},
         true <- config.rpc_url == agent.rpc_url || {:error, :agent_lab_mismatch},
         true <- config.public_rpc_url == agent.public_rpc_url || {:error, :agent_lab_mismatch},
         true <- same_agent_addresses?(config, agent) || {:error, :agent_lab_mismatch} do
      {:ok, Map.put(config, :run_id, agent.run_id)}
    end
  end

  def current! do
    case current() do
      {:ok, config} ->
        config

      {:error, reason} ->
        raise "Autolaunch Base Stocks deployment description is unavailable: #{reason}"
    end
  end

  def load!(path) do
    case load(path) do
      {:ok, config} ->
        config

      {:error, reason} ->
        raise "Autolaunch Base Stocks deployment description is invalid: #{reason}"
    end
  end

  def load(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         # Founder-supplied startup input; this path never comes from an HTTP request.
         # sobelow_skip ["Traversal.FileModule"]
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, rpc_url} <- LabRpcUrl.admitted(decoded["rpc_url"]),
         {:ok, public_rpc_url} <- LabRpcUrl.public(decoded["public_rpc_url"], rpc_url),
         {:ok, chain_id} <- Lab.chain_id(decoded["chain_id"]),
         {:ok, addresses} <- exact_addresses(decoded["addresses"]),
         {:ok, faucet} <- faucet_section(decoded["faucet"], chain_id),
         {:ok, abis} <- exact_abis(decoded["abis"]),
         :ok <- StocksLabAbi.validate(abis),
         {:ok, v1} <- v1_section(decoded["v1"]) do
      {:ok,
       %{
         path: path,
         rpc_url: rpc_url,
         public_rpc_url: public_rpc_url,
         chain_id: chain_id,
         addresses: addresses,
         faucet: faucet,
         abis: abis,
         v1: v1
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

  def address!(config, key), do: Map.fetch!(config.addresses, to_string(key))
  def abi!(config, key), do: Map.fetch!(config.abis, to_string(key))

  @doc """
  The launchpad, hook, locker and bid adapter a Memestock launch on `version`
  runs on, the ABIs of the first three (keyed `"launchpad"`, `"hook"` and
  `"locker"`) and the shape of that version's records and hook
  (`Autolaunch.Stocks.LabAbi.shape/1`).
  """
  def contracts(config, :v2) do
    {:ok,
     :v2
     |> StocksLabAbi.shape()
     |> Map.merge(%{
       version: :v2,
       launchpad: address!(config, :launchpad),
       hook: address!(config, :hook),
       locker: address!(config, :locker),
       bid_adapter: address!(config, :bid_adapter),
       abis: Map.take(config.abis, @contract_keys)
     })}
  end

  def contracts(%{v1: %{} = v1}, :v1),
    do: {:ok, :v1 |> StocksLabAbi.shape() |> Map.merge(v1) |> Map.put(:version, :v1)}

  def contracts(_config, :v1), do: {:error, :v1_contracts_missing}

  @doc "The Base deployment's chain id, which this description shares."
  def chain_id, do: Lab.chain_id()
  def stock_chain_id, do: @stock_chain_id

  def rpc_opts(config, scope \\ "autolaunch stocks lab") do
    [
      rpc_url: config.rpc_url,
      expected_chain_id: config.chain_id,
      client_key: :autolaunch_lab_http_client,
      log_scope: scope
    ]
  end

  # The Agent addresses the Stocks lab repeats have to be the Agent lab's own,
  # so one site never prepares against two forks.
  defp same_agent_addresses?(config, agent) do
    Enum.all?(
      [
        {"agent_factory", "factory"},
        {"regent", "regent"},
        {"permit2", "permit2"},
        {"governance_safe", "governance_safe"},
        {"cca_factory", "cca_factory"},
        {"pool_manager", "pool_manager"},
        {"position_manager", "position_manager"}
      ],
      fn {stocks_key, agent_key} ->
        Address.equal?(config.addresses[stocks_key], agent.addresses[agent_key])
      end
    )
  end

  defp exact_addresses(addresses) when is_map(addresses) do
    with true <- Enum.sort(Map.keys(addresses)) == Enum.sort(@address_keys),
         true <- Enum.all?(addresses, fn {_key, value} -> valid_address?(value) end) do
      {:ok, Map.new(addresses, fn {key, value} -> {key, String.downcase(value)} end)}
    else
      _ -> {:error, :invalid_addresses}
    end
  end

  defp exact_addresses(_addresses), do: {:error, :invalid_addresses}

  # A lab description carries the test-funds faucet; a mainnet description has none.
  defp faucet_section(faucet, @test_chain_id), do: exact_faucet(faucet)
  defp faucet_section(nil, _chain_id), do: {:ok, nil}
  defp faucet_section(_faucet, _chain_id), do: {:error, :invalid_faucet}

  defp exact_faucet(faucet) when is_map(faucet) do
    with true <- Enum.sort(Map.keys(faucet)) == Enum.sort(@faucet_keys),
         true <- valid_address?(faucet["regent_holder"]),
         true <- valid_address?(faucet["usdc_holder"]),
         true <- Enum.all?(~w(regent_amount stock_amount_units usdc_amount), &digits?(faucet[&1])) do
      {:ok,
       faucet
       |> Map.update!("regent_holder", &String.downcase/1)
       |> Map.update!("usdc_holder", &String.downcase/1)}
    else
      _ -> {:error, :invalid_faucet}
    end
  end

  defp exact_faucet(_faucet), do: {:error, :invalid_faucet}

  defp v1_section(nil), do: {:ok, nil}

  defp v1_section(%{"addresses" => addresses, "abis" => abis} = v1) when map_size(v1) == 2 do
    with true <- is_map(addresses) and Enum.sort(Map.keys(addresses)) == @v1_address_keys,
         true <- Enum.all?(addresses, fn {_key, value} -> valid_address?(value) end),
         true <- is_map(abis) and Enum.sort(Map.keys(abis)) == @contract_keys,
         true <- Enum.all?(abis, fn {_key, value} -> is_list(value) and value != [] end),
         :ok <- StocksLabAbi.validate_v1(abis) do
      {:ok,
       %{
         launchpad: String.downcase(addresses["launchpad"]),
         hook: String.downcase(addresses["hook"]),
         locker: String.downcase(addresses["locker"]),
         bid_adapter: String.downcase(addresses["bid_adapter"]),
         abis: abis
       }}
    else
      _ -> {:error, :invalid_v1}
    end
  end

  defp v1_section(_v1), do: {:error, :invalid_v1}

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

  defp digits?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9]+\z/, value)
  defp digits?(_value), do: false
end
