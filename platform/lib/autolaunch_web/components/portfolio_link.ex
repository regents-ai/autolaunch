defmodule AutolaunchWeb.Components.PortfolioLink do
  @moduledoc """
  The "View Portfolio" button the success toast of a wallet action that
  changes the person's own holdings carries (swap, stake and claim, covered
  calls), as the bid-placed card does, so they go straight to what changed.
  A toast shown on the portfolio itself leaves it out.
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
