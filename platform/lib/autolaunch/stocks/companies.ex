defmodule Autolaunch.Stocks.Companies do
  @moduledoc """
  The company or fund behind each stock ticker, as the stock gallery links it:
  its own public website. Keyed by plain ticker (`AAPL`, not `AAPLc`), like
  the logos in `priv/static/images/stocks/` and their sources in
  `docs/stock-logo-sources.md`.
  """

  @websites %{
    "AAPL" => "https://www.apple.com",
    "AMD" => "https://www.amd.com",
    "AMZN" => "https://www.amazon.com",
    "BABA" => "https://www.alibabagroup.com",
    "COIN" => "https://www.coinbase.com",
    "CRCL" => "https://www.circle.com",
    "DELL" => "https://www.dell.com",
    "GME" => "https://www.gamestop.com",
    "GOOGL" => "https://abc.xyz",
    "INTC" => "https://www.intel.com",
    "META" => "https://about.meta.com",
    "MSFT" => "https://www.microsoft.com",
    "MSTR" => "https://www.strategy.com",
    "MU" => "https://www.micron.com",
    "NVDA" => "https://www.nvidia.com",
    "PLTR" => "https://www.palantir.com",
    "QQQ" => "https://www.invesco.com",
    "SGOV" => "https://www.ishares.com",
    "SLV" => "https://www.ishares.com",
    "SNDK" => "https://www.sandisk.com",
    "SPCX" => "https://www.spacex.com",
    "SPY" => "https://www.ssga.com",
    "TSLA" => "https://www.tesla.com",
    "TSM" => "https://www.tsmc.com",
    "USAR" => "https://www.usare.com",
    "USO" => "https://www.uscfinvestments.com"
  }

  @doc "The website of the company or fund behind a plain ticker; nil when none is kept."
  @spec website(String.t()) :: String.t() | nil
  def website(ticker), do: Map.get(@websites, ticker)
end
