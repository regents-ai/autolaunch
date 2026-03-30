defmodule AutolaunchWeb.AuctionsLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.Launch
  alias AutolaunchWeb.LaunchComponents
  alias AutolaunchWeb.RegentScenes

  @poll_ms 15_000

  def mount(_params, _session, socket) do
    filters = %{"sort" => "hottest", "status" => "", "chain" => "", "mine_only" => false}

    if connected?(socket), do: Process.send_after(self(), :refresh, @poll_ms)

    {:ok,
     socket
     |> assign(:page_title, "Auctions")
     |> assign(:active_view, "auctions")
     |> assign(:chain_options, launch_module().chain_options())
     |> assign(:filters, filters)
     |> assign(:auctions, launch_module().list_auctions(filters, socket.assigns[:current_human]))
     |> assign_regent_scene()}
  end

  def handle_event("filters_changed", %{"filters" => filters}, socket) do
    merged =
      socket.assigns.filters
      |> Map.merge(filters)
      |> Map.update("mine_only", false, &truthy?/1)

    {:noreply,
     socket
     |> assign(:filters, merged)
     |> assign(:auctions, launch_module().list_auctions(merged, socket.assigns.current_human))
     |> assign_regent_scene()}
  end

  def handle_event("regent:node_select", %{"meta" => %{"auctionId" => auction_id}}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/auctions/#{auction_id}")}
  end

  def handle_event("regent:node_select", _params, socket), do: {:noreply, socket}

  def handle_event("regent:node_hover", _params, socket), do: {:noreply, socket}
  def handle_event("regent:surface_ready", _params, socket), do: {:noreply, socket}

  def handle_event("regent:surface_error", _params, socket) do
    {:noreply, put_flash(socket, :error, "The auction market surface could not render in this browser session.")}
  end

  def handle_info(:refresh, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @poll_ms)

    {:noreply,
     assign(
       socket,
       :auctions,
       launch_module().list_auctions(socket.assigns.filters, socket.assigns.current_human)
     )
     |> assign_regent_scene()}
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
      <section class="al-regent-shell">
        <.surface
          id="auctions-regent-surface"
          class="rg-regent-theme-autolaunch"
          scene={@regent_scene}
          scene_version={@regent_scene_version}
          selected_node_id={@regent_selected_node_id}
          theme="autolaunch"
          camera_distance={24}
        >
          <:chamber>
            <.chamber
              id="auctions-regent-chamber"
              title="Auction market"
              subtitle="Velocity-first view"
              summary="The symbolic market shell keeps live status and urgency legible. Detailed math, filters, and irreversible actions stay in the regular cards below."
            >
              <div class="al-launch-tags" aria-label="Auction market summary">
                <span class="al-launch-tag">Live auctions: {@active_count}</span>
                <span class="al-launch-tag">Settling: {@expired_count}</span>
                <span class="al-launch-tag">Your markets: {@mine_count}</span>
              </div>
            </.chamber>
          </:chamber>

          <:ledger>
            <.ledger
              id="auctions-regent-ledger"
              title="Active filters"
              subtitle="Use the regular filter panel below to change the market slice."
            >
              <table class="rg-table">
                <tbody>
                  <tr>
                    <th scope="row">Sort</th>
                    <td>{@filters["sort"]}</td>
                  </tr>
                  <tr>
                    <th scope="row">Status</th>
                    <td>{if @filters["status"] == "", do: "All", else: @filters["status"]}</td>
                  </tr>
                  <tr>
                    <th scope="row">Chain</th>
                    <td>{if @filters["chain"] == "", do: "All", else: @filters["chain"]}</td>
                  </tr>
                </tbody>
              </table>
            </.ledger>
          </:ledger>
        </.surface>
      </section>

      <section id="auctions-hero" class="al-hero al-panel" phx-hook="MissionMotion">
        <div>
          <p class="al-kicker">Auction Market</p>
          <h2>Sort for recent velocity, not stale lifetime volume.</h2>
          <p class="al-subcopy">
            Hottest is weighted toward recent bid velocity and recent volume so the market stays current.
            Detail pages carry the deeper estimator and lifecycle thresholds.
          </p>

          <div class="al-hero-actions">
            <.link navigate={~p"/how-auctions-work"} class="al-cta-link">
              How auctions work
            </.link>
          </div>
        </div>

        <div class="al-stat-grid">
          <.stat_card title="Live auctions" value={Integer.to_string(@active_count)} />
          <.stat_card title="Settling" value={Integer.to_string(@expired_count)} />
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
                <option value="ending-soon" selected={@filters["status"] == "ending-soon"}>Ending soon</option>
                <option value="borderline" selected={@filters["status"] == "borderline"}>Borderline</option>
                <option value="inactive" selected={@filters["status"] == "inactive"}>Inactive</option>
                <option value="claimable" selected={@filters["status"] == "claimable"}>Claimable</option>
                <option value="pending-claim" selected={@filters["status"] == "pending-claim"}>Pending claim</option>
                <option value="claimed" selected={@filters["status"] == "claimed"}>Claimed</option>
                <option value="exited" selected={@filters["status"] == "exited"}>Exited</option>
                <option value="settled" selected={@filters["status"] == "settled"}>Settled</option>
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
          body="Relax the filters or wait for the next launch queue to fill the market."
        />
      <% else %>
        <section class="al-auction-grid">
          <%= for auction <- @auctions do %>
            <article id={"auction-tile-#{auction.id}"} class="al-panel al-auction-tile" phx-hook="MissionMotion">
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
                  Trust {if auction.world_registered, do: "checked", else: "pending"}
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
    "ENS is linked, the trust check is complete, and this operator has launched #{count} tokens through autolaunch."
  end

  defp listing_completion_copy(%{world_registered: true, ens_attached: true}),
    do: "ENS is linked and the trust check is complete."

  defp listing_completion_copy(%{world_registered: true}),
    do: "The trust check is complete. ENS still needs to be linked on the creator identity."

  defp listing_completion_copy(%{ens_attached: true}),
    do: "ENS is linked. The trust check still needs to be completed."

  defp listing_completion_copy(_auction),
    do: "Both the ENS link and the trust check are still open follow-up steps."

  defp launch_module do
    :autolaunch
    |> Application.get_env(:auctions_live, [])
    |> Keyword.get(:launch_module, Launch)
  end

  defp assign_regent_scene(socket) do
    next_version = (socket.assigns[:regent_scene_version] || 0) + 1
    scene = RegentScenes.auctions(socket.assigns.auctions, socket.assigns.filters)

    socket
    |> assign(:regent_scene_version, next_version)
    |> assign(:regent_scene, Map.put(scene, "sceneVersion", next_version))
    |> assign(:regent_selected_node_id, "auction:market")
  end
end
