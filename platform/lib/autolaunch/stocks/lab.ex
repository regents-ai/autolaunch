defmodule Autolaunch.Stocks.Lab do
  @moduledoc """
  The Stocks lab configuration: `stocks-site-config.json` written by
  `contracts/stocks/bin/local-stocks-lab.py deploy`.

  It extends a running Agent lab and is refused unless it names the very Agent
  lab configuration this site runs with, answers on the same admitted RPC
  doors as chain 31337 (`Autolaunch.LabRpcUrl`), and declares every function
  and event the site prepares against. Production loads it only in fork mode
  (`Autolaunch.ChainMode`).
  """

  alias Autolaunch.Chain.Address
  alias Autolaunch.{ChainMode, Lab, LabRpcUrl}
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi

  @chain_id 31_337
  @stock_chain_id 8453

  @address_keys ~w(
    launchpad hook bid_adapter usdc regent permit2 cca_factory pool_manager
    position_manager live_staking governance_safe agent_factory agent_strategy
  )
  @abi_keys ~w(launchpad hook bid_adapter route auction erc20 permit2)
  @faucet_keys ~w(regent_holder regent_amount stock_amount_units usdc_holder usdc_amount)
  # Present when the lab funds the Stocks launch fee; a decimal string of REGENT base units.
  @optional_faucet_keys ~w(regent_launch_fee_amount)
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
          agent_lab_config: String.t(),
          addresses: %{required(String.t()) => String.t()},
          faucet: %{required(String.t()) => String.t()},
          stocks: [stock()],
          abis: %{required(String.t()) => [map()]}
        }

  def enabled?,
    do: Application.get_env(:autolaunch, :autolaunch_stocks_lab_enabled, false) == true

  @doc "The loaded configuration, refused unless the Agent lab it extends is the current one."
  def current do
    with true <- enabled?() || {:error, :stocks_lab_disabled},
         {:ok, agent} <- Lab.current(),
         {:ok, config} <-
           Application.fetch_env!(:autolaunch, :autolaunch_stocks_lab_config_path) |> load(),
         true <- config.agent_lab_config == agent.path || {:error, :agent_lab_mismatch},
         true <- config.rpc_url == agent.rpc_url || {:error, :agent_lab_mismatch},
         true <- config.public_rpc_url == agent.public_rpc_url || {:error, :agent_lab_mismatch},
         true <- same_agent_addresses?(config, agent) || {:error, :agent_lab_mismatch} do
      {:ok, Map.put(config, :run_id, agent.run_id)}
    end
  end

  def current! do
    case current() do
      {:ok, config} -> config
      {:error, reason} -> raise "Autolaunch Stocks lab configuration is unavailable: #{reason}"
    end
  end

  def load!(path, mode \\ ChainMode.mode()) do
    case load(path, mode) do
      {:ok, config} -> config
      {:error, reason} -> raise "Autolaunch Stocks lab configuration is invalid: #{reason}"
    end
  end

  def load(path, mode \\ ChainMode.mode())

  def load(path, mode) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         # Founder-supplied startup input; this path never comes from an HTTP request.
         # sobelow_skip ["Traversal.FileModule"]
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, rpc_url} <- LabRpcUrl.admitted(decoded["rpc_url"], mode),
         {:ok, public_rpc_url} <- LabRpcUrl.public(decoded["public_rpc_url"], rpc_url, mode),
         @chain_id <- decoded["chain_id"],
         {:ok, agent_lab_config} <- absolute(decoded["agent_lab_config"]),
         {:ok, addresses} <- exact_addresses(decoded["addresses"]),
         {:ok, faucet} <- exact_faucet(decoded["faucet"]),
         {:ok, stocks} <- exact_stocks(decoded["stocks"]),
         {:ok, abis} <- exact_abis(decoded["abis"]),
         :ok <- StocksLabAbi.validate(abis) do
      {:ok,
       %{
         path: path,
         rpc_url: rpc_url,
         public_rpc_url: public_rpc_url,
         chain_id: @chain_id,
         agent_lab_config: agent_lab_config,
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

  def load(_path, _mode), do: {:error, :absolute_path_required}

  @doc """
  The lab binding an envelope carries: the exact addresses a review depends on,
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

  @doc "The REGENT base units the lab faucet grants for the launch fee, or `nil` when it does not."
  @spec launch_fee_grant(t()) :: non_neg_integer() | nil
  def launch_fee_grant(%{faucet: faucet}) do
    case faucet["regent_launch_fee_amount"] do
      nil -> nil
      digits -> String.to_integer(digits)
    end
  end

  @doc "The admitted lab stock for one exact address, or `nil`."
  @spec stock(t(), String.t()) :: stock() | nil
  def stock(%{stocks: stocks}, address) when is_binary(address),
    do: Enum.find(stocks, &Address.equal?(&1.address, address))

  def address!(config, key), do: Map.fetch!(config.addresses, to_string(key))
  def abi!(config, key), do: Map.fetch!(config.abis, to_string(key))
  def chain_id, do: @chain_id
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
        {"agent_strategy", "strategy"},
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

  defp absolute(value) when is_binary(value) do
    if Path.type(value) == :absolute, do: {:ok, value}, else: {:error, :invalid_agent_lab_config}
  end

  defp absolute(_value), do: {:error, :invalid_agent_lab_config}

  defp exact_addresses(addresses) when is_map(addresses) do
    with true <- Enum.sort(Map.keys(addresses)) == Enum.sort(@address_keys),
         true <- Enum.all?(addresses, fn {_key, value} -> valid_address?(value) end) do
      {:ok, Map.new(addresses, fn {key, value} -> {key, String.downcase(value)} end)}
    else
      _ -> {:error, :invalid_addresses}
    end
  end

  defp exact_addresses(_addresses), do: {:error, :invalid_addresses}

  defp exact_faucet(faucet) when is_map(faucet) do
    optional = Map.keys(faucet) -- @faucet_keys

    with true <- Enum.sort(Map.keys(faucet) -- optional) == Enum.sort(@faucet_keys),
         true <- optional -- @optional_faucet_keys == [],
         true <- valid_address?(faucet["regent_holder"]),
         true <- valid_address?(faucet["usdc_holder"]),
         true <- Enum.all?(~w(regent_amount stock_amount_units usdc_amount), &digits?(faucet[&1])),
         true <- Enum.all?(optional, &digits?(faucet[&1])) do
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
