defmodule Autolaunch.Stocks.PriceFeeds do
  @moduledoc """
  The Chainlink price feed for each stock a launch can be paired with, per chain.

  Base lists Chainlink's Coinbase tokenized-equity feeds (proxy addresses from
  Chainlink's Base feed directory, each checked on chain); Robinhood lists the
  stock feeds Chainlink publishes on Robinhood Chain. Every feed answers in USD
  with eight decimals. A stock's ticker is its symbol without the issuer's
  trailing `c`, so `AAPLc` on either chain reads the `AAPL` feed of that chain.
  """

  @decimals 8

  @feeds %{
    "AAPL" =>
      {"0x787f13dEa48Db0897CbCDD985de77809D837F988", "0x6B22A786bAa607d76728168703a39Ea9C99f2cD0"},
    "AMZN" =>
      {"0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295", "0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C"},
    "COIN" =>
      {"0x408e44f504A7371a345F03a73dDC96A4b48e8aa7", "0xA3a468A452940B7D6b69991207B508c609a98Ef2"},
    "CRCL" =>
      {"0x0231cF2635D1E17bB5c2462cc7504Ba1fBd61f33", "0x6652eDf64bA3731C4F2D3ce821A0Fb1f1f6b482a"},
    "GOOGL" =>
      {"0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2", "0xF6f373a037c30F0e5010d854385cA89185AE638b"},
    "INTC" =>
      {"0xAB657C39bac0D5886250D70849e2E3E008F2EECB", "0x3f390C5C24628Ac7C489515402235FeAD71D1913"},
    "META" =>
      {"0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D", "0x7C38C00C30BEe9378381E7B6135d7283356D71b1"},
    "MSFT" =>
      {"0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c", "0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E"},
    "MSTR" =>
      {"0xB3cE282CD188b35DA0E38D8Bc7d58e33173D202a", "0x396118bdFB181e6240E74D243F266B061c0edc3D"},
    "NVDA" =>
      {"0x04689a41629776563E6822F76f2e57D148d28513", "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15"},
    "SNDK" =>
      {"0x388b0dC46C0Fb05A74BeE0994fa5b02c6Fcca2eA", "0xfb133Fa4B7b385802B693a293606682Df47109A3"},
    "SPCX" =>
      {"0x6A634B235903C4ad6376892180d6fF8612e3Fa68", "0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb"},
    "TSLA" =>
      {"0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4", "0x4A1166a659A55625345e9515b32adECea5547C38"}
  }

  def decimals, do: @decimals

  @doc "The exchange ticker behind a stock token symbol: `AAPLc` is `AAPL`."
  def ticker(symbol) when is_binary(symbol), do: String.replace_suffix(symbol, "c", "")

  @doc "The feed proxy that prices a stock token on the given launch chain."
  @spec feed(:base | :robinhood, String.t()) :: {:ok, String.t()} | :error
  def feed(chain, symbol) do
    case Map.fetch(@feeds, ticker(symbol)) do
      {:ok, {base, _robinhood}} when chain == :base -> {:ok, base}
      {:ok, {_base, robinhood}} when chain == :robinhood -> {:ok, robinhood}
      _unlisted -> :error
    end
  end
end
