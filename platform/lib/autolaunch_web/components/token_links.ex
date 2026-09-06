defmodule AutolaunchWeb.Components.TokenLinks do
  @moduledoc false
  use Phoenix.Component

  alias Autolaunch.Chain.Abi

  @chart "https://dexscreener.com/base/0x4ed3b69ac263ad86482f609b2c2105f64bcfd3a7e02e8e078ec9fec1f0324bed"

  def buy, do: "https://app.uniswap.org/explore/tokens/base/#{Abi.regent_address()}"
  def chart, do: @chart

  def regent_market_links(assigns) do
    ~H"""
    <nav class="regent-token-links" aria-label="REGENT market">
      <a href={buy()} id="regent-buy" target="_blank" rel="noopener noreferrer">
        Buy REGENT <span aria-hidden="true">↗</span>
      </a>
      <a href={chart()} id="regent-chart" target="_blank" rel="noopener noreferrer">
        View REGENT Chart <span aria-hidden="true">↗</span>
      </a>
    </nav>
    """
  end
end
