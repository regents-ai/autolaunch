defmodule Autolaunch.Stocks.PriceFeeds do
  @moduledoc """
  The Chainlink price feed for each Base catalog stock: Chainlink's Coinbase
  tokenized-equity feeds (proxy addresses from Chainlink's Base feed directory,
  each checked on chain). Robinhood stocks carry their own feed in the Robinhood
  deployment description. Every feed answers in USD with eight decimals. A
  stock's ticker is its symbol without the issuer's trailing `c`, so `AAPLc`
  reads the `AAPL` feed.
  """

  @decimals 8

  @feeds %{
    "AAPL" => "0x787f13dEa48Db0897CbCDD985de77809D837F988",
    "AMZN" => "0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295",
    "COIN" => "0x408e44f504A7371a345F03a73dDC96A4b48e8aa7",
    "CRCL" => "0x0231cF2635D1E17bB5c2462cc7504Ba1fBd61f33",
    "GOOGL" => "0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2",
    "INTC" => "0xAB657C39bac0D5886250D70849e2E3E008F2EECB",
    "META" => "0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D",
    "MSFT" => "0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c",
    "MSTR" => "0xB3cE282CD188b35DA0E38D8Bc7d58e33173D202a",
    "NVDA" => "0x04689a41629776563E6822F76f2e57D148d28513",
    "SNDK" => "0x388b0dC46C0Fb05A74BeE0994fa5b02c6Fcca2eA",
    "SPCX" => "0x6A634B235903C4ad6376892180d6fF8612e3Fa68",
    "TSLA" => "0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4"
  }

  def decimals, do: @decimals

  @doc "The exchange ticker behind a stock token symbol: `AAPLc` is `AAPL`."
  def ticker(symbol) when is_binary(symbol), do: String.replace_suffix(symbol, "c", "")

  @doc "The feed proxy that prices a Base catalog stock token."
  @spec base_feed!(String.t()) :: String.t()
  def base_feed!(symbol), do: Map.fetch!(@feeds, ticker(symbol))
end
