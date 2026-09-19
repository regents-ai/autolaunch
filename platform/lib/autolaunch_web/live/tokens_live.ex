defmodule AutolaunchWeb.TokensLive do
  @moduledoc false
  use AutolaunchWeb, :live_view
  import AutolaunchWeb.Components.AutolaunchHelpers
  import AutolaunchWeb.Components.SwapModal

  def mount(_params, _session, socket), do: {:ok, assign(socket, trade: nil)}

  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(cursor: params["after"], trade: nil) |> load_page()}
  end

  def handle_event("retry", _params, socket), do: {:noreply, load_page(socket)}

  def handle_event("open_trade", %{"id" => id} = params, socket),
    do: {:noreply, assign(socket, :trade, opened_trade(socket.assigns.records, id, params))}

  def handle_event("open_trade", _params, socket), do: {:noreply, socket}

  def handle_event("close_trade", %{"id" => id}, socket) do
    case socket.assigns.trade do
      %{record: %{id: ^id}} -> {:noreply, assign(socket, :trade, nil)}
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
      :if={@trade}
      id={"tokens-trade-#{@trade.record.id}"}
      token={@trade.record}
      amount={@trade.amount}
      authenticated={@account_control.kind == :signed_in}
      current_human_id={current_human_id(@access_context)}
      session_lease={@session_lease}
    />
    """
  end
end
