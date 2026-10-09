defmodule AutolaunchWeb.ChartLinkComponent do
  @moduledoc """
  A chart link only after DexScreener confirms this pool's listing. The caller's
  component id includes the network and pool id, so the background read has one
  fixed owner throughout this component's lifetime.
  """
  use AutolaunchWeb, :live_component

  @impl true
  def mount(socket), do: {:ok, assign(socket, asked?: false)}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if socket.assigns.asked? do
      {:ok, socket}
    else
      %{network: network, pool_id: pool_id} = assigns

      {:ok,
       socket
       |> assign(:asked?, true)
       |> assign_async(:listed, fn ->
         {:ok, %{listed: Autolaunch.DexScreener.listed?(network, pool_id)}}
       end)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <span id={@id} class="token-heading__chart">
      <a
        :if={@listed.ok? && @listed.result == true}
        class="rg-button rg-button--secondary token-heading__link"
        href={"https://dexscreener.com/#{@network}/#{@pool_id}"}
        target="_blank"
        rel="noopener noreferrer"
      >
        <span class="token-heading__dexscreener" aria-hidden="true"></span> View Chart
      </a>
      <Regent.Primitives.button
        :if={!@listed.ok? || @listed.result != true}
        variant="secondary"
        disabled
        class="token-heading__link"
      >
        Chart unavailable
      </Regent.Primitives.button>
    </span>
    """
  end
end
