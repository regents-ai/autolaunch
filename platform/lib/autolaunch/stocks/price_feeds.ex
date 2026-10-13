defmodule Autolaunch.Stocks.PriceFeeds do
  @moduledoc """
  What the site assumes of a stock's Chainlink price feed, which the stock's
  route names (`Autolaunch.Stocks.Stock`): it answers in USD with eight
  decimals. A stock's ticker is its symbol without the Base issuer's trailing
  `c`, so `AAPLc` and Robinhood's `AAPL` are the same company.
  """

  @decimals 8

  def decimals, do: @decimals

  @doc "The exchange ticker behind a stock token symbol: `AAPLc` is `AAPL`."
  def ticker(symbol) when is_binary(symbol), do: String.replace_suffix(symbol, "c", "")
end
