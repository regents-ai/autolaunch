defmodule AutolaunchWeb.Components.PortfolioLink do
  @moduledoc """
  The "View Portfolio" button every success toast after a wallet action
  carries (swap, stake and claim, REGENT's share converted, covered calls), as
  the bid-placed card does, so a person goes straight to what changed.
  """
  use Phoenix.Component
  use AutolaunchWeb, :verified_routes

  attr :class, :any, default: nil

  def portfolio_link(assigns) do
    ~H"""
    <.link
      navigate={~p"/portfolio"}
      class={["rg-button rg-button--secondary toast-portfolio", @class]}
    >
      <span class="rg-button__label">View Portfolio</span>
    </.link>
    """
  end
end
