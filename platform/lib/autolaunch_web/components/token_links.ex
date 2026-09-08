defmodule AutolaunchWeb.Components.TokenLinks do
  @moduledoc false
  use Phoenix.Component

  alias Autolaunch.Chain.Abi
  alias Autolaunch.Lab

  @chart "https://dexscreener.com/base/0x4ed3b69ac263ad86482f609b2c2105f64bcfd3a7e02e8e078ec9fec1f0324bed"

  def buy, do: "https://app.uniswap.org/explore/tokens/base/#{Abi.regent_address()}"
  def chart, do: @chart

  # Both destinations are public Base mainnet. On a local-fork site they are
  # named as such, because nothing they sell or show is the fork's REGENT.
  def regent_market_links(assigns) do
    assigns = assign(assigns, :local_lab?, Lab.enabled?())

    ~H"""
    <nav class="regent-token-links" aria-label="REGENT market">
      <a
        class="rg-button rg-button--secondary"
        href={buy()}
        id="regent-buy"
        target="_blank"
        rel="noopener noreferrer"
      >
        Buy REGENT{mainnet_suffix(@local_lab?)} <span aria-hidden="true">↗</span>
      </a>
      <a
        class="rg-button rg-button--secondary"
        href={chart()}
        id="regent-chart"
        target="_blank"
        rel="noopener noreferrer"
      >
        View REGENT Chart{mainnet_suffix(@local_lab?)} <span aria-hidden="true">↗</span>
      </a>
      <p :if={@local_lab?} class="regent-token-links__note">
        Both open public Base mainnet. This local fork's test REGENT cannot be bought there.
      </p>
    </nav>
    """
  end

  defp mainnet_suffix(true), do: " · Base mainnet"
  defp mainnet_suffix(false), do: ""
end
