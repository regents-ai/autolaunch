defmodule Autolaunch.TestStocksMarketHttpClient do
  @moduledoc """
  The HTTP client the stock market data reads through under test: every price
  feed and pair listing is unavailable, so the create page renders without a
  price or a venue and nothing is contacted.
  """

  def get(_url, _options), do: {:ok, %{status: 503, body: %{}}}
  def post(_url, _options), do: {:ok, %{status: 503, body: %{}}}
end
