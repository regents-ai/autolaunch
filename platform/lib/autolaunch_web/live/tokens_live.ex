defmodule AutolaunchWeb.TokensLive do
  @moduledoc false
  use AutolaunchWeb, :live_view
  import AutolaunchWeb.Components.AutolaunchHelpers
  import AutolaunchWeb.Components.SwapModal

  def mount(_params, _session, socket), do: {:ok, assign(socket, :trade_token, nil)}

  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(cursor: params["after"], trade_token: nil) |> load_page()}
  end

  def handle_event("retry", _params, socket), do: {:noreply, load_page(socket)}

  def handle_event("open_trade", %{"token-id" => id}, socket) do
    records = socket.assigns.records

    token =
      if records.ok? && !records.loading && !records.failed,
        do: Enum.find(records.result, &(&1.id == id))

    {:noreply, assign(socket, :trade_token, token)}
  end

  def handle_event("open_trade", _params, socket), do: {:noreply, socket}

  def handle_event("close_trade", %{"token_id" => id}, socket) do
    case socket.assigns.trade_token do
      %{id: ^id} -> {:noreply, assign(socket, :trade_token, nil)}
      _other -> {:noreply, socket}
    end
  end

  def handle_event("close_trade", _params, socket), do: {:noreply, socket}

  defp load_page(socket) do
    cursor = socket.assigns.cursor

    assign_async(
      socket,
      [:records, :creators, :pagination],
      fn ->
        with {:ok, opts} <- AutolaunchWeb.PublicPage.options(cursor, :tokens, 24),
             {:ok, page} <- Autolaunch.page_public_tokens(actor: nil, page: opts) do
          {:ok,
           %{
             records: page.results,
             creators: creator_connections_for(page.results),
             pagination: AutolaunchWeb.PublicPage.metadata(page, :tokens)
           }}
        end
      end,
      reset: true
    )
  end

  def render(assigns) do
    ~H"""
    <.collection
      kind={:tokens}
      records={@records}
      creators={@creators}
      pagination={@pagination}
      cursor={@cursor}
      trade_event="open_trade"
    />
    <.swap_modal
      :if={@trade_token}
      id={"tokens-trade-#{@trade_token.id}"}
      token={@trade_token}
    />
    """
  end
end
