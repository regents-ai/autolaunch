defmodule AutolaunchWeb.AuctionReturnsLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.Launch
  alias Decimal, as: D

  @page_size 12
  @auctions_css_path Path.expand("../../../assets/css/auctions-live.css", __DIR__)
  @external_resource @auctions_css_path
  @auctions_css File.read!(@auctions_css_path)

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
     |> assign_returns(payload.items, payload.next_offset)}
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

    {:noreply, assign_returns(socket, socket.assigns.items ++ payload.items, payload.next_offset)}
  end

  def render(assigns) do
    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <style id="auction-returns-css">
        <%= raw(route_css()) %>
      </style>

      <div class="al-auction-returns-route">
        <section id="auction-returns-head" class="al-auctions-page-head" phx-hook="MissionMotion">
          <div>
            <h1>Auctions</h1>
          </div>

          <nav class="tabs tabs-boxed al-auctions-page-tabs" aria-label="Auction pages">
            <.link navigate={~p"/auctions"} class="tab">Open markets</.link>
            <.link navigate={~p"/auction-returns"} class="tab tab-active">Auction returns</.link>
          </nav>
        </section>

        <section
          id="auction-returns-hero"
          class="al-auction-returns-hero al-panel"
          phx-hook="MissionMotion"
        >
          <div class="al-auction-returns-hero-copy">
            <div>
              <p class="al-kicker">Auction returns</p>
              <h2>Find the auctions where bidders can pull USDC back.</h2>
              <p class="al-subcopy">
                These markets ended below the minimum raise. Open the matching auction or your
                positions page to finish the return action quickly.
              </p>
            </div>

            <.link navigate={~p"/how-auctions-work"} class="btn btn-outline btn-sm">
              Learn how returns work
            </.link>
          </div>

          <div class="al-auction-returns-stats">
            <article>
              <span>Failed auctions</span>
              <strong>{@summary.failed_count}</strong>
              <p>Returns available</p>
            </article>
            <article>
              <span>Total raised</span>
              <strong>{@summary.total_raised}</strong>
              <p>Across failed auctions</p>
            </article>
            <article>
              <span>Tracked bids</span>
              <strong>{@summary.tracked_count}</strong>
              <p>With a visible next step</p>
            </article>
            <article>
              <span>Oldest return window</span>
              <strong>{@summary.oldest_window}</strong>
              <p>Still open</p>
            </article>
          </div>
        </section>

        <%= if @items == [] do %>
          <.empty_state
            title="No failed auctions yet."
            body="Returns will show up here if any auction ends below its minimum raise."
          />
        <% else %>
          <section
            id="auction-returns-board"
            class="al-auction-returns-board al-panel"
            phx-hook="MissionMotion"
          >
            <div class="al-auction-returns-board-head">
              <div>
                <p class="al-kicker">Failed auctions</p>
                <h3>Open the auction or jump straight to your positions.</h3>
              </div>

              <span :if={@next_offset} class="badge badge-outline">More to load</span>
            </div>

            <div class="al-auction-returns-list">
              <article
                :for={auction <- @items}
                id={"auction-return-#{auction.id}"}
                class="al-auction-return-row"
              >
                <div class="al-auction-return-token">
                  <div class="al-auction-return-mark">{agent_monogram(auction.agent_name)}</div>
                  <div>
                    <strong>{auction.agent_name}</strong>
                    <p>{auction_symbol(auction)}</p>
                    <span>{auction.agent_id}</span>
                  </div>
                </div>

                <div class="al-auction-return-metric">
                  <span>Raised</span>
                  <strong>{auction.currency_raised || auction.total_bid_volume || "Unavailable"}</strong>
                  <p>{minimum_progress_copy(auction)}</p>
                </div>

                <div class="al-auction-return-metric">
                  <span>Minimum</span>
                  <strong>{auction.required_currency_raised || "Unavailable"}</strong>
                  <p>{minimum_status_copy(auction)}</p>
                </div>

                <div class="al-auction-return-metric">
                  <span>Ended</span>
                  <strong>{format_date(auction.ends_at)}</strong>
                  <p>{format_time(auction.ends_at)}</p>
                </div>

                <div class="al-auction-return-metric">
                  <span>Your status</span>
                  <strong>{auction.your_bid_status || "Watching only"}</strong>
                  <p>{status_copy(auction)}</p>
                </div>

                <div class="al-auction-return-actions">
                  <.link navigate={auction.detail_url} class="al-submit">Open return path</.link>
                  <.link navigate={~p"/positions"} class="al-ghost">Open positions</.link>
                </div>
              </article>
            </div>

            <div
              :if={@next_offset}
              id="auction-returns-more"
              phx-viewport-bottom="load_more"
              class="al-auction-returns-loading"
            >
              Loading more failed auctions…
            </div>
          </section>
        <% end %>
      </div>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end

  defp assign_returns(socket, items, next_offset) do
    socket
    |> assign(:items, items)
    |> assign(:next_offset, next_offset)
    |> assign(:summary, build_summary(items))
  end

  defp build_summary(items) do
    total_raised =
      items
      |> Enum.map(&(Map.get(&1, :currency_raised) || Map.get(&1, :total_bid_volume)))
      |> sum_currency()

    tracked_count =
      Enum.count(items, fn item ->
        case Map.get(item, :your_bid_status) do
          value when is_binary(value) and value != "" -> true
          _ -> false
        end
      end)

    %{
      failed_count: length(items),
      total_raised: total_raised,
      tracked_count: tracked_count,
      oldest_window: oldest_window_label(items)
    }
  end

  defp sum_currency(values) do
    values
    |> Enum.reduce(nil, fn value, acc ->
      case parse_decimal(value) do
        nil -> acc
        decimal when is_nil(acc) -> decimal
        decimal -> D.add(acc, decimal)
      end
    end)
    |> case do
      nil -> "Unavailable"
      decimal -> "$" <> format_decimal(decimal, 0)
    end
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(value) when is_integer(value), do: D.new(value)

  defp parse_decimal(value) when is_binary(value) do
    case D.parse(value) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  defp parse_decimal(_value), do: nil

  defp format_decimal(decimal, places) do
    decimal
    |> D.round(places)
    |> D.to_string(:normal)
    |> add_delimiters()
  end

  defp add_delimiters(value) do
    case String.split(value, ".", parts: 2) do
      [integer, fraction] -> add_integer_delimiters(integer) <> "." <> fraction
      [integer] -> add_integer_delimiters(integer)
    end
  end

  defp add_integer_delimiters(integer) do
    integer
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.join/1)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp oldest_window_label([]), do: "0 days"

  defp oldest_window_label(items) do
    items
    |> Enum.map(&days_since(&1.ends_at))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "0 days"
      values -> "#{Enum.max(values)} days"
    end
  end

  defp days_since(nil), do: nil

  defp days_since(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} ->
        DateTime.diff(DateTime.utc_now(), datetime, :second)
        |> max(0)
        |> Kernel./(86_400)
        |> floor()

      _ ->
        nil
    end
  end

  defp format_date(nil), do: "Unknown"

  defp format_date(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> Calendar.strftime(datetime, "%b %-d, %Y")
      _ -> "Unknown"
    end
  end

  defp format_time(nil), do: "Unknown"

  defp format_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> Calendar.strftime(datetime, "%H:%M UTC")
      _ -> "Unknown"
    end
  end

  defp minimum_progress_copy(%{minimum_raise_progress_percent: value}) when is_number(value) do
    "#{trunc(value)}% of minimum"
  end

  defp minimum_progress_copy(_auction), do: "Minimum pace unavailable"

  defp minimum_status_copy(%{minimum_raise_met: true}), do: "Already crossed once"
  defp minimum_status_copy(_auction), do: "Below target"

  defp status_copy(%{your_bid_status: value}) when is_binary(value) and value != "" do
    "Use the auction or positions page"
  end

  defp status_copy(_auction), do: "Open the auction to review final state"

  defp agent_monogram(name) when is_binary(name) do
    name
    |> String.split(~r/[\s-]+/, trim: true)
    |> Enum.map(&String.first/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(2)
    |> Enum.join()
    |> String.upcase()
  end

  defp agent_monogram(_name), do: "AL"

  defp auction_symbol(auction) do
    case Map.get(auction, :symbol) do
      value when is_binary(value) and value != "" -> value
      _ -> "Return path"
    end
  end

  defp launch_module do
    :autolaunch
    |> Application.get_env(:auction_returns_live, [])
    |> Keyword.get(:launch_module, Launch)
  end

  defp route_css, do: @auctions_css
end
