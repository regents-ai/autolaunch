defmodule AutolaunchWeb.AuctionReturnsLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.Launch

  @page_size 12

  def mount(_params, _session, socket) do
    payload =
      launch_module().list_auction_returns(
        %{"limit" => @page_size},
        socket.assigns[:current_human]
      )

    {:ok,
     socket
     |> assign(:page_title, "Auction Returns")
     |> assign(:active_view, "auctions")
     |> assign(:items, payload.items)
     |> assign(:next_offset, payload.next_offset)}
  end

  def handle_event("load_more", _params, %{assigns: %{next_offset: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("load_more", _params, socket) do
    payload =
      launch_module().list_auction_returns(
        %{"limit" => @page_size, "offset" => socket.assigns.next_offset},
        socket.assigns[:current_human]
      )

    {:noreply,
     socket
     |> assign(:items, socket.assigns.items ++ payload.items)
     |> assign(:next_offset, payload.next_offset)}
  end

  def render(assigns) do
    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <section id="auction-returns-hero" class="al-hero al-panel" phx-hook="MissionMotion">
        <div>
          <p class="al-kicker">Auction returns</p>
          <h2>Failed auctions where bidders can take USDC back.</h2>
          <p class="al-subcopy">
            These are the auctions that ended without meeting the minimum raise. If you bid in one
            of them, use the return action from the auction page or your positions page.
          </p>
        </div>

        <div class="al-stat-grid">
          <.stat_card title="Failed auctions" value={Integer.to_string(length(@items))} />
          <.stat_card title="More to load" value={if(@next_offset, do: "Yes", else: "No")} />
        </div>
      </section>

      <%= if @items == [] do %>
        <.empty_state
          title="No failed auctions yet."
          body="Returns will show up here if any auction ends below its minimum raise."
        />
      <% else %>
        <section class="al-token-grid">
          <article
            :for={auction <- @items}
            id={"auction-return-#{auction.id}"}
            class="al-panel al-token-card"
            phx-hook="MissionMotion"
          >
            <div class="al-token-card-head">
              <div>
                <p class="al-kicker">{auction.agent_id}</p>
                <h3>{auction.agent_name}</h3>
                <p class="al-inline-note">{auction.symbol} • failed minimum</p>
              </div>
              <span class="al-status-badge is-muted">Returns open</span>
            </div>

            <div class="al-stat-grid">
              <.stat_card title="Raised" value={auction.currency_raised || auction.total_bid_volume} />
              <.stat_card title="Minimum" value={auction.required_currency_raised || "Unavailable"} />
              <.stat_card title="Ended" value={format_date(auction.ends_at)} />
              <.stat_card
                title="Your status"
                value={auction.your_bid_status || "No tracked bid"}
              />
            </div>

            <div class="al-action-row">
              <.link navigate={auction.detail_url} class="al-submit">Open auction</.link>
            </div>
          </article>
        </section>

        <div
          :if={@next_offset}
          id="auction-returns-more"
          phx-viewport-bottom="load_more"
          class="al-panel al-inline-note"
        >
          Loading more failed auctions…
        </div>
      <% end %>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end

  defp format_date(nil), do: "Unknown"

  defp format_date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> Calendar.strftime(datetime, "%b %-d")
      _ -> "Unknown"
    end
  end

  defp launch_module do
    :autolaunch
    |> Application.get_env(:auction_returns_live, [])
    |> Keyword.get(:launch_module, Launch)
  end
end
