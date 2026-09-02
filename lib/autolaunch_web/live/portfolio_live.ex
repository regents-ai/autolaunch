defmodule AutolaunchWeb.PortfolioLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("refresh", _params, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <main>
      <div id="account-control" data-account-kind={@account_control.kind}>
        <h1>Portfolio</h1>
        <button phx-click="refresh">Refresh</button>
      </div>
    </main>
    """
  end
end
