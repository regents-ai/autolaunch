defmodule AutolaunchWeb.AuctionLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.Launch
  alias AutolaunchWeb.LaunchComponents
  alias AutolaunchWeb.RegentScenes

  @poll_ms 12_000

  def mount(%{"id" => auction_id}, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @poll_ms)

    auction = launch_module().get_auction(auction_id, socket.assigns[:current_human])
    form = default_bid_form(auction)
    quote = maybe_quote(auction, form, socket.assigns[:current_human])
    positions = positions_for_auction(socket.assigns[:current_human], auction_id)

    {:ok,
     socket
     |> assign(:page_title, "Auction Detail")
     |> assign(:active_view, "auctions")
     |> assign(:auction_id, auction_id)
     |> assign(:auction, auction)
     |> assign(:bid_form, form)
     |> assign(:quote, quote)
     |> assign(:positions, positions)
     |> assign(:detail_focus, "detail:bid")
     |> assign_regent_scene()}
  end

  def handle_event("quote_changed", %{"bid" => attrs}, socket) do
    form = Map.merge(socket.assigns.bid_form, attrs)

    {:noreply,
     socket
     |> assign(:bid_form, form)
     |> assign(:quote, maybe_quote(socket.assigns.auction, form, socket.assigns.current_human))
     |> assign_regent_scene()}
  end

  def handle_event("apply_preset", %{"preset" => preset}, socket) do
    form = preset_form(socket.assigns.auction, socket.assigns.bid_form, preset)

    {:noreply,
     socket
     |> assign(:bid_form, form)
     |> assign(:quote, maybe_quote(socket.assigns.auction, form, socket.assigns.current_human))
     |> assign_regent_scene()}
  end

  def handle_event("wallet_tx_started", %{"message" => message}, socket) do
    {:noreply, put_flash(socket, :info, message)}
  end

  def handle_event("wallet_tx_registered", %{"message" => message}, socket) do
    auction = launch_module().get_auction(socket.assigns.auction_id, socket.assigns.current_human)
    positions = positions_for_auction(socket.assigns.current_human, socket.assigns.auction_id)

    {:noreply,
     socket
     |> put_flash(:info, message)
     |> assign(:auction, auction)
     |> assign(:positions, positions)
      |> assign(
        :quote,
        maybe_quote(auction, socket.assigns.bid_form, socket.assigns.current_human)
      )
     |> assign_regent_scene()}
  end

  def handle_event("wallet_tx_error", %{"message" => message}, socket) do
    {:noreply, put_flash(socket, :error, message)}
  end

  def handle_event("regent:node_select", %{"meta" => %{"panel" => panel}}, socket) do
    {:noreply, socket |> assign(:detail_focus, panel) |> assign_regent_scene()}
  end

  def handle_event("regent:node_select", _params, socket), do: {:noreply, socket}

  def handle_event("regent:node_hover", _params, socket), do: {:noreply, socket}
  def handle_event("regent:surface_ready", _params, socket), do: {:noreply, socket}

  def handle_event("regent:surface_error", _params, socket) do
    {:noreply, put_flash(socket, :error, "The auction detail surface could not render in this browser session.")}
  end

  def handle_info(:refresh, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @poll_ms)

    auction = launch_module().get_auction(socket.assigns.auction_id, socket.assigns.current_human)
    positions = positions_for_auction(socket.assigns.current_human, socket.assigns.auction_id)

    {:noreply,
     socket
     |> assign(:auction, auction)
     |> assign(:positions, positions)
      |> assign(
        :quote,
        maybe_quote(auction, socket.assigns.bid_form, socket.assigns.current_human)
      )
     |> assign_regent_scene()}
  end

  def render(assigns) do
    latest_position = List.first(assigns.positions)

    assigns =
      assigns
      |> assign(:latest_position, latest_position)
      |> assign(:regent_detail_title, regent_detail_title(assigns.detail_focus))
      |> assign(:regent_detail_summary, regent_detail_summary(assigns.detail_focus, assigns.quote, latest_position))

    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <%= if @auction do %>
        <section class="al-regent-shell">
          <.surface
            id="auction-detail-regent-surface"
            class="rg-regent-theme-autolaunch"
            scene={@regent_scene}
            scene_version={@regent_scene_version}
            selected_node_id={@regent_selected_node_id}
            theme="autolaunch"
            camera_distance={24}
          >
            <:chamber>
              <.chamber
                id="auction-detail-regent-chamber"
                title={@regent_detail_title}
                subtitle={@auction.agent_name}
                summary={@regent_detail_summary}
              >
                <div class="al-launch-tags" aria-label="Auction detail summary">
                  <span class="al-launch-tag">Clearing price: {@auction.current_clearing_price}</span>
                  <span class="al-launch-tag">Bid volume: {@auction.total_bid_volume}</span>
                  <span class="al-launch-tag">Your status: {human_position_status(@latest_position)}</span>
                </div>
              </.chamber>
            </:chamber>

            <:ledger>
              <.ledger
                id="auction-detail-regent-ledger"
                title="Live state"
                subtitle="Use the regular cards below to bid, claim, and inspect the estimator."
              >
                <table class="rg-table">
                  <tbody>
                    <tr>
                      <th scope="row">Status</th>
                      <td>{@auction.status}</td>
                    </tr>
                    <tr>
                      <th scope="row">Time remaining</th>
                      <td>{LaunchComponents.time_left_label(@auction.ends_at)}</td>
                    </tr>
                    <tr>
                      <th scope="row">Trust</th>
                      <td>{if @auction.world_registered, do: "Checked", else: "Pending"}</td>
                    </tr>
                  </tbody>
                </table>
              </.ledger>
            </:ledger>
          </.surface>
        </section>

        <section id="auction-detail-hero" class="al-detail-hero al-panel" phx-hook="MissionMotion">
          <div>
            <p class="al-kicker">Auction detail</p>
            <h2>{@auction.agent_name}</h2>
            <p class="al-subcopy">
              This page is built around the estimator because CCA behavior is easier to trust with a live quote.
            </p>
          </div>

          <div class="al-stat-grid">
            <.stat_card title="Clearing price" value={@auction.current_clearing_price} />
            <.stat_card title="Bid volume" value={@auction.total_bid_volume} />
            <.stat_card title="Time remaining" value={LaunchComponents.time_left_label(@auction.ends_at)} />
            <.stat_card
              title="Your status"
              value={human_position_status(@latest_position)}
              hint="Active, borderline, inactive, claimable, pending claim, claimed, exited, ending soon, settled"
            />
            <.stat_card
              title="ENS"
              value={if @auction.ens_attached, do: @auction.ens_name || "Linked", else: "Pending"}
              hint="Creator identity"
            />
            <.stat_card
              title="Trust"
              value={if @auction.world_registered, do: "Checked", else: "Pending"}
              hint="Creator trust record"
            />
          </div>
        </section>

        <section class="al-detail-layout">
          <article id="auction-trust-card" class="al-panel al-card" phx-hook="MissionMotion">
            <div class="al-section-head">
              <div>
                <p class="al-kicker">Creator completion</p>
                <h3>Identity and trust status</h3>
              </div>
            </div>

            <div class="al-note-grid">
              <article class="al-note-card">
                <span>ENS link</span>
                <strong>{if @auction.ens_attached, do: "Linked", else: "Needs link"}</strong>
                <p>
                  {if @auction.ens_attached,
                    do: "Creator identity name: #{@auction.ens_name}",
                    else: "The creator identity still needs an ENS name attached."}
                </p>
              </article>

              <article class="al-note-card">
                <span>Trust record</span>
                <strong>{if @auction.world_registered, do: "Checked", else: "Needs check"}</strong>
                <p>
                  {if @auction.world_registered,
                    do: "Human ID #{@auction.world_human_id} has launched #{@auction.world_launch_count} tokens through autolaunch.",
                    else: "A trust check still needs to be completed for this token."}
                </p>
              </article>
            </div>
          </article>

          <article id="auction-bid-composer" class="al-panel al-card" phx-hook="MissionMotion">
            <div class="al-section-head">
              <div>
                <p class="al-kicker">Bid composer</p>
                <h3>Choose amount and max price</h3>
              </div>
              <.status_badge status={@auction.status} />
            </div>

            <div class="al-inline-banner">
              <strong>Wallet-driven bid path.</strong>
              <p>
                The quote is computed on the server, but the bid itself is sent straight to the CCA contract from your wallet.
              </p>
            </div>

            <form phx-change="quote_changed" class="al-form">
              <div class="al-field-grid">
                <label>
                  <span>Amount</span>
                  <input type="text" name="bid[amount]" value={@bid_form["amount"]} />
                </label>
                <label>
                  <span>Max price</span>
                  <input type="text" name="bid[max_price]" value={@bid_form["max_price"]} />
                </label>
              </div>
            </form>

            <div class="al-pill-row">
              <button type="button" class="al-filter" phx-click="apply_preset" phx-value-preset="starter">Starter bid</button>
              <button type="button" class="al-filter" phx-click="apply_preset" phx-value-preset="stay_active">Stay-active bid</button>
              <button type="button" class="al-filter" phx-click="apply_preset" phx-value-preset="aggressive">Aggressive</button>
            </div>

            <div class="al-action-row">
              <.wallet_tx_button
                :if={@quote && @quote.tx_request}
                id={"submit-bid-#{@auction_id}"}
                class="al-submit"
                tx_request={@quote.tx_request}
                register_endpoint={~p"/api/auctions/#{@auction_id}/bids"}
                register_body={%{
                  "amount" => @quote.amount,
                  "max_price" => @quote.max_price,
                  "current_clearing_price" => @quote.current_clearing_price,
                  "projected_clearing_price" => @quote.projected_clearing_price,
                  "estimated_tokens_if_end_now" => @quote.estimated_tokens_if_end_now,
                  "estimated_tokens_if_no_other_bids_change" =>
                    @quote.estimated_tokens_if_no_other_bids_change,
                  "inactive_above_price" => @quote.inactive_above_price,
                  "status_band" => @quote.status_band
                }}
                pending_message="Bid transaction sent. Waiting for chain confirmation."
                success_message="Bid registered from the confirmed onchain transaction."
              >
                Submit bid from wallet
              </.wallet_tx_button>
              <span :if={is_nil(@current_human)} class="al-inline-note">
                Privy session required before the wallet transaction can be registered.
              </span>
            </div>
          </article>

          <article id="auction-estimator-card" class="al-panel al-card" phx-hook="MissionMotion">
            <div class="al-section-head">
              <div>
                <p class="al-kicker">Live estimator</p>
                <h3>What changes if nothing else moves?</h3>
              </div>
            </div>

            <%= if @quote do %>
              <div class="al-stat-grid">
                <.stat_card
                  title="Active now?"
                  value={if @quote.would_be_active_now, do: "Yes", else: "No"}
                  hint={@quote.status_band}
                />
                <.stat_card
                  title="If auction ended now"
                  value={@quote.estimated_tokens_if_end_now}
                />
                <.stat_card
                  title="If no bids change"
                  value={@quote.estimated_tokens_if_no_other_bids_change}
                />
                <.stat_card
                  title="Inactive above"
                  value={@quote.inactive_above_price}
                />
              </div>

              <ul class="al-compact-list">
                <li>
                  Current clearing price: <strong>{@quote.current_clearing_price}</strong>
                </li>
                <li>
                  Status band: <strong>{String.capitalize(@quote.status_band)}</strong>
                </li>
                <li>
                  Time remaining: <strong>{Integer.to_string(@quote.time_remaining_seconds)} seconds</strong>
                </li>
                <li :for={warning <- @quote.warnings}>{warning}</li>
              </ul>
            <% else %>
              <p class="al-inline-note">Enter a valid amount and max price to calculate the estimator.</p>
            <% end %>
          </article>
        </section>

        <section class="al-detail-layout">
          <article id="auction-position-card" class="al-panel al-card" phx-hook="MissionMotion">
            <div class="al-section-head">
              <div>
                <p class="al-kicker">Your position</p>
                <h3>Current bid state</h3>
              </div>
            </div>

            <%= if @positions == [] do %>
              <p class="al-inline-note">
                No bids recorded for this auction yet. The first quote tells you whether you would be active right now.
              </p>
            <% else %>
              <div class="al-position-list">
                <article :for={position <- @positions} class="al-position-card">
                  <div class="al-agent-card-head">
                    <div>
                      <strong>{position.amount}</strong>
                      <p>{position.max_price} max price</p>
                    </div>
                    <.status_badge status={position.status} />
                  </div>

                  <div class="al-stat-grid">
                    <.stat_card title="Tokens filled" value={position.tokens_filled} />
                    <.stat_card title="If end now" value={position.estimated_tokens_if_end_now} />
                    <.stat_card title="Inactive above" value={position.inactive_above_price} />
                  </div>

              <p class="al-inline-note">{position.next_action_label}</p>

              <div class="al-action-row">
                    <.wallet_tx_button
                      :if={position.tx_actions.exit}
                      id={"auction-exit-#{position.bid_id}"}
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
                      id={"auction-claim-#{position.bid_id}"}
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
              </div>
            <% end %>
          </article>

          <article id="auction-model-card" class="al-panel al-card" phx-hook="MissionMotion">
            <div class="al-section-head">
              <div>
                <p class="al-kicker">How this works</p>
                <h3>Keep the CCA model practical</h3>
              </div>
            </div>

            <ul class="al-compact-list">
              <li>Active bids receive tokens at the current clearing price.</li>
              <li>Inactive bids stop participating until the clearing price moves back below the bid cap.</li>
              <li>The estimator is the operational summary: active now, tokens now, tokens if nothing changes, and your inactive threshold.</li>
            </ul>
          </article>
        </section>
      <% else %>
        <.empty_state
          title="Auction not found."
          body="The requested auction could not be loaded from the local launch view."
          action_label="Back to auctions"
          action_href={~p"/auctions"}
        />
      <% end %>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end

  defp default_bid_form(nil), do: %{"amount" => "250.0", "max_price" => "0.0050"}

  defp default_bid_form(auction) do
    %{
      "amount" => "250.0",
      "max_price" => decimal_plus(auction.current_clearing_price, "0.0008")
    }
  end

  defp maybe_quote(nil, _form, _human), do: nil

  defp maybe_quote(auction, form, current_human) do
    case launch_module().quote_bid(auction.id, form, current_human) do
      {:ok, quote} -> quote
      _ -> nil
    end
  end

  defp positions_for_auction(nil, _auction_id), do: []

  defp positions_for_auction(current_human, auction_id) do
    current_human
    |> launch_module().list_positions()
    |> Enum.filter(&(&1.auction_id == auction_id))
  end

  defp preset_form(nil, form, _preset), do: form

  defp preset_form(auction, form, "starter") do
    Map.put(form, "max_price", decimal_plus(auction.current_clearing_price, "0.0005"))
  end

  defp preset_form(auction, form, "stay_active") do
    Map.put(form, "max_price", decimal_plus(auction.current_clearing_price, "0.0009"))
  end

  defp preset_form(auction, form, "aggressive") do
    form
    |> Map.put("amount", "500.0")
    |> Map.put("max_price", decimal_plus(auction.current_clearing_price, "0.0014"))
  end

  defp preset_form(_auction, form, _preset), do: form

  defp decimal_plus(left, right) do
    with {lhs, ""} <- Decimal.parse(left),
         {rhs, ""} <- Decimal.parse(right) do
      lhs
      |> Decimal.add(rhs)
      |> Decimal.round(4)
      |> Decimal.to_string(:normal)
    else
      _ -> left
    end
  end

  defp human_position_status(nil), do: "No bid"
  defp human_position_status(position), do: String.capitalize(position.status)

  defp assign_regent_scene(socket) do
    latest_position = List.first(socket.assigns.positions || [])
    next_version = (socket.assigns[:regent_scene_version] || 0) + 1
    scene = RegentScenes.auction_detail(socket.assigns.auction, latest_position, socket.assigns.detail_focus)

    socket
    |> assign(:regent_scene_version, next_version)
    |> assign(:regent_scene, Map.put(scene, "sceneVersion", next_version))
    |> assign(:regent_selected_node_id, socket.assigns.detail_focus)
  end

  defp regent_detail_title("detail:estimate"), do: "Live estimator"
  defp regent_detail_title("detail:trust"), do: "Trust and identity"
  defp regent_detail_title("detail:claim"), do: "Position state"
  defp regent_detail_title(_detail_focus), do: "Bid composer"

  defp regent_detail_summary("detail:estimate", quote, _latest_position) when is_map(quote) do
    "If nothing else moved right now, you would receive #{quote.estimated_tokens_if_end_now} tokens, and the bid would go inactive above #{quote.inactive_above_price}."
  end

  defp regent_detail_summary("detail:trust", _quote, _latest_position) do
    "This view keeps ENS and trust status visible so the market context stays legible without turning the bidding controls into a maze."
  end

  defp regent_detail_summary("detail:claim", _quote, latest_position) do
    "Current position state: #{human_position_status(latest_position)}. Claiming and exits stay as explicit wallet actions in the human-readable cards below."
  end

  defp regent_detail_summary(_detail_focus, _quote, _latest_position) do
    "Set the budget and max price here, then use the live quote below to decide whether the bid should stay active."
  end

  defp launch_module do
    :autolaunch
    |> Application.get_env(:auction_live, [])
    |> Keyword.get(:launch_module, Launch)
  end
end
