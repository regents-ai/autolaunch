defmodule AutolaunchWeb.AuctionLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.Launch
  alias AutolaunchWeb.LaunchComponents
  alias AutolaunchWeb.Live.Refreshable
  alias AutolaunchWeb.RegentScenes

  @poll_ms 12_000

  def mount(%{"id" => auction_id}, _session, socket) do
    auction = launch_module().get_auction(auction_id, socket.assigns[:current_human])
    form = default_bid_form(auction)
    quote = maybe_quote(auction, form, socket.assigns[:current_human])
    positions = positions_for_auction(socket.assigns[:current_human], auction_id)

    {:ok,
     socket
     |> Refreshable.schedule(@poll_ms)
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
    {:noreply, Refreshable.wallet_started(socket, message)}
  end

  def handle_event("wallet_tx_registered", %{"message" => message}, socket) do
    {:noreply, Refreshable.wallet_registered(socket, message, &reload_auction/1)}
  end

  def handle_event("wallet_tx_error", %{"message" => message}, socket) do
    {:noreply, Refreshable.wallet_error(socket, message)}
  end

  def handle_event("regent:node_select", %{"meta" => %{"panel" => panel}}, socket) do
    {:noreply, socket |> assign(:detail_focus, panel) |> assign_regent_scene()}
  end

  def handle_event("regent:node_select", _params, socket), do: {:noreply, socket}

  def handle_event("scene-back", _params, socket) do
    {:noreply, socket |> assign(:detail_focus, "detail:bid") |> assign_regent_scene()}
  end

  def handle_event("regent:node_hover", _params, socket), do: {:noreply, socket}
  def handle_event("regent:surface_ready", _params, socket), do: {:noreply, socket}

  def handle_event("regent:surface_error", _params, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "The auction detail surface could not render in this browser session."
     )}
  end

  def handle_info(:refresh, socket) do
    {:noreply, Refreshable.refresh(socket, @poll_ms, &reload_auction/1)}
  end

  def render(assigns) do
    latest_position = List.first(assigns.positions)
    auction_trust = auction_trust(assigns.auction)

    assigns =
      assigns
      |> assign(:latest_position, latest_position)
      |> assign(:trust_summary, auction_trust_summary(auction_trust))
      |> assign(:regent_detail_title, regent_detail_title(assigns.detail_focus))
      |> assign(
        :regent_detail_summary,
        regent_detail_summary(assigns.detail_focus, assigns.quote, latest_position)
      )

    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <%= if @auction do %>
        <section id="auction-detail-hero" class="al-detail-hero al-panel" phx-hook="MissionMotion">
          <div>
            <p class="al-kicker">Auction detail</p>
            <h2>{@auction.agent_name}</h2>
            <p class="al-subcopy">
              Start with the bid composer. The supporting cards below are there to confirm price,
              time, minimum raise, and your current position without competing with the action area.
            </p>

            <div class="al-launch-tags">
              <span class="al-launch-tag">{LaunchComponents.time_left_label(@auction.ends_at)}</span>
              <span class="al-launch-tag">Status {@auction.status}</span>
              <span class="al-launch-tag">Trust {@trust_summary.status}</span>
            </div>
          </div>

          <div class="al-stat-grid">
            <.stat_card title="Clearing price" value={@auction.current_clearing_price} />
            <.stat_card title="Bid volume" value={@auction.total_bid_volume} />
            <.stat_card
              title="Your status"
              value={human_position_status(@latest_position)}
              hint="Active, borderline, inactive, claimable, pending claim, claimed, exited, ending soon, settled"
            />
          </div>
        </section>

        <section class="al-auction-primary-layout">
          <article id="auction-bid-composer" class="al-panel al-card" phx-hook="MissionMotion">
            <div class="al-section-head">
              <div>
                <p class="al-kicker">Bid composer</p>
                <h3>Bid your real budget and your real max price.</h3>
              </div>
              <.status_badge status={@auction.status} />
            </div>

            <div class="al-inline-banner">
              <strong>Simple buyer model.</strong>
              <p>
                Your order is spread across the remaining blocks like a TWAP. It only keeps buying
                while the clearing price stays below your cap, so you never pay above the max price
                you chose.
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
                <h3>If nothing else changes, this is where your bid lands.</h3>
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

            <%= if @positions != [] do %>
              <div class="al-inline-banner al-auction-position-callout">
                <strong>Your latest bid</strong>
                <p>{@latest_position.next_action_label}</p>
              </div>
            <% end %>
          </article>
        </section>

        <section class="al-regent-shell">
          <.surface
            id="auction-detail-regent-surface"
            class="rg-regent-theme-autolaunch al-terrain-surface"
            scene={@regent_scene}
            scene_version={@regent_scene_version}
            selected_target_id={@regent_selected_target_id}
            theme="autolaunch"
            camera_distance={24}
          >
            <:header_strip>
              <div class="al-terrain-strip">
                <div class="al-terrain-strip-copy">
                  <p class="al-kicker">Detail strip</p>
                  <div>
                    <h2>{@auction.agent_name}</h2>
                    <p class="al-subcopy">The detail terrain stays orienting only. Bids, claims, trust checks, and estimator math remain in the readable cards below.</p>
                  </div>
                </div>

                <div class="al-terrain-strip-controls">
                  <.link navigate={~p"/auction-returns"} class="al-ghost">
                    Auction returns
                  </.link>
                  <button
                    :if={@detail_focus != "detail:bid"}
                    type="button"
                    phx-click="scene-back"
                    class="rg-surface-back"
                  >
                    <span class="rg-surface-back-icon" aria-hidden="true">←</span>
                    Back to overview
                  </button>
                  <span class="al-network-badge">{@auction.status}</span>
                  <span class="al-network-badge">{LaunchComponents.time_left_label(@auction.ends_at)}</span>
                  <span class="al-network-badge">Trust {@trust_summary.status}</span>
                </div>
              </div>
            </:header_strip>

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
                      <td>{String.capitalize(@trust_summary.status)}</td>
                    </tr>
                  </tbody>
                </table>
              </.ledger>
            </:ledger>
          </.surface>
        </section>

        <section class="al-detail-layout">
          <article id="auction-minimum-raise-card" class="al-panel al-card" phx-hook="MissionMotion">
            <div class="al-section-head">
              <div>
                <p class="al-kicker">Minimum raise</p>
                <h3>How close the auction is to graduating</h3>
              </div>
              <.link navigate={~p"/auction-returns"} class="al-ghost">Auction returns</.link>
            </div>

            <div class="al-stat-grid">
              <.stat_card
                title="Raised now"
                value={auction_value(@auction, :currency_raised, @auction.total_bid_volume)}
              />
              <.stat_card
                title="Minimum needed"
                value={auction_value(@auction, :required_currency_raised, "Unavailable")}
              />
              <.stat_card
                title="Progress"
                value={
                  if(is_number(auction_value(@auction, :minimum_raise_progress_percent)),
                    do: "#{auction_value(@auction, :minimum_raise_progress_percent)}%",
                    else: "Unavailable"
                  )
                }
              />
              <.stat_card
                title="Simple pace estimate"
                value={auction_value(@auction, :projected_final_currency_raised, "Waiting for more time")}
                hint="Estimate only, not a promise"
              />
            </div>

            <p class="al-inline-note">
              {minimum_raise_copy(@auction)}
            </p>
          </article>

          <article id="auction-position-card" class="al-panel al-card" phx-hook="MissionMotion">
            <div class="al-section-head">
              <div>
                <p class="al-kicker">Your position</p>
                <h3>What you can do from here</h3>
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
                      :if={return_action(position)}
                      id={"auction-return-#{position.bid_id}"}
                      class="al-submit"
                      tx_request={return_action(position).tx_request}
                      register_endpoint={~p"/api/bids/#{position.bid_id}/return-usdc"}
                      pending_message="Return transaction sent. Waiting for confirmation."
                      success_message="USDC return registered."
                    >
                      Return USDC
                    </.wallet_tx_button>
                    <.wallet_tx_button
                      :if={tx_action(position, :exit) && is_nil(return_action(position))}
                      id={"auction-exit-#{position.bid_id}"}
                      class="al-ghost"
                      tx_request={tx_action(position, :exit).tx_request}
                      register_endpoint={~p"/api/bids/#{position.bid_id}/exit"}
                      pending_message="Exit transaction sent. Waiting for confirmation."
                      success_message="Bid exit registered."
                    >
                      Exit bid
                    </.wallet_tx_button>

                    <.wallet_tx_button
                      :if={tx_action(position, :claim)}
                      id={"auction-claim-#{position.bid_id}"}
                      class="al-submit"
                      tx_request={tx_action(position, :claim).tx_request}
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
        </section>

        <section class="al-detail-layout">
          <details id="auction-trust-card" class="al-panel al-disclosure" phx-hook="MissionMotion">
            <summary class="al-disclosure-summary">
              <div>
                <p class="al-kicker">Creator completion</p>
                <h3>Identity and trust status</h3>
              </div>
              <span class="al-network-badge">Secondary</span>
            </summary>

            <div class="al-note-grid">
              <article class="al-note-card">
                <span>ENS link</span>
                <strong>{@trust_summary.ens.title}</strong>
                <p>{@trust_summary.ens.body}</p>
              </article>

              <article class="al-note-card">
                <span>Trust record</span>
                <strong>{@trust_summary.world.title}</strong>
                <p>{@trust_summary.world.body}</p>
              </article>
            </div>
          </details>

          <details id="auction-model-card" class="al-panel al-disclosure" phx-hook="MissionMotion">
            <summary class="al-disclosure-summary">
              <div>
                <p class="al-kicker">Auction model</p>
                <h3>Why the auction behaves this way</h3>
              </div>
              <span class="al-network-badge">Secondary</span>
            </summary>

            <ul class="al-compact-list">
              <li>Bid early with your real budget and your real max price instead of waiting for a last-second entry.</li>
              <li>Your max price protects you from overpaying, and everyone in the same block gets the same clearing price.</li>
              <li>With sane auction timing, there is far less room for sniping, bundling, sandwiching, or other speed advantages.</li>
            </ul>
          </details>
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

  defp auction_trust(nil), do: %{}

  defp auction_trust(%{trust: trust}) when is_map(trust), do: trust

  defp auction_trust(_auction), do: %{}

  defp auction_trust_summary(%{
         ens: %{
           connected: ens_connected,
           name: ens_name
         },
         world: %{
           connected: world_connected,
           human_id: human_id,
           launch_count: launch_count
         }
       }) do
    %{
      status: if(world_connected, do: "checked", else: "pending"),
      ens: %{
        title: if(ens_connected, do: "Linked", else: "Needs link"),
        body:
          if(ens_connected,
            do: "Creator identity name: #{ens_name}",
            else: "The creator identity still needs an ENS name attached."
          )
      },
      world: %{
        title: if(world_connected, do: "Checked", else: "Needs check"),
        body:
          if(world_connected,
            do: "Human ID #{human_id} has launched #{launch_count} tokens through autolaunch.",
            else: "A trust check still needs to be completed for this token."
          )
      }
    }
  end

  defp auction_trust_summary(_trust) do
    %{
      status: "pending",
      ens: %{
        title: "Needs link",
        body: "The creator identity still needs an ENS name attached."
      },
      world: %{
        title: "Needs check",
        body: "A trust check still needs to be completed for this token."
      }
    }
  end

  defp reload_auction(socket) do
    auction = launch_module().get_auction(socket.assigns.auction_id, socket.assigns.current_human)
    positions = positions_for_auction(socket.assigns.current_human, socket.assigns.auction_id)

    socket
    |> assign(:auction, auction)
    |> assign(:positions, positions)
    |> assign(:quote, maybe_quote(auction, socket.assigns.bid_form, socket.assigns.current_human))
    |> assign_regent_scene()
  end

  defp minimum_raise_copy(auction) do
    case auction_value(auction, :auction_outcome) do
      "failed_minimum" ->
        "This auction ended below the minimum raise. Buyers can return their USDC from the wallet actions on this page or from Positions."

      _ ->
        minimum_raise_copy_by_state(auction)
    end
  end

  defp minimum_raise_copy_by_state(auction) do
    if auction_value(auction, :minimum_raise_met) == true do
      "The auction has already met its minimum raise, so it can graduate if bidding holds through the end."
    else
      "Simple pace assumes the current bidding rate continues for the rest of the three-day auction. It is there to orient visitors, not to promise the final outcome."
    end
  end

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

  defp auction_value(auction, key, default \\ nil)
  defp auction_value(nil, _key, default), do: default

  defp auction_value(auction, key, default) when is_map(auction) do
    Map.get(auction, key, default)
  end

  defp return_action(position) when is_map(position) do
    Map.get(position, :return_action)
  end

  defp tx_action(position, action) when is_map(position) do
    position
    |> Map.get(:tx_actions, %{})
    |> Map.get(action)
  end

  defp assign_regent_scene(socket) do
    latest_position = List.first(socket.assigns.positions || [])
    next_version = (socket.assigns[:regent_scene_version] || 0) + 1

    scene =
      RegentScenes.auction_detail(
        socket.assigns.auction,
        latest_position,
        socket.assigns.detail_focus
      )

    socket
    |> assign(:regent_scene_version, next_version)
    |> assign(:regent_scene, Map.put(scene, "sceneVersion", next_version))
    |> assign(:regent_selected_target_id, socket.assigns.detail_focus)
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
    "Set the budget and max price here, then use the live quote below to see how that order would TWAP across the remaining blocks."
  end

  defp launch_module do
    :autolaunch
    |> Application.get_env(:auction_live, [])
    |> Keyword.get(:launch_module, Launch)
  end
end
