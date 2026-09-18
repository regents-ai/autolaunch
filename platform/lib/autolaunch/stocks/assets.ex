defmodule Autolaunch.Stocks.Assets do
  @moduledoc """
  The stock currencies a Stocks launch can be drafted against, by chain.

  Base is the founder-selected catalog. Robinhood is whatever the local
  Robinhood lab admitted at start: mintable fixture stocks with fixture prices,
  provisional lab data rather than a founder selection. It is empty when the
  lab is not configured, and a configured lab whose file no longer loads raises
  rather than answering an empty or Base list.

  Neither list is proof of executable contract admission. Issuer policies,
  native B20 support and settlement routes require separate verification.
  Preserve supplied address spelling; resolve identities by chain and address.
  """

  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab

  @base_chain_id 8453
  @oracle_registry "0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD"
  @assets [
    {"AAPLc", "0xb200000000000000000000C2e324d24d7eEcd1fb"},
    {"AMZNc", "0xb200000000000000000000d9192b6B456483C2E8"},
    {"COINc", "0xb200000000000000000000c85a31389D71F3ecfb"},
    {"CRCLc", "0xB20000000000000000000019f6E7C675b73C2e4D"},
    {"GOOGLc", "0xb2000000000000000000002D0BA3164cc74f58B7"},
    {"INTCc", "0xB2000000000000000000004AFF16039bA04bdFBc"},
    {"METAc", "0xb2000000000000000000008bC8786B856E61707C"},
    {"MSFTc", "0xB200000000000000000000Ab99cFa739E253872B"},
    {"MSTRc", "0xb2000000000000000000004884b426556b92883d"},
    {"NVDAc", "0xb20000000000000000000078ee7ce2fE4908108C"},
    {"SNDKc", "0xb200000000000000000000397293Cb8cda9a10c5"},
    {"SPCXc", "0xb2000000000000000000007b9fcbd005511aCBd5"},
    {"TSLAc", "0xb2000000000000000000001e800a7f5189430cD0"}
  ]

  @doc "The chain id a draft's stock currency lives on, for each launch chain."
  def chain_id(:base), do: @base_chain_id
  def chain_id(:robinhood), do: RobinhoodLab.chain_id()

  def all(:base) do
    Enum.map(@assets, fn {symbol, address} ->
      %{
        chain_id: @base_chain_id,
        symbol: symbol,
        address: address,
        catalog_status: :listed,
        launch_admission: :unverified
      }
    end)
  end

  def all(:robinhood) do
    case RobinhoodLab.current() do
      {:ok, config} ->
        Enum.map(RobinhoodLab.stocks(config), fn stock ->
          %{
            chain_id: RobinhoodLab.chain_id(),
            symbol: stock.symbol,
            name: stock.name,
            address: stock.address,
            decimals: stock.decimals,
            route: stock.route,
            catalog_status: :lab_fixture,
            launch_admission: :fixture_admitted
          }
        end)

      {:error, :robinhood_lab_disabled} ->
        []

      {:error, reason} ->
        raise "Autolaunch Robinhood lab configuration is invalid: #{reason}"
    end
  end

  @doc "`{symbol, address}` pairs for a selector, in catalog order."
  def options(chain), do: chain |> all() |> Enum.map(&{&1.symbol, &1.address})

  # The Base selector's list; the create page switches to `options(chain)` and
  # this clause goes with it.
  def options, do: @assets

  def oracle_registry, do: %{chain_id: @base_chain_id, address: @oracle_registry}

  def fetch(@base_chain_id, address) when is_binary(address), do: find(:base, address)
  def fetch(31_338, address) when is_binary(address), do: find(:robinhood, address)
  def fetch(_chain_id, _address), do: {:error, :unsupported_stock}

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
