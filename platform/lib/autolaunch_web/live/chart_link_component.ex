defmodule AutolaunchWeb.ChartLinkComponent do
  @moduledoc """
  The chart button: DexScreener's chart once DexScreener confirms this pool's
  listing, and until then, or when it never does, the page's own price chart
  (`own_chart`, the chart's id). The caller's component id includes the
  network and pool id, so the background read has one fixed owner throughout
  this component's lifetime.
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
      <a
        :if={(!@listed.ok? || @listed.result != true) && @own_chart}
        class="rg-button rg-button--secondary token-heading__link"
        href={"#" <> @own_chart}
      >
        View Chart
      </a>
    </span>
    """
  end
end
