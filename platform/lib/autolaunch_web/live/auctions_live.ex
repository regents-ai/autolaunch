defmodule AutolaunchWeb.AuctionsLive do
  @moduledoc false
  use AutolaunchWeb, :live_view
  import AutolaunchWeb.Components.AutolaunchHelpers

  def mount(_params, _session, socket), do: {:ok, socket}

  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:cursor, params["after"]) |> load_page()}
  end

  def handle_event("retry", _params, socket), do: {:noreply, load_page(socket)}

  defp load_page(socket) do
    cursor = socket.assigns.cursor

    assign_async(
      socket,
      [:records, :creators, :pagination],
      fn ->
        with {:ok, opts} <-
               AutolaunchWeb.PublicPage.options(cursor, {:auctions, "all", "newest"}, 24),
             {:ok, page} <-
               Autolaunch.page_public_auctions("all", "newest", actor: nil, page: opts) do
          {:ok,
           %{
             records: page.results,
             creators: creator_connections_for(page.results),
             pagination: AutolaunchWeb.PublicPage.metadata(page, {:auctions, "all", "newest"})
           }}
        end
      end,
      reset: true
    )
  end

  def render(assigns) do
    ~H"""
    <.collection
      kind={:auctions}
      records={@records}
      creators={@creators}
      pagination={@pagination}
      cursor={@cursor}
    />
    """
  end
end
