defmodule Autolaunch.Stocks.Assets do
  @moduledoc """
  The stock currencies a Stocks launch can be drafted against, by chain.

  Base is the founder-selected catalog. Robinhood is whatever the Robinhood
  deployment description lists: on the local lab, mintable fixture stocks with
  fixture prices. It is empty when no Robinhood description is configured, and
  a configured description that no longer loads raises rather than answering
  an empty or Base list.

  Neither list is proof of executable contract admission. Issuer policies,
  native B20 support and settlement routes require separate verification.
  Preserve supplied address spelling; resolve identities by chain and address.
  """

  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab

  @base_chain_id 8453
  @oracle_registry "0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD"
  @assets [
    {"AAPLc", "Apple", "0xb200000000000000000000C2e324d24d7eEcd1fb"},
    {"AMZNc", "Amazon", "0xb200000000000000000000d9192b6B456483C2E8"},
    {"COINc", "Coinbase", "0xb200000000000000000000c85a31389D71F3ecfb"},
    {"CRCLc", "Circle", "0xB20000000000000000000019f6E7C675b73C2e4D"},
    {"GOOGLc", "Alphabet", "0xb2000000000000000000002D0BA3164cc74f58B7"},
    {"INTCc", "Intel", "0xB2000000000000000000004AFF16039bA04bdFBc"},
    {"METAc", "Meta", "0xb2000000000000000000008bC8786B856E61707C"},
    {"MSFTc", "Microsoft", "0xB200000000000000000000Ab99cFa739E253872B"},
    {"MSTRc", "Strategy", "0xb2000000000000000000004884b426556b92883d"},
    {"NVDAc", "NVIDIA", "0xb20000000000000000000078ee7ce2fE4908108C"},
    {"SNDKc", "Sandisk", "0xb200000000000000000000397293Cb8cda9a10c5"},
    {"SPCXc", "SpaceX", "0xb2000000000000000000007b9fcbd005511aCBd5"},
    {"TSLAc", "Tesla", "0xb2000000000000000000001e800a7f5189430cD0"}
  ]

  @doc "The chain id a draft's stock currency lives on, for each launch chain."
  def chain_id(:base), do: @base_chain_id
  def chain_id(:robinhood), do: RobinhoodLab.chain_id()

  def all(:base) do
    Enum.map(@assets, fn {symbol, name, address} ->
      %{
        chain_id: @base_chain_id,
        symbol: symbol,
        name: name,
        address: address,
        catalog_status: :listed,
        launch_admission: :unverified
      }
    end)
  end

  def all(:robinhood) do
    case RobinhoodLab.current() do
      {:ok, config} ->
        Enum.map(RobinhoodLab.stocks(config), &robinhood_asset(config, &1))

      {:error, :robinhood_deployment_missing} ->
        []

      {:error, reason} ->
        raise "Autolaunch Robinhood deployment description is invalid: #{reason}"
    end
  end

  @doc "The listed stock a link names by symbol or address, however it is spelled."
  @spec named(:base | :robinhood, String.t()) :: {:ok, map()} | :error
  def named(chain, token) when is_binary(token) do
    wanted = token |> String.trim() |> String.downcase()

    case Enum.find(
           all(chain),
           &(wanted in [String.downcase(&1.symbol), String.downcase(&1.address)])
         ) do
      nil -> :error
      asset -> {:ok, asset}
    end
  end

  def oracle_registry, do: %{chain_id: @base_chain_id, address: @oracle_registry}

  def fetch(@base_chain_id, address) when is_binary(address), do: find(:base, address)

  def fetch(chain_id, address) when is_integer(chain_id) and is_binary(address) do
    if chain_id == RobinhoodLab.chain_id(),
      do: find(:robinhood, address),
      else: {:error, :unsupported_stock}
  end

  def fetch(_chain_id, _address), do: {:error, :unsupported_stock}

  # A fixture stock is the lab's own mintable token; any other stock the
  # description lists is a listed asset whose admission the launchpad answers.
  defp robinhood_asset(config, %{fixture: true} = stock),
    do: robinhood_asset(config, stock, :lab_fixture, :fixture_admitted)

  defp robinhood_asset(config, stock), do: robinhood_asset(config, stock, :listed, :unverified)

  defp robinhood_asset(config, stock, catalog_status, launch_admission) do
    %{
      chain_id: config.chain_id,
      symbol: stock.symbol,
      name: stock.name,
      address: stock.address,
      decimals: stock.decimals,
      route: stock.route,
      catalog_status: catalog_status,
      launch_admission: launch_admission
    }
  end

  defp find(chain, address) do
    if Regex.match?(~r/\A0x[0-9a-fA-F]{40}\z/, address) do
      case Enum.find(all(chain), &(String.downcase(&1.address) == String.downcase(address))) do
        nil -> {:error, :unsupported_stock}
        asset -> {:ok, asset}
      end
    else
      {:error, :invalid_address}
    end
  end
end
