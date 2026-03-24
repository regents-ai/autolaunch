defmodule AutolaunchWeb.AuctionsLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.Launch
  alias AutolaunchWeb.LaunchComponents

  @poll_ms 15_000

  def mount(_params, _session, socket) do
    filters = %{"sort" => "hottest", "status" => "", "chain" => "", "mine_only" => false}

    if connected?(socket), do: Process.send_after(self(), :refresh, @poll_ms)

    {:ok,
     socket
     |> assign(:page_title, "Auctions")
     |> assign(:active_view, "auctions")
     |> assign(:chain_options, Launch.chain_options())
     |> assign(:filters, filters)
     |> assign(:auctions, Launch.list_auctions(filters, socket.assigns[:current_human]))}
  end

  def handle_event("filters_changed", %{"filters" => filters}, socket) do
    merged =
      socket.assigns.filters
      |> Map.merge(filters)
      |> Map.update("mine_only", false, &truthy?/1)

    {:noreply,
     socket
     |> assign(:filters, merged)
     |> assign(:auctions, Launch.list_auctions(merged, socket.assigns.current_human))}
  end

  def handle_info(:refresh, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @poll_ms)

    {:noreply,
     assign(
       socket,
       :auctions,
       Launch.list_auctions(socket.assigns.filters, socket.assigns.current_human)
     )}
  end

  def render(assigns) do
    active = Enum.count(assigns.auctions, &(&1.status in ["active", "ending-soon"]))
    expired = Enum.count(assigns.auctions, &(&1.status in ["settled", "pending-claim"]))
    mine = Enum.count(assigns.auctions, &(&1.your_bid_status not in [nil, "none"]))

    assigns =
      assigns
      |> assign(:active_count, active)
      |> assign(:expired_count, expired)
      |> assign(:mine_count, mine)

    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <section id="auctions-hero" class="al-hero al-panel" phx-hook="MissionMotion">
        <div>
          <p class="al-kicker">Auction Market</p>
          <h2>Sort for recent velocity, not stale lifetime volume.</h2>
          <p class="al-subcopy">
            Hottest is weighted toward recent bid velocity and recent volume so the market feels alive.
            Detail pages carry the deeper estimator and active/inactive thresholds.
          </p>

          <div class="al-hero-actions">
            <.link navigate={~p"/auctions/how-it-works"} class="al-cta-link">
              How auctions work
            </.link>
          </div>
        </div>

        <div class="al-stat-grid">
          <.stat_card title="Active auctions" value={Integer.to_string(@active_count)} />
          <.stat_card title="Expired" value={Integer.to_string(@expired_count)} />
          <.stat_card title="Your markets" value={Integer.to_string(@mine_count)} hint="Requires sign-in" />
        </div>
      </section>

      <section class="al-panel al-filter-panel">
        <form phx-change="filters_changed" class="al-filter-form">
          <label>
            <span>Sort</span>
            <select name="filters[sort]">
              <option value="hottest" selected={@filters["sort"] == "hottest"}>Hottest</option>
              <option value="recently_launched" selected={@filters["sort"] == "recently_launched"}>Recently launched</option>
              <option value="expired" selected={@filters["sort"] == "expired"}>Expired</option>
            </select>
          </label>

          <label>
            <span>Status</span>
            <select name="filters[status]">
              <option value="" selected={@filters["status"] == ""}>All</option>
              <option value="active" selected={@filters["status"] == "active"}>Active</option>
              <option value="expired" selected={@filters["status"] == "expired"}>Expired</option>
            </select>
          </label>

          <label>
            <span>Chain</span>
            <select name="filters[chain]">
              <option value="" selected={@filters["chain"] == ""}>All</option>
              <option
                :for={chain <- @chain_options}
                value={chain.key}
                selected={@filters["chain"] == chain.key}
              >
                {chain.label}
              </option>
            </select>
          </label>

          <label class="al-check-toggle">
            <input type="checkbox" name="filters[mine_only]" checked={@filters["mine_only"]} />
            <span>Mine only</span>
          </label>
        </form>
      </section>

      <%= if @auctions == [] do %>
        <.empty_state
          title="No auctions match the current filter."
          body="Relax the filters or wait for the next launch queue to settle into a live market."
        />
      <% else %>
        <section class="al-auction-grid">
          <%= for auction <- @auctions do %>
            <article class="al-panel al-auction-tile">
              <div class="al-auction-card-head">
                <div>
                  <p class="al-kicker">{auction.agent_id}</p>
                  <h3>{auction.agent_name}</h3>
                  <p class="al-inline-note">{auction.symbol} on {auction.chain}</p>
                </div>
                <div class="al-stack-right">
                  <.status_badge status={auction.status} />
                  <%= if auction.your_bid_status not in [nil, "none"] do %>
                    <.status_badge status={auction.your_bid_status} />
                  <% end %>
                </div>
              </div>

              <div class="al-stat-grid">
                <.stat_card title="Clearing price" value={auction.current_clearing_price} />
                <.stat_card title="Bid volume" value={auction.total_bid_volume} />
                <.stat_card title="Ends in" value={LaunchComponents.time_left_label(auction.ends_at)} />
              </div>

              <div class="al-pill-row">
                <span class="al-network-badge">{auction.chain}</span>
                <span class="al-network-badge">{auction.bidders} bids</span>
                <span class="al-network-badge">
                  ENS {if auction.ens_attached, do: "linked", else: "pending"}
                </span>
                <span class="al-network-badge">
                  World {if auction.world_registered, do: "attached", else: "pending"}
                </span>
              </div>

              <p class="al-inline-note">
                {listing_completion_copy(auction)}
              </p>

              <div class="al-action-row">
                <.link navigate={~p"/auctions/#{auction.id}"} class="al-submit">Inspect auction</.link>
              </div>
            </article>
          <% end %>
        </section>
      <% end %>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end

  defp truthy?(value), do: value in [true, "true", "1", 1, "on", "yes"]

  defp listing_completion_copy(%{
         world_registered: true,
         world_launch_count: count,
         ens_attached: true
       })
       when count > 0 do
    "ENS is linked, World proof is attached, and this human has launched #{count} tokens through autolaunch."
  end

  defp listing_completion_copy(%{world_registered: true, ens_attached: true}),
    do: "ENS is linked and World proof is attached."

  defp listing_completion_copy(%{world_registered: true}),
    do: "World proof is attached. ENS still needs to be linked on the creator identity."

  defp listing_completion_copy(%{ens_attached: true}),
    do: "ENS is linked. World proof still needs a human to finish registration."

  defp listing_completion_copy(_auction),
    do: "Both the ENS link and the World proof are still open follow-up steps."
end
