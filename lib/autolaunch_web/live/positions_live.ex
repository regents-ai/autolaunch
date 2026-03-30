defmodule AutolaunchWeb.PositionsLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.Launch

  @poll_ms 15_000

  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @poll_ms)

    filters = %{"status" => ""}

    {:ok,
     socket
     |> assign(:page_title, "Positions")
     |> assign(:active_view, "positions")
     |> assign(:filters, filters)
     |> assign(:positions, load_positions(socket.assigns[:current_human], filters))}
  end

  def handle_event("filters_changed", %{"filters" => filters}, socket) do
    merged = Map.merge(socket.assigns.filters, filters)

    {:noreply,
     socket
     |> assign(:filters, merged)
     |> assign(:positions, load_positions(socket.assigns.current_human, merged))}
  end

  def handle_event("wallet_tx_started", %{"message" => message}, socket) do
    {:noreply, put_flash(socket, :info, message)}
  end

  def handle_event("wallet_tx_registered", %{"message" => message}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, message)
     |> assign(:positions, load_positions(socket.assigns.current_human, socket.assigns.filters))}
  end

  def handle_event("wallet_tx_error", %{"message" => message}, socket) do
    {:noreply, put_flash(socket, :error, message)}
  end

  def handle_info(:refresh, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @poll_ms)

    {:noreply,
     assign(
       socket,
       :positions,
       load_positions(socket.assigns.current_human, socket.assigns.filters)
     )}
  end

  def render(assigns) do
    active = Enum.count(assigns.positions, &(&1.status == "active"))
    borderline = Enum.count(assigns.positions, &(&1.status == "borderline"))
    inactive = Enum.count(assigns.positions, &(&1.status == "inactive"))
    claimable = Enum.count(assigns.positions, &(&1.status == "claimable"))

    assigns =
      assigns
      |> assign(:active_count, active)
      |> assign(:borderline_count, borderline)
      |> assign(:inactive_count, inactive)
      |> assign(:claimable_count, claimable)

    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <section id="positions-hero" class="al-hero al-panel" phx-hook="MissionMotion">
        <div>
          <p class="al-kicker">Positions</p>
          <h2>Returning users should not have to rediscover where each bid stands.</h2>
          <p class="al-subcopy">
            Every bid is labeled against the current clearing price and lifecycle state so the next action is obvious.
          </p>
        </div>

        <div class="al-stat-grid">
          <.stat_card title="Active" value={Integer.to_string(@active_count)} />
          <.stat_card title="Borderline" value={Integer.to_string(@borderline_count)} />
          <.stat_card title="Inactive" value={Integer.to_string(@inactive_count)} />
          <.stat_card title="Claimable" value={Integer.to_string(@claimable_count)} />
        </div>
      </section>

        <%= if is_nil(@current_human) do %>
        <.empty_state
          title="Sign in to inspect your bids."
          body="Positions are tied to the Privy-backed session and wallet binding."
        />
      <% else %>
        <section class="al-panel al-filter-panel">
          <form phx-change="filters_changed" class="al-filter-form">
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
        </form>
      </section>

        <%= if @positions == [] do %>
          <.empty_state
            title="No bids match the current filter."
            body="Place a bid from an auction detail page or clear the status filter to see every state."
          />
        <% else %>
          <section class="al-position-list">
            <article :for={position <- @positions} id={"position-card-#{position.bid_id}"} class="al-panel al-position-card" phx-hook="MissionMotion">
              <div class="al-agent-card-head">
                <div>
                  <p class="al-kicker">{position.chain}</p>
                  <h3>{position.agent_name}</h3>
                  <p class="al-inline-note">{position.bid_id}</p>
                </div>
                <.status_badge status={position.status} />
              </div>

              <div class="al-stat-grid">
                <.stat_card title="Amount" value={position.amount} />
                <.stat_card title="Max price" value={position.max_price} />
                <.stat_card title="Current clearing price" value={position.current_clearing_price} />
                <.stat_card title="Inactive above" value={position.inactive_above_price} />
              </div>

              <div class="al-inline-banner">
                <strong>{status_copy(position.status)}</strong>
                <p>{position.next_action_label}</p>
              </div>

              <div class="al-action-row">
                <.link navigate={~p"/auctions/#{position.auction_id}"} class="al-ghost">Inspect auction</.link>
                <.wallet_tx_button
                  :if={position.tx_actions.exit}
                  id={"positions-exit-#{position.bid_id}"}
                  class="al-ghost"
                  tx_request={position.tx_actions.exit.tx_request}
                  register_endpoint={~p"/api/bids/#{position.bid_id}/exit"}
                  pending_message="Exit transaction sent. Waiting for confirmation."
                  success_message="Bid exit registered."
                >
                  Exit bid
                </.wallet_tx_button>
                <.wallet_tx_button
                  :if={position.tx_actions.claim}
                  id={"positions-claim-#{position.bid_id}"}
                  class="al-submit"
                  tx_request={position.tx_actions.claim.tx_request}
                  register_endpoint={~p"/api/bids/#{position.bid_id}/claim"}
                  pending_message="Claim transaction sent. Waiting for confirmation."
                  success_message="Claim registered."
                >
                  Claim tokens
                </.wallet_tx_button>
              </div>
            </article>
          </section>
        <% end %>
      <% end %>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end

  defp load_positions(nil, _filters), do: []

  defp load_positions(current_human, filters),
    do: launch_module().list_positions(current_human, filters)

  defp status_copy("active"), do: "Active — receiving tokens at the current clearing price."
  defp status_copy("ending-soon"), do: "Ending soon — the auction is near the finish line."
  defp status_copy("borderline"), do: "Borderline — one move away from inactive."

  defp status_copy("inactive"),
    do: "Inactive — not receiving tokens at the current clearing price."

  defp status_copy("claimable"),
    do: "Claimable — the bid is exited and purchased tokens can be claimed."

  defp status_copy("pending-claim"),
    do: "Pending claim — the auction has settled, but the claim still needs to be completed."

  defp status_copy("exited"), do: "Exited — this bid is no longer participating."
  defp status_copy("claimed"), do: "Claimed — purchased tokens have already been withdrawn."
  defp status_copy("settled"), do: "Settled — the auction outcome is finalized."
  defp status_copy(_status), do: "Monitor this position from the auction detail page."

  defp launch_module do
    :autolaunch
    |> Application.get_env(:positions_live, [])
    |> Keyword.get(:launch_module, Launch)
  end
end
