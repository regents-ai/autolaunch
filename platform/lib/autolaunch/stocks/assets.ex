defmodule Autolaunch.Stocks.Assets do
  @moduledoc """
  The stock currencies a Stocks launch can be drafted against, by chain.

  Each chain offers exactly the stocks its deployment description lists. Base
  names them from the founder-selected catalog, which every stock the Base
  Stocks description lists must come from; Robinhood's description carries its
  own names, and on the local lab mintable fixture stocks with fixture prices.
  A chain is empty when its description is not configured, and a configured
  description that no longer loads raises rather than answering an empty list.

  Neither list is proof of executable contract admission: the launchpad's own
  `stockAdmission` is read again before every launch and bid.
  Preserve supplied address spelling; resolve identities by chain and address.
  """

  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias Autolaunch.Stocks.PriceFeeds

  @base_chain_id 8453
  @oracle_registry "0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD"
  # Each entry's last address is the same company's Robinhood stock token: the
  # pair Chainlink's feed directory names for one issuer on both chains
  # (artifacts/autolaunch-stock-catalog-1011/eligibility.json).
  @catalog [
    {"AAPLc", "Apple", "0xb200000000000000000000C2e324d24d7eEcd1fb",
     "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9"},
    {"AMZNc", "Amazon", "0xb200000000000000000000d9192b6B456483C2E8",
     "0x12f190a9F9d7D37a250758b26824B97CE941bF54"},
    {"COINc", "Coinbase", "0xb200000000000000000000c85a31389D71F3ecfb",
     "0x6330D8C3178a418788dF01a47479c0ce7CCF450b"},
    {"CRCLc", "Circle", "0xB20000000000000000000019f6E7C675b73C2e4D",
     "0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5"},
    {"GOOGLc", "Alphabet", "0xb2000000000000000000002D0BA3164cc74f58B7",
     "0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3"},
    {"INTCc", "Intel", "0xB2000000000000000000004AFF16039bA04bdFBc",
     "0xc72b96e0E48ecd4DC75E1e45396e26300BC39681"},
    {"METAc", "Meta", "0xb2000000000000000000008bC8786B856E61707C",
     "0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35"},
    {"MSFTc", "Microsoft", "0xB200000000000000000000Ab99cFa739E253872B",
     "0xe93237C50D904957Cf27E7B1133b510C669c2e74"},
    {"MSTRc", "Strategy", "0xb2000000000000000000004884b426556b92883d",
     "0xec262a75e413fAfD0dF80480274532C79D42da09"},
    {"NVDAc", "NVIDIA", "0xb20000000000000000000078ee7ce2fE4908108C",
     "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC"},
    {"SNDKc", "Sandisk", "0xb200000000000000000000397293Cb8cda9a10c5",
     "0xB90A19fF0Af67f7779afF50A882A9CfF42446400"},
    {"SPCXc", "SpaceX", "0xb2000000000000000000007b9fcbd005511aCBd5",
     "0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa"},
    {"TSLAc", "Tesla", "0xb2000000000000000000001e800a7f5189430cD0",
     "0x322F0929c4625eD5bAd873c95208D54E1c003b2d"}
  ]

  @doc "The chain id a draft's stock currency lives on, for each launch chain."
  def chain_id(:base), do: @base_chain_id
  def chain_id(:robinhood), do: RobinhoodLab.chain_id()

  def all(:base) do
    case StocksLab.current() do
      {:ok, config} ->
        Enum.map(config.stocks, &base_asset/1)

      {:error, :stocks_deployment_missing} ->
        []

      {:error, reason} ->
        raise "Autolaunch Base Stocks deployment description is invalid: #{reason}"
    end
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

  @doc "The founder-selected Base catalog entry for an address, however it is spelled."
  @spec catalogued(String.t()) ::
          {:ok, %{symbol: String.t(), name: String.t(), address: String.t()}} | :error
  def catalogued(address) when is_binary(address) do
    case Enum.find(@catalog, fn {_symbol, _name, listed, _robinhood} ->
           String.downcase(listed) == String.downcase(address)
         end) do
      {symbol, name, listed, _robinhood} -> {:ok, %{symbol: symbol, name: name, address: listed}}
      nil -> :error
    end
  end

  @doc "The same company's stock token on the other launch chain, from the catalog's pairs."
  @spec counterpart(:base | :robinhood, String.t()) :: {:ok, String.t()} | :error
  def counterpart(:base, address) when is_binary(address) do
    case Enum.find(@catalog, fn {_symbol, _name, base, _robinhood} -> same?(base, address) end) do
      {_symbol, _name, _base, robinhood} -> {:ok, robinhood}
      nil -> :error
    end
  end

  def counterpart(:robinhood, address) when is_binary(address) do
    case Enum.find(@catalog, fn {_symbol, _name, _base, robinhood} ->
           same?(robinhood, address)
         end) do
      {_symbol, _name, base, _robinhood} -> {:ok, base}
      nil -> :error
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

  # The description checked every stock against the catalog when it loaded.
  defp base_asset(stock) do
    {:ok, entry} = catalogued(stock.address)

    %{
      chain_id: @base_chain_id,
      symbol: entry.symbol,
      name: entry.name,
      address: entry.address,
      feed: PriceFeeds.base_feed!(entry.symbol),
      catalog_status: :listed,
      launch_admission: :unverified
    }
  end

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
      feed: stock.feed,
      catalog_status: catalog_status,
      launch_admission: launch_admission
    }
  end

  defp same?(listed, address), do: String.downcase(listed) == String.downcase(address)

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
