defmodule Autolaunch.Stocks.Lab do
  @moduledoc """
  The Base Stocks deployment description: `stocks-site-config.json` as
  `contracts/stocks/bin/local-stocks-lab.py deploy` writes it, and as the
  contracts thread writes it for Base mainnet. `AUTOLAUNCH_BASE_STOCKS_DEPLOYMENT`
  names the file.

  It extends the Base deployment (`Autolaunch.Lab`) and is refused unless it
  names the very Base description this site runs with, answers on the same
  chain through the same RPC doors (`Autolaunch.LabRpcUrl`), and declares
  every function and event the site prepares against.
  """

  alias Autolaunch.Chain.Address
  alias Autolaunch.{Lab, LabRpcUrl}
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi

  @stock_chain_id 8453
  @test_chain_id 31_337

  @address_keys ~w(
    launchpad hook locker splitter_implementation bid_adapter usdc regent permit2
    cca_factory pool_manager position_manager live_staking governance_safe agent_factory
  )
  @abi_keys ~w(launchpad hook locker splitter bid_adapter route auction erc20 permit2)
  @faucet_keys ~w(regent_holder regent_amount stock_amount_units usdc_holder usdc_amount)
  @stock_keys ~w(symbol address decimals route fixture launch_admission)

  @type stock :: %{
          symbol: String.t(),
          address: String.t(),
          decimals: non_neg_integer(),
          route: String.t(),
          fixture: boolean(),
          launch_admission: String.t()
        }

  @type t :: %{
          path: String.t(),
          rpc_url: String.t(),
          public_rpc_url: String.t(),
          chain_id: pos_integer(),
          addresses: %{required(String.t()) => String.t()},
          faucet: %{required(String.t()) => String.t()} | nil,
          stocks: [stock()],
          abis: %{required(String.t()) => [map()]}
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
         {:ok, config} <- load(path),
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
         {:ok, stocks} <- exact_stocks(decoded["stocks"]),
         {:ok, abis} <- exact_abis(decoded["abis"]),
         :ok <- StocksLabAbi.validate(abis) do
      {:ok,
       %{
         path: path,
         rpc_url: rpc_url,
         public_rpc_url: public_rpc_url,
         chain_id: chain_id,
         addresses: addresses,
         faucet: faucet,
         stocks: stocks,
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

  @doc """
  The binding an envelope carries: the exact addresses a review depends on,
  with the public RPC door as its `rpc_url`. The site's own door never leaves
  the server.
  """
  def binding(
        %{
          run_id: run_id,
          public_rpc_url: public_rpc_url,
          chain_id: chain_id,
          addresses: addresses
        },
        keys
      )
      when is_list(keys) do
    %{
      "run_id" => run_id,
      "rpc_url" => public_rpc_url,
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

  @doc "The admitted lab stock for one exact address, or `nil`."
  @spec stock(t(), String.t()) :: stock() | nil
  def stock(%{stocks: stocks}, address) when is_binary(address),
    do: Enum.find(stocks, &Address.equal?(&1.address, address))

  def address!(config, key), do: Map.fetch!(config.addresses, to_string(key))
  def abi!(config, key), do: Map.fetch!(config.abis, to_string(key))

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

  defp exact_stocks(stocks) when is_list(stocks) and stocks != [] do
    parsed = Enum.map(stocks, &exact_stock/1)

    if Enum.all?(parsed, &match?({:ok, _}, &1)) do
      stocks = Enum.map(parsed, fn {:ok, stock} -> stock end)

      if Enum.uniq_by(stocks, & &1.address) == stocks,
        do: {:ok, stocks},
        else: {:error, :invalid_stocks}
    else
      {:error, :invalid_stocks}
    end
  end

  defp exact_stocks(_stocks), do: {:error, :invalid_stocks}

  defp exact_stock(stock) when is_map(stock) do
    with true <- Enum.sort(Map.keys(stock)) == Enum.sort(@stock_keys),
         true <- is_binary(stock["symbol"]) and stock["symbol"] != "",
         true <- valid_address?(stock["address"]),
         true <- is_integer(stock["decimals"]) and stock["decimals"] in 0..36,
         true <- valid_address?(stock["route"]),
         true <- is_boolean(stock["fixture"]),
         true <- is_binary(stock["launch_admission"]),
         {:ok, catalog} <-
           Autolaunch.Stocks.Assets.fetch(@stock_chain_id, stock["address"]),
         true <- catalog.symbol == stock["symbol"] do
      {:ok,
       %{
         symbol: stock["symbol"],
         address: String.downcase(stock["address"]),
         decimals: stock["decimals"],
         route: String.downcase(stock["route"]),
         fixture: stock["fixture"],
         launch_admission: stock["launch_admission"]
       }}
    else
      _ -> :error
    end
  end

  defp exact_stock(_stock), do: :error

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

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)

  defp stringify(value), do: value
end
