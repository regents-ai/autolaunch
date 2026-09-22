defmodule Autolaunch.Robinhood.Lab do
  @moduledoc """
  The Robinhood deployment description: `site-config.json` as
  `contracts/robinhood/bin/local-robinhood-lab.py start` writes it, and as the
  contracts thread writes it for the Robinhood chain. `AUTOLAUNCH_ROBINHOOD_DEPLOYMENT`
  names the file.

  It is refused unless it answers on an admitted RPC door
  (`Autolaunch.LabRpcUrl`), names every address the site depends on (with the
  swap router and quoter together or not at all), lists
  every stock the Stocks launchpad admitted, and declares every function and
  event the site prepares against. Chain 31338 is the local lab, a blank Anvil
  chain with fixture stocks; `test_chain?/0` is what the lab-only features key
  off.
  """

  alias Autolaunch.Chain.Address
  alias Autolaunch.{Lab, LabRpcUrl}
  alias Autolaunch.Robinhood.LabAbi, as: RobinhoodLabAbi

  @test_chain_id 31_338
  @address_keys ~w(
    stocks_launchpad stocks_hook stocks_locker stocks_splitter_implementation bid_adapter usdg
    inbox hook_factory pool_manager position_manager cca_factory uerc20_factory permit2 admin_safe
  )
  # A deployment that supports swapping on the site names Uniswap's Universal
  # Router and V4 Quoter together; one without the other is refused.
  @swap_address_keys ~w(swap_router quoter)
  @abi_keys ~w(stocks_launchpad stocks_hook stocks_locker splitter bid_adapter stock_route auction erc20)
  @stock_keys ~w(symbol name address decimals route usdg_per_share fixture launch_admission)
  @stock_decimals 8

  @type stock :: %{
          symbol: String.t(),
          name: String.t(),
          address: String.t(),
          decimals: pos_integer(),
          route: String.t(),
          usdg_per_share: pos_integer(),
          fixture: boolean(),
          launch_admission: String.t()
        }

  @type t :: %{
          path: String.t(),
          rpc_url: String.t(),
          public_rpc_url: String.t(),
          chain_id: pos_integer(),
          run_id: String.t(),
          addresses: %{required(String.t()) => String.t()},
          stocks: [stock()],
          abis: %{required(String.t()) => [map()]}
        }

  @doc "Whether this site was given a Robinhood deployment description."
  def configured?,
    do: is_binary(Application.get_env(:autolaunch, :autolaunch_robinhood_deployment))

  @doc "Whether the Robinhood deployment is the local lab: fixture stocks with no value."
  def test_chain?, do: chain_id() == @test_chain_id

  @doc "Whether a reviewed chain id is the local lab's."
  def test_chain?(chain_id), do: chain_id == @test_chain_id

  @doc "The network a reviewed chain id names."
  def network_name(chain_id),
    do: if(test_chain?(chain_id), do: "Robinhood test network", else: "Robinhood Chain")

  @doc "The configured Robinhood deployment's chain id, or `nil` without one."
  def chain_id, do: Application.get_env(:autolaunch, :autolaunch_robinhood_chain_id)

  def current do
    case Application.get_env(:autolaunch, :autolaunch_robinhood_deployment) do
      path when is_binary(path) -> load(path)
      nil -> {:error, :robinhood_deployment_missing}
    end
  end

  def load!(path) do
    case load(path) do
      {:ok, config} ->
        config

      {:error, reason} ->
        raise "Autolaunch Robinhood deployment description is invalid: #{reason}"
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
         {:ok, run_id} <- run_id(decoded["run_id"]),
         {:ok, addresses} <- exact_addresses(decoded["addresses"]),
         {:ok, stocks} <- exact_stocks(decoded["stocks"]),
         {:ok, abis} <- exact_abis(decoded["abis"]),
         :ok <- RobinhoodLabAbi.validate(abis) do
      {:ok,
       %{
         path: path,
         rpc_url: rpc_url,
         public_rpc_url: public_rpc_url,
         chain_id: chain_id,
         run_id: run_id,
         addresses: addresses,
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

  def address!(config, key), do: Map.fetch!(config.addresses, to_string(key))

  @doc "The router and quoter a deployment trades through, or `:error` when it names none."
  @spec swap_addresses(t()) :: {:ok, %{router: String.t(), quoter: String.t()}} | :error
  def swap_addresses(%{addresses: addresses}) do
    case addresses do
      %{"swap_router" => router, "quoter" => quoter} -> {:ok, %{router: router, quoter: quoter}}
      _none -> :error
    end
  end

  def abi!(config, key), do: Map.fetch!(config.abis, to_string(key))

  @doc "The stocks the controller read back from the chain, admitted on the Stocks launchpad."
  @spec stocks(t()) :: [stock()]
  def stocks(%{stocks: stocks}), do: stocks

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
    with true <- Enum.sort(Map.keys(addresses)) in address_key_sets(),
         true <- Enum.all?(addresses, fn {_key, value} -> valid_address?(value) end) do
      {:ok, Map.new(addresses, fn {key, value} -> {key, String.downcase(value)} end)}
    else
      _ -> {:error, :invalid_addresses}
    end
  end

  defp exact_addresses(_addresses), do: {:error, :invalid_addresses}

  defp address_key_sets,
    do: [Enum.sort(@address_keys), Enum.sort(@address_keys ++ @swap_address_keys)]

  # Every entry is exactly what the controller read back from the chain; a
  # missing field, a stock that is not eight decimals, or a repeated symbol or
  # address refuses the whole description. Addresses are normalized (the zero
  # address refused) before the duplicate check.
  defp exact_stocks(stocks) when is_list(stocks) and stocks != [] do
    parsed = Enum.map(stocks, &exact_stock/1)

    with true <- Enum.all?(parsed, &match?({:ok, _stock}, &1)),
         stocks <- Enum.map(parsed, fn {:ok, stock} -> stock end),
         true <- Enum.uniq_by(stocks, & &1.address) == stocks,
         true <- Enum.uniq_by(stocks, & &1.symbol) == stocks do
      {:ok, stocks}
    else
      _ -> {:error, :invalid_stocks}
    end
  end

  defp exact_stocks(_stocks), do: {:error, :invalid_stocks}

  defp exact_stock(stock) when is_map(stock) do
    with true <- Enum.sort(Map.keys(stock)) == Enum.sort(@stock_keys),
         true <- present?(stock["symbol"]),
         true <- present?(stock["name"]),
         true <- valid_address?(stock["address"]),
         @stock_decimals <- stock["decimals"],
         true <- valid_address?(stock["route"]),
         {:ok, usdg_per_share} <- atomic_amount(stock["usdg_per_share"]),
         true <- is_boolean(stock["fixture"]),
         true <- present?(stock["launch_admission"]) do
      {:ok,
       %{
         symbol: stock["symbol"],
         name: stock["name"],
         address: String.downcase(stock["address"]),
         decimals: @stock_decimals,
         route: String.downcase(stock["route"]),
         usdg_per_share: usdg_per_share,
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

  defp present?(value), do: is_binary(value) and value != ""

  defp atomic_amount(value) when is_binary(value) do
    case Integer.parse(value) do
      {amount, ""} when amount > 0 -> {:ok, amount}
      _ -> :error
    end
  end

  defp atomic_amount(_value), do: :error

  defp valid_address?(value), do: match?({:ok, _address}, Address.normalize(value))

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)

  defp stringify(value), do: value
end
