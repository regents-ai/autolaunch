defmodule AutolaunchWeb.PositionsLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.Launch
  alias AutolaunchWeb.Live.Refreshable

  @poll_ms 15_000
  @default_filters %{"status" => "", "search" => ""}

  def mount(_params, _session, socket) do
    all_positions = load_positions(socket.assigns[:current_human])

    {:ok,
     socket
     |> Refreshable.schedule(@poll_ms)
     |> Refreshable.subscribe([:positions, :market, :system])
     |> assign(:page_title, "Positions")
     |> assign(:active_view, "positions")
     |> assign(:all_positions, all_positions)
     |> assign(:positions, all_positions)}
  end

  def handle_params(params, _uri, socket) do
    filters = sanitize_filters(Map.merge(@default_filters, params))

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:positions, filter_positions(socket.assigns.all_positions, filters))}
  end

  def handle_event("filters_changed", %{"filters" => filters}, socket) do
    merged = Map.merge(socket.assigns.filters, filters)

    {:noreply, push_patch(socket, to: ~p"/positions?#{filter_query(merged)}")}
  end

  def handle_event("quick_filter", %{"status" => status}, socket) do
    filters = Map.put(socket.assigns.filters, "status", status)

    {:noreply, push_patch(socket, to: ~p"/positions?#{filter_query(filters)}")}
  end

  def handle_event("wallet_tx_started", %{"message" => message}, socket) do
    {:noreply, Refreshable.wallet_started(socket, message)}
  end

  def handle_event("wallet_tx_registered", %{"message" => message}, socket) do
    {:noreply, Refreshable.wallet_registered(socket, message, &reload_positions/1)}
  end

  def handle_event("wallet_tx_error", %{"message" => message}, socket) do
    {:noreply, Refreshable.wallet_error(socket, message)}
  end

  def handle_info(:refresh, socket) do
    {:noreply, Refreshable.refresh(socket, @poll_ms, &reload_positions/1)}
  end

  def handle_info({:autolaunch_live_update, :changed}, socket) do
    {:noreply, reload_positions(socket)}
  end

  def render(assigns) do
    summary = positions_summary(assigns.all_positions)
    recent_activity = recent_activity_rows(assigns.all_positions)

    assigns =
      assigns
      |> assign(:summary, summary)
      |> assign(:recent_activity, recent_activity)

    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <.positions_styles />

      <section class="al-positions-page">
        <header class="al-positions-header">
          <div class="al-positions-header-copy">
            <p class="al-kicker">Positions</p>
            <h1>Portfolio overview</h1>
            <p>
              Keep bids, claims, and failed-auction returns in one action desk so you only open the market page when you need detail.
            </p>
          </div>

          <div :if={!is_nil(@current_human)} class="al-positions-header-actions">
            <span class="al-positions-refresh-note">Live triage refreshes every {poll_seconds()}s</span>
            <.link navigate={~p"/profile"} class="al-ghost">Open profile</.link>
          </div>
        </header>

        <%= if is_nil(@current_human) do %>
          <.empty_state
            title="Sign in to inspect your bids."
            body="This workspace keeps your active bids, claims, and returns in one place."
            mark="PO"
            action_label="Browse auctions"
            action_href={~p"/auctions"}
          />
        <% else %>
          <section
            id="positions-summary-row"
            class="al-positions-summary-row"
            phx-hook="MissionMotion"
          >
            <article class="al-panel al-positions-summary-card">
              <span>Tracked exposure</span>
              <strong>{display_money(@summary.tracked_exposure)}</strong>
              <p>{@summary.total_count} tracked positions</p>
            </article>

            <article class="al-panel al-positions-summary-card">
              <span>Claimable</span>
              <strong>{@summary.claimable_count}</strong>
              <p>Ready to withdraw now</p>
            </article>

            <article class="al-panel al-positions-summary-card">
              <span>Returns available</span>
              <strong>{@summary.returnable_count}</strong>
              <p>Failed raises</p>
            </article>

            <article class="al-panel al-positions-summary-card">
              <span>Active bids</span>
              <strong>{@summary.active_total_count}</strong>
              <p>Still in market</p>
            </article>

            <article class="al-panel al-positions-summary-card">
              <span>Auction wins</span>
              <strong>{@summary.won_total_count}</strong>
              <p>Settled or claimable</p>
            </article>
          </section>

          <.action_desk
            id="positions-action-desk"
            title={positions_action_title(@summary)}
            body={positions_action_body(@summary)}
            status_label={"#{@summary.claimable_count} claimable / #{@summary.returnable_count} returns"}
            class="al-positions-action-desk"
          >
            <:primary>
              <button
                type="button"
                class="al-submit"
                phx-click="quick_filter"
                phx-value-status={positions_primary_status(@summary)}
              >
                {positions_primary_label(@summary)}
              </button>
            </:primary>
            <:secondary>
              <.link navigate={~p"/auctions"} class="al-ghost">Browse auctions</.link>
            </:secondary>
            <:aside>
              <div class="al-positions-desk-ledger">
                <span>Tracked exposure</span>
                <strong>{display_money(@summary.tracked_exposure)}</strong>
                <p>{@summary.total_count} positions watched from this wallet</p>
              </div>
            </:aside>
          </.action_desk>

          <section
            id="positions-priority-grid"
            class="al-positions-priority-grid"
            phx-hook="MissionMotion"
          >
            <article class="al-panel al-positions-priority-card">
              <div class="al-positions-priority-copy">
                <p class="al-kicker">Claimable</p>
                <h2>Claim what is ready before you do anything else.</h2>
                <p>
                  {claimable_priority_copy(@summary.claimable_count)}
                </p>
              </div>

              <div class="al-positions-priority-actions">
                <button
                  type="button"
                  class="al-submit"
                  phx-click="quick_filter"
                  phx-value-status="claimable"
                >
                  Review claimable
                </button>
                <.link navigate={~p"/auctions"} class="al-ghost">Open auctions</.link>
              </div>
            </article>

            <article class="al-panel al-positions-priority-card">
              <div class="al-positions-priority-copy">
                <p class="al-kicker">Returns available</p>
                <h2>Failed auctions should be cleared out quickly.</h2>
                <p>
                  {return_priority_copy(@summary.returnable_count)}
                </p>
              </div>

              <div class="al-positions-priority-actions">
                <button
                  type="button"
                  class="al-ghost"
                  phx-click="quick_filter"
                  phx-value-status="returnable"
                >
                  Review returns
                </button>
                <.link navigate={~p"/auctions"} class="al-ghost">Browse markets</.link>
              </div>
            </article>
          </section>

          <section
            id="positions-main-grid"
            class="al-positions-main-grid"
            phx-hook="MissionMotion"
          >
            <section class="al-panel al-positions-table-card">
              <div class="al-positions-table-topline">
                <div>
                  <p class="al-kicker">Your positions</p>
                  <h3>Use the quick buckets first, then inspect the auction only when you need detail.</h3>
                </div>

                <form phx-change="filters_changed" class="al-positions-filter-row">
                  <div class="al-account-pill-row" role="group" aria-label="Quick position filters">
                    <button
                      type="button"
                      class={["al-account-pill", @filters["status"] == "" && "is-active"]}
                      phx-click="quick_filter"
                      phx-value-status=""
                    >
                      All
                    </button>
                    <button
                      type="button"
                      class={["al-account-pill", @filters["status"] == "claimable" && "is-active"]}
                      phx-click="quick_filter"
                      phx-value-status="claimable"
                    >
                      Claimable
                    </button>
                    <button
                      type="button"
                      class={["al-account-pill", @filters["status"] == "returnable" && "is-active"]}
                      phx-click="quick_filter"
                      phx-value-status="returnable"
                    >
                      Returns
                    </button>
                    <button
                      type="button"
                      class={["al-account-pill", @filters["status"] == "active" && "is-active"]}
                      phx-click="quick_filter"
                      phx-value-status="active"
                    >
                      Active
                    </button>
                    <button
                      type="button"
                      class={["al-account-pill", @filters["status"] == "borderline" && "is-active"]}
                      phx-click="quick_filter"
                      phx-value-status="borderline"
                    >
                      Borderline
                    </button>
                  </div>

                  <div class="al-account-search">
                    <label class="sr-only" for="positions-search">Search positions</label>
                    <input
                      id="positions-search"
                      type="search"
                      name="filters[search]"
                      value={@filters["search"]}
                      placeholder="Search by token or auction ID"
                    />
                  </div>
                </form>
              </div>

              <%= if @positions == [] do %>
                <.empty_state
                  title="No bids match the current view."
                  body="Clear the search or switch buckets to see more positions."
                  mark="FI"
                  action_label="Show all positions"
                  action_href={~p"/positions"}
                />
              <% else %>
                <div class="al-account-table-shell">
                  <table class="al-account-position-table">
                    <thead>
                      <tr>
                        <th>Token / auction</th>
                        <th>Exposure</th>
                        <th>Max price</th>
                        <th>Current price</th>
                        <th>Status</th>
                        <th>Next action</th>
                        <th>Action</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={position <- @positions} id={"position-row-#{position.bid_id}"}>
                        <td>
                          <div class="al-account-position-token">
                            <strong>{position.agent_name}</strong>
                            <span class="al-account-token-meta">{position.chain}</span>
                            <span class="al-account-token-meta">
                              Auction {position.auction_id} • {position.bid_id}
                            </span>
                          </div>
                        </td>
                        <td>
                          <div class="al-account-position-stack">
                            <strong>{position.amount}</strong>
                            <span class="al-account-token-meta">{status_copy(position.status)}</span>
                          </div>
                        </td>
                        <td>
                          <div class="al-account-position-stack">
                            <strong>{position.max_price}</strong>
                            <span class="al-account-token-meta">Bid ceiling</span>
                          </div>
                        </td>
                        <td>
                          <div class="al-account-position-stack">
                            <strong>{position.current_clearing_price}</strong>
                            <span class="al-account-token-meta">
                              Inactive above {position.inactive_above_price}
                            </span>
                          </div>
                        </td>
                        <td><.status_badge status={position.status} /></td>
                        <td>
                          <div class="al-account-next-step">
                            <strong>{position.next_action_label}</strong>
                            <span class="al-account-token-meta">{status_copy(position.status)}</span>
                          </div>
                        </td>
                        <td>
                          <div class="al-account-table-actions">
                            <.link navigate={~p"/auctions/#{position.auction_id}"} class="al-ghost">
                              Inspect auction
                            </.link>
                            <.wallet_tx_button
                              :if={return_action(position)}
                              id={"positions-return-#{position.bid_id}"}
                              class="al-submit"
                              tx_request={return_action(position).tx_request}
                              register_endpoint={~p"/v1/app/bids/#{position.bid_id}/return-usdc"}
                              pending_message="Return transaction sent. Waiting for confirmation."
                              success_message="USDC return registered."
                            >
                              Return USDC
                            </.wallet_tx_button>
                            <.wallet_tx_button
                              :if={tx_action(position, :exit) && is_nil(return_action(position))}
                              id={"positions-exit-#{position.bid_id}"}
                              class="al-ghost"
                              tx_request={tx_action(position, :exit).tx_request}
                              register_endpoint={~p"/v1/app/bids/#{position.bid_id}/exit"}
                              pending_message="Exit transaction sent. Waiting for confirmation."
                              success_message="Bid exit registered."
                            >
                              Exit bid
                            </.wallet_tx_button>
                            <.wallet_tx_button
                              :if={tx_action(position, :claim)}
                              id={"positions-claim-#{position.bid_id}"}
                              class="al-submit"
                              tx_request={tx_action(position, :claim).tx_request}
                              register_endpoint={~p"/v1/app/bids/#{position.bid_id}/claim"}
                              pending_message="Claim transaction sent. Waiting for confirmation."
                              success_message="Claim registered."
                            >
                              Claim tokens
                            </.wallet_tx_button>
                          </div>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              <% end %>
            </section>

            <aside class="al-panel al-positions-activity-card">
              <div class="al-positions-activity-head">
                <div>
                  <p class="al-kicker">Recent activity</p>
                  <h3>Keep the newest actions close.</h3>
                </div>
              </div>

              <%= if @recent_activity == [] do %>
                <.empty_state
                  title="No position activity yet."
                  body="Once you place bids or claim balances, the latest actions will show up here."
                  mark="AC"
                  action_label="Open auctions"
                  action_href={~p"/auctions"}
                />
              <% else %>
                <div class="al-positions-activity-list">
                  <article :for={item <- @recent_activity} class="al-positions-activity-row">
                    <div>
                      <strong>{item.title}</strong>
                      <p>{item.body}</p>
                    </div>
                    <span>{item.time}</span>
                  </article>
                </div>
              <% end %>
            </aside>
          </section>
        <% end %>
      </section>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end

  defp load_positions(nil), do: []

  defp load_positions(current_human),
    do: launch_module().list_positions(current_human, %{"status" => ""})

  defp reload_positions(socket) do
    all_positions = load_positions(socket.assigns.current_human)

    assign(
      socket,
      all_positions: all_positions,
      positions: filter_positions(all_positions, socket.assigns.filters)
    )
  end

  defp filter_positions(positions, filters) do
    positions
    |> filter_by_status(filters["status"])
    |> filter_by_search(filters["search"])
  end

  defp sanitize_filters(filters) do
    %{
      "status" => sanitize_status(Map.get(filters, "status")),
      "search" => filters |> Map.get("search", "") |> to_string() |> String.trim()
    }
  end

  defp sanitize_status(status)
       when status in ["", "active", "borderline", "claimable", "returnable", "inactive"],
       do: status

  defp sanitize_status(_status), do: ""

  defp filter_query(filters) do
    filters
    |> sanitize_filters()
    |> Enum.reject(fn {key, value} ->
      Map.get(@default_filters, key) == value or value in [nil, ""]
    end)
    |> Map.new()
  end

  defp filter_by_status(positions, nil), do: positions
  defp filter_by_status(positions, ""), do: positions
  defp filter_by_status(positions, status), do: Enum.filter(positions, &(&1.status == status))

  defp filter_by_search(positions, nil), do: positions
  defp filter_by_search(positions, ""), do: positions

  defp filter_by_search(positions, search) do
    needle = String.downcase(String.trim(search))

    Enum.filter(positions, fn position ->
      [
        position.agent_name,
        position.bid_id,
        position.auction_id,
        position.chain
      ]
      |> Enum.any?(fn value ->
        value
        |> to_string()
        |> String.downcase()
        |> String.contains?(needle)
      end)
    end)
  end

  defp positions_summary(positions) do
    active = Enum.count(positions, &(&1.status == "active"))
    borderline = Enum.count(positions, &(&1.status == "borderline"))
    ending_soon = Enum.count(positions, &(&1.status == "ending-soon"))

    %{
      total_count: length(positions),
      claimable_count: Enum.count(positions, &(&1.status == "claimable")),
      returnable_count: Enum.count(positions, &(&1.status == "returnable")),
      active_total_count: active + borderline + ending_soon,
      won_total_count: Enum.count(positions, &(&1.status in ["claimable", "claimed", "settled"])),
      tracked_exposure: positions_total(positions)
    }
  end

  defp positions_total(positions) do
    Enum.reduce(positions, Decimal.new(0), fn position, acc ->
      case Decimal.parse(position.amount || "") do
        {decimal, ""} -> Decimal.add(acc, decimal)
        _ -> acc
      end
    end)
  end

  defp recent_activity_rows(positions) do
    positions
    |> Enum.sort_by(&activity_sort_key/1, {:desc, DateTime})
    |> Enum.take(5)
    |> Enum.map(fn position ->
      %{
        title: recent_activity_title(position),
        body: "#{position.agent_name} • Auction #{position.auction_id}",
        time: activity_time(Map.get(position, :inserted_at))
      }
    end)
  end

  defp activity_sort_key(%{inserted_at: value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> datetime
      _ -> DateTime.from_unix!(0)
    end
  end

  defp activity_sort_key(_position), do: DateTime.from_unix!(0)

  defp recent_activity_title(%{status: "claimable"}), do: "Claim now"
  defp recent_activity_title(%{status: "returnable"}), do: "Return available"
  defp recent_activity_title(%{status: "inactive"}), do: "Bid needs exit"
  defp recent_activity_title(%{status: "borderline"}), do: "Watch this bid"
  defp recent_activity_title(%{status: "active"}), do: "Bid is active"
  defp recent_activity_title(%{status: "claimed"}), do: "Tokens claimed"
  defp recent_activity_title(_position), do: "Review position"

  defp activity_time(nil), do: "Now"

  defp activity_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} ->
        hours = max(DateTime.diff(DateTime.utc_now(), datetime, :hour), 0)

        cond do
          hours == 0 -> "Now"
          hours < 24 -> "#{hours}h ago"
          true -> "#{div(hours, 24)}d ago"
        end

      _ ->
        "Now"
    end
  end

  defp claimable_priority_copy(0), do: "No positions are ready to claim at the moment."

  defp claimable_priority_copy(count),
    do: "#{count} positions can move tokens or balances out right now."

  defp return_priority_copy(0), do: "No failed-auction returns are waiting right now."

  defp return_priority_copy(count),
    do: "#{count} positions can return USDC from failed raises."

  defp positions_action_title(%{claimable_count: count}) when count > 0,
    do: "Claim ready balances first."

  defp positions_action_title(%{returnable_count: count}) when count > 0,
    do: "Clear failed-auction returns."

  defp positions_action_title(%{active_total_count: count}) when count > 0,
    do: "Watch active bids."

  defp positions_action_title(_summary), do: "No wallet action is waiting."

  defp positions_action_body(%{claimable_count: count}) when count > 0,
    do: "#{count} positions can be claimed now. Review them before checking new markets."

  defp positions_action_body(%{returnable_count: count}) when count > 0,
    do: "#{count} positions can return USDC from failed raises."

  defp positions_action_body(%{active_total_count: count}) when count > 0,
    do: "#{count} active bids are still moving with the market."

  defp positions_action_body(_summary),
    do: "New bids, claims, and returns will collect here once this wallet is active."

  defp positions_primary_status(%{claimable_count: count}) when count > 0, do: "claimable"
  defp positions_primary_status(%{returnable_count: count}) when count > 0, do: "returnable"
  defp positions_primary_status(_summary), do: ""

  defp positions_primary_label(%{claimable_count: count}) when count > 0, do: "Review claims"
  defp positions_primary_label(%{returnable_count: count}) when count > 0, do: "Review returns"
  defp positions_primary_label(_summary), do: "Show all positions"

  defp status_copy("active"), do: "Active — receiving tokens at the current clearing price."
  defp status_copy("ending-soon"), do: "Ending soon — the auction is near the finish line."
  defp status_copy("borderline"), do: "Borderline — one move away from inactive."

  defp status_copy("inactive"),
    do: "Inactive — not receiving tokens at the current clearing price."

  defp status_copy("returnable"),
    do: "Returnable — this auction failed its minimum raise and your USDC can be returned."

  defp status_copy("claimable"),
    do: "Claimable — the bid is exited and purchased tokens can be claimed."

  defp status_copy("pending-claim"),
    do: "Pending claim — the auction has settled, but the claim still needs to be completed."

  defp status_copy("exited"), do: "Exited — this bid is no longer participating."
  defp status_copy("claimed"), do: "Claimed — purchased tokens have already been withdrawn."
  defp status_copy("settled"), do: "Settled — the auction outcome is finalized."
  defp status_copy(_status), do: "Monitor this position from the auction detail page."

  defp return_action(position) when is_map(position), do: Map.get(position, :return_action)

  defp tx_action(position, action) when is_map(position) do
    position
    |> Map.get(:tx_actions, %{})
    |> Map.get(action)
  end

  defp display_money(%Decimal{} = value),
    do: "#{Decimal.round(value, 2) |> Decimal.to_string(:normal)} USDC"

  defp display_money(value) when is_binary(value), do: "#{value} USDC"

  defp poll_seconds, do: div(@poll_ms, 1_000)

  defp positions_styles(assigns) do
    ~H"""
    <style>
      .al-positions-page {
        display: grid;
        gap: clamp(1rem, 2vw, 1.5rem);
      }

      .al-positions-header,
      .al-positions-summary-card,
      .al-positions-priority-card,
      .al-positions-table-card,
      .al-positions-activity-card {
        border: 1px solid color-mix(in srgb, var(--al-border) 88%, white 12%);
        background: color-mix(in srgb, var(--al-panel-strong) 94%, white 6%);
        box-shadow: 0 20px 60px -48px rgba(17, 35, 64, 0.2);
      }

      .al-positions-header {
        border-radius: 1.5rem;
        padding: clamp(1.1rem, 2.4vw, 1.45rem);
        display: flex;
        justify-content: space-between;
        align-items: flex-start;
        gap: 1rem;
      }

      .al-positions-header-copy,
      .al-positions-header-actions,
      .al-positions-priority-copy {
        display: grid;
        gap: 0.45rem;
      }

      .al-positions-header-copy h1,
      .al-positions-table-topline h3,
      .al-positions-activity-head h3,
      .al-positions-priority-copy h2 {
        margin: 0;
      }

      .al-positions-header-copy h1 {
        font-size: clamp(2rem, 4vw, 3rem);
        line-height: 0.95;
      }

      .al-positions-header-copy p:not(.al-kicker),
      .al-positions-refresh-note,
      .al-positions-priority-copy p,
      .al-positions-activity-row p {
        margin: 0;
        color: var(--al-muted);
      }

      .al-positions-header-actions {
        justify-items: end;
      }

      .al-positions-summary-row {
        display: grid;
        gap: 1rem;
        grid-template-columns: repeat(5, minmax(0, 1fr));
      }

      .al-positions-summary-card {
        border-radius: 1.35rem;
        padding: 1rem;
        display: grid;
        gap: 0.25rem;
      }

      .al-positions-summary-card span,
      .al-positions-summary-card p {
        color: var(--al-muted);
      }

      .al-positions-summary-card strong {
        font-family: var(--al-font-display);
        font-size: clamp(1.4rem, 2.3vw, 2rem);
      }

      .al-positions-priority-grid,
      .al-positions-main-grid {
        display: grid;
        gap: 1rem;
      }

      .al-positions-priority-grid {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }

      .al-positions-priority-card,
      .al-positions-table-card,
      .al-positions-activity-card {
        border-radius: 1.45rem;
        padding: 1rem 1.1rem;
      }

      .al-positions-priority-card {
        display: flex;
        justify-content: space-between;
        gap: 1rem;
        align-items: flex-end;
      }

      .al-positions-priority-actions {
        display: flex;
        gap: 0.7rem;
        flex-wrap: wrap;
      }

      .al-positions-main-grid {
        grid-template-columns: minmax(0, 1.55fr) minmax(18rem, 0.7fr);
        align-items: start;
      }

      .al-positions-table-topline {
        display: grid;
        gap: 0.9rem;
      }

      .al-positions-filter-row {
        display: grid;
        gap: 0.8rem;
        grid-template-columns: minmax(0, 1fr) minmax(14rem, 18rem);
        align-items: center;
      }

      .al-positions-activity-list {
        display: grid;
        gap: 0.8rem;
      }

      .al-positions-activity-row {
        display: flex;
        justify-content: space-between;
        gap: 0.8rem;
        padding-bottom: 0.85rem;
        border-bottom: 1px solid color-mix(in srgb, var(--al-border) 82%, white 18%);
      }

      .al-positions-activity-row:last-child {
        border-bottom: none;
        padding-bottom: 0;
      }

      .al-positions-activity-row span {
        color: var(--al-muted);
        white-space: nowrap;
      }

      .al-positions-desk-ledger {
        display: grid;
        gap: 0.25rem;
        align-content: center;
        min-height: 100%;
        border-radius: 1.1rem;
        padding: 1rem;
        background: color-mix(in srgb, var(--brand-primary) 8%, transparent 92%);
      }

      .al-positions-desk-ledger span,
      .al-positions-desk-ledger p {
        color: var(--al-muted);
      }

      .al-positions-desk-ledger strong {
        font-family: var(--al-font-display);
        font-size: clamp(1.4rem, 2.6vw, 2.2rem);
      }

      @media (max-width: 1100px) {
        .al-positions-summary-row,
        .al-positions-priority-grid,
        .al-positions-main-grid,
        .al-positions-filter-row {
          grid-template-columns: 1fr;
        }

        .al-positions-header {
          flex-direction: column;
        }

        .al-positions-header-actions {
          justify-items: start;
        }
      }
    </style>
    """
  end

  defp launch_module do
    :autolaunch
    |> Application.get_env(:positions_live, [])
    |> Keyword.get(:launch_module, Launch)
  end
end
