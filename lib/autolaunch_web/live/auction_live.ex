defmodule AutolaunchWeb.AuctionLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.Launch
  alias AutolaunchWeb.LaunchComponents
  alias AutolaunchWeb.Live.Refreshable
  alias Decimal, as: D

  @poll_ms 12_000
  @auctions_css_path Path.expand("../../../assets/css/auctions-live.css", __DIR__)
  @external_resource @auctions_css_path
  @auctions_css File.read!(@auctions_css_path)

  def mount(%{"id" => auction_id}, _session, socket) do
    auction = launch_module().get_auction(auction_id, socket.assigns[:current_human])
    form = default_bid_form(auction)
    quote = maybe_quote(auction, form, socket.assigns[:current_human])
    positions = positions_for_auction(socket.assigns[:current_human], auction_id)

    {:ok,
     socket
     |> Refreshable.schedule(@poll_ms)
     |> Refreshable.subscribe([:market, :positions, :system])
     |> assign(:page_title, "Auction Detail")
     |> assign(:active_view, "auctions")
     |> assign(:auction_id, auction_id)
     |> assign(:auction, auction)
     |> assign(:bid_form, form)
     |> assign(:quote, quote)
     |> assign(:positions, positions)}
  end

  def handle_event("quote_changed", %{"bid" => attrs}, socket) do
    form = Map.merge(socket.assigns.bid_form, attrs)

    {:noreply,
     socket
     |> assign(:bid_form, form)
     |> assign(:quote, maybe_quote(socket.assigns.auction, form, socket.assigns.current_human))}
  end

  def handle_event("apply_preset", %{"preset" => preset}, socket) do
    form = preset_form(socket.assigns.auction, socket.assigns.bid_form, preset)

    {:noreply,
     socket
     |> assign(:bid_form, form)
     |> assign(:quote, maybe_quote(socket.assigns.auction, form, socket.assigns.current_human))}
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

  def handle_info(:refresh, socket) do
    {:noreply, Refreshable.refresh(socket, @poll_ms, &reload_auction/1)}
  end

  def handle_info({:autolaunch_live_update, :changed}, socket) do
    {:noreply, reload_auction(socket)}
  end

  def render(assigns) do
    latest_position = List.first(assigns.positions)
    planner = bid_planner(assigns.quote, assigns.bid_form)
    settlement = settlement_panel(assigns.auction, latest_position)

    assigns =
      assigns
      |> assign(:latest_position, latest_position)
      |> assign(:planner, planner)
      |> assign(:settlement, settlement)
      |> assign(:trust_summary, auction_trust_summary(auction_trust(assigns.auction)))

    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <style id="auction-detail-css">
        <%= raw(route_css()) %>
      </style>

      <%= if @auction do %>
        <div class="al-auction-detail-route">
          <section
            id="auction-detail-page-head"
            class="al-auction-detail-page-head"
            phx-hook="MissionMotion"
          >
            <div class="breadcrumbs text-sm">
              <ul>
                <li><.link navigate={~p"/auctions"}>Auctions</.link></li>
                <li>Detail</li>
              </ul>
            </div>

            <div class="al-auction-detail-title-row">
              <div>
                <p class="al-kicker">Auction detail</p>
                <h1>{@auction.agent_name}</h1>
              </div>

              <div class="al-auction-detail-page-actions">
                <.link navigate={~p"/auction-returns"} class="btn btn-ghost btn-sm">
                  Auction returns
                </.link>
                <.link
                  :if={is_binary(auction_value(@auction, :subject_url))}
                  navigate={auction_value(@auction, :subject_url)}
                  class="btn btn-outline btn-sm"
                >
                  Open token page
                </.link>
                <a
                  :if={is_binary(auction_value(@auction, :uniswap_url))}
                  href={auction_value(@auction, :uniswap_url)}
                  class="btn btn-outline btn-sm"
                  target="_blank"
                  rel="noreferrer"
                >
                  Uniswap
                </a>
              </div>
            </div>
          </section>

          <section
            id="auction-detail-hero"
            class="al-auction-detail-hero al-panel"
            phx-hook="MissionMotion"
          >
            <div class="al-auction-detail-hero-main">
              <div class="al-auction-detail-brand-mark">{agent_monogram(@auction.agent_name)}</div>

              <div class="al-auction-detail-hero-copy">
                <div class="al-auction-detail-hero-heading">
                  <h2>{@auction.agent_name}</h2>
                  <span class={["al-status-badge", status_tone(@auction)]}>
                    {detail_status_label(@auction)}
                  </span>
                </div>

                <p class="al-auction-detail-hero-meta">
                  {auction_symbol(@auction)} <span>•</span> {network_label(@auction)} <span>•</span>
                  {@trust_summary.status |> String.capitalize()}
                </p>

                <p class="al-subcopy">{auction_description(@auction)}</p>

                <div class="al-auction-detail-hero-badges">
                  <span :if={@trust_summary.ens.title == "Linked"} class="badge badge-outline">
                    ENS linked
                  </span>
                  <span :if={@trust_summary.world.title == "Checked"} class="badge badge-outline">
                    Trust checked
                  </span>
                  <span :if={truthy?(auction_value(@auction, :returns_enabled))} class="badge badge-outline">
                    Returns ready if needed
                  </span>
                </div>
              </div>
            </div>

            <div class="al-auction-detail-hero-stats">
              <article>
                <span>Auction status</span>
                <strong>{detail_status_value(@auction)}</strong>
                <p>{LaunchComponents.time_left_label(@auction.ends_at)}</p>
              </article>
              <article>
                <span>Clearing price</span>
                <strong>{auction_value(@auction, :current_clearing_price, "Unavailable")}</strong>
                <p>{price_source_label(@auction)}</p>
              </article>
              <article>
                <span>Bid volume</span>
                <strong>{auction_value(@auction, :total_bid_volume, "Unavailable")}</strong>
                <p>{bidder_copy(@auction)}</p>
              </article>
            </div>
          </section>

          <section
            id="auction-detail-primary"
            class="al-auction-detail-primary"
            phx-hook="MissionMotion"
          >
            <article class="al-auction-detail-composer">
              <div class="al-auction-detail-card-head">
                <div>
                  <p class="al-kicker">Bid composer</p>
                  <h3>Plan your spend before you sign.</h3>
                </div>
                <span class="badge badge-outline">Bid planner</span>
              </div>

              <p class="al-auction-detail-dark-copy">
                Enter the most you want to spend and the exposure you want. The estimate shows how
                close this bid gets before you send anything from your wallet.
              </p>

              <form phx-change="quote_changed" class="al-auction-detail-form">
                <label class="al-auction-detail-field">
                  <span>Max spend</span>
                  <div class="al-auction-detail-input-shell">
                    <input type="text" name="bid[amount]" value={@bid_form["amount"]} />
                    <span>USDC</span>
                  </div>
                </label>

                <label class="al-auction-detail-field">
                  <span>Max price</span>
                  <div class="al-auction-detail-input-shell">
                    <input type="text" name="bid[max_price]" value={@bid_form["max_price"]} />
                    <span>USD</span>
                  </div>
                </label>

                <label class="al-auction-detail-field">
                  <span>Desired exposure</span>
                  <div class="al-auction-detail-input-shell">
                    <input
                      type="text"
                      name="bid[desired_exposure]"
                      value={@bid_form["desired_exposure"]}
                    />
                    <span>tokens</span>
                  </div>
                </label>
              </form>

              <div class="al-auction-detail-plan-card">
                <div>
                  <span>Expected outcome</span>
                  <strong>{@planner.title}</strong>
                  <p>{@planner.body}</p>
                </div>
                <div>
                  <span>Target check</span>
                  <strong>{@planner.target_title}</strong>
                  <p>{@planner.target_body}</p>
                </div>
              </div>

              <div class="al-auction-detail-presets">
                <button type="button" class="al-auction-detail-preset is-active" phx-click="apply_preset" phx-value-preset="starter">
                  <strong>Starter bid</strong>
                  <span>Conservative entry</span>
                </button>
                <button type="button" class="al-auction-detail-preset" phx-click="apply_preset" phx-value-preset="stay_active">
                  <strong>Stay-active bid</strong>
                  <span>Higher clearing odds</span>
                </button>
                <button type="button" class="al-auction-detail-preset" phx-click="apply_preset" phx-value-preset="aggressive">
                  <strong>Aggressive</strong>
                  <span>Maximum allocation</span>
                </button>
              </div>

              <div class="al-auction-detail-primary-action">
                <.wallet_tx_button
                  :if={@quote && @quote.tx_request}
                  id={"submit-bid-#{@auction_id}"}
                  class="al-submit"
                  tx_request={@quote.tx_request}
                  register_endpoint={~p"/v1/app/auctions/#{@auction_id}/bids"}
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

                <p :if={is_nil(@current_human)} class="al-auction-detail-wallet-note">
                  Sign in first so your bid can be recorded after it confirms.
                </p>
              </div>
            </article>

            <article class="al-auction-detail-estimator al-panel">
              <div class="al-auction-detail-card-head">
                <div>
                  <p class="al-kicker">Live estimator</p>
                  <h3>If nothing else changes, this is where your bid lands.</h3>
                </div>
                <span class="al-auction-detail-timestamp">{metrics_updated_copy(@auction)}</span>
              </div>

              <%= if @quote do %>
                <div class="al-auction-detail-estimator-grid">
                  <article>
                    <span>Active now?</span>
                    <strong>{if @quote.would_be_active_now, do: "You are active", else: "Below the line"}</strong>
                    <p>{String.capitalize(@quote.status_band)}</p>
                  </article>
                  <article>
                    <span>If auction ended now</span>
                    <strong>{@quote.current_clearing_price}</strong>
                    <p>~{@quote.estimated_tokens_if_end_now} tokens</p>
                  </article>
                  <article>
                    <span>If no bids change</span>
                    <strong>{@quote.projected_clearing_price}</strong>
                    <p>~{@quote.estimated_tokens_if_no_other_bids_change} tokens</p>
                  </article>
                </div>

                <div class="al-auction-detail-estimator-foot">
                  <span>Inactive above</span>
                  <strong>{@quote.inactive_above_price}</strong>
                </div>

                <ul :if={@quote.warnings != []} class="al-compact-list">
                  <li :for={warning <- @quote.warnings}>{warning}</li>
                </ul>
              <% else %>
                <p class="al-inline-note">Enter both fields to calculate the live estimate.</p>
              <% end %>
            </article>
          </section>

          <section
            id="auction-detail-strip"
            class="al-auction-detail-strip"
            phx-hook="MissionMotion"
          >
            <article>
              <span>Your latest bid</span>
              <strong>{latest_bid_value(@latest_position)}</strong>
              <p>{latest_bid_copy(@latest_position)}</p>
            </article>
            <article>
              <span>Auction returns</span>
              <strong>{returns_strip_title(@auction, @latest_position)}</strong>
              <p>{returns_strip_copy(@auction, @latest_position)}</p>
            </article>
            <article>
              <span>Clearing price</span>
              <strong>{auction_value(@auction, :current_clearing_price, "Unavailable")}</strong>
              <p>{price_source_label(@auction)}</p>
            </article>
            <article>
              <span>Bid volume</span>
              <strong>{auction_value(@auction, :total_bid_volume, "Unavailable")}</strong>
              <p>{bidder_copy(@auction)}</p>
            </article>
            <article>
              <span>Your status</span>
              <strong>{human_position_status(@latest_position)}</strong>
              <p>{status_strip_copy(@latest_position)}</p>
            </article>
          </section>

          <section
            id="auction-detail-lower"
            class="al-auction-detail-lower"
            phx-hook="MissionMotion"
          >
            <article class="al-panel al-auction-detail-info-card">
              <div class="al-auction-detail-card-head">
                <div>
                  <p class="al-kicker">Auction information</p>
                  <h3>Key dates and market state</h3>
                </div>
              </div>

              <table class="al-auction-detail-info-table">
                <tbody>
                  <tr>
                    <th scope="row">Auction type</th>
                    <td>Continuous clearing auction</td>
                  </tr>
                  <tr>
                    <th scope="row">Start time</th>
                    <td>{format_timestamp(auction_value(@auction, :started_at))}</td>
                  </tr>
                  <tr>
                    <th scope="row">End time</th>
                    <td>{format_timestamp(@auction.ends_at)}</td>
                  </tr>
                  <tr>
                    <th scope="row">Network</th>
                    <td>{network_label(@auction)}</td>
                  </tr>
                  <tr>
                    <th scope="row">Minimum needed</th>
                    <td>{auction_value(@auction, :required_currency_raised, "Unavailable")}</td>
                  </tr>
                  <tr>
                    <th scope="row">Raised now</th>
                    <td>{auction_value(@auction, :currency_raised, auction_value(@auction, :total_bid_volume, "Unavailable"))}</td>
                  </tr>
                </tbody>
              </table>
            </article>

            <article class="al-panel al-auction-detail-curve-card">
              <div class="al-auction-detail-card-head">
                <div>
                  <p class="al-kicker">Price path</p>
                  <h3>Current and projected market pace</h3>
                </div>
              </div>

              <%= if price_curve_path(@auction, @quote) do %>
                <div class="al-auction-detail-curve-shell">
                  <svg viewBox="0 0 360 180" class="al-auction-detail-curve" aria-hidden="true">
                    <path d="M 16 18 L 16 152 L 344 152" class="al-auction-detail-axis" />
                    <path d={price_curve_path(@auction, @quote)} class="al-auction-detail-line" />
                    <circle cx="316" cy={price_curve_current_y(@auction, @quote)} r="5" class="al-auction-detail-line-dot" />
                  </svg>
                  <div class="al-auction-detail-curve-tag">
                    {auction_value(@auction, :current_clearing_price, "Unavailable")}
                  </div>
                </div>
              <% else %>
                <p class="al-inline-note">Price path appears once the current clearing price is available.</p>
              <% end %>

              <div class="al-auction-detail-curve-meta">
                <div>
                  <span>Current</span>
                  <strong>{auction_value(@auction, :current_clearing_price, "Unavailable")}</strong>
                </div>
                <div>
                  <span>Projected</span>
                  <strong>{quote_value(@quote, :projected_clearing_price, "Waiting for live quote")}</strong>
                </div>
              </div>
            </article>

            <article class="al-panel al-auction-detail-position-card">
              <div class="al-auction-detail-card-head">
                <div>
                  <p class="al-kicker">Settlement</p>
                  <h3>{@settlement.title}</h3>
                </div>
                <span class={["al-status-badge", @settlement.tone]}>{@settlement.label}</span>
              </div>

              <p class="al-inline-note">{@settlement.body}</p>

              <div class="al-auction-detail-settlement-grid">
                <article class={settlement_step_class(@settlement.state, "open")}>
                  <span>Open</span>
                </article>
                <article class={settlement_step_class(@settlement.state, "closing")}>
                  <span>Closing</span>
                </article>
                <article class={settlement_step_class(@settlement.state, "claimable")}>
                  <span>Claimable</span>
                </article>
                <article class={settlement_step_class(@settlement.state, "refunded")}>
                  <span>Refunded</span>
                </article>
                <article class={settlement_step_class(@settlement.state, "complete")}>
                  <span>Complete</span>
                </article>
              </div>
            </article>

            <article class="al-panel al-auction-detail-position-card">
              <div class="al-auction-detail-card-head">
                <div>
                  <p class="al-kicker">Your position</p>
                  <h3>What you can do from here</h3>
                </div>
              </div>

              <%= if @positions == [] do %>
                <p class="al-inline-note">
                  No bids recorded for this auction yet. Use the estimate above to see where a new
                  bid would land before you send the wallet action.
                </p>
              <% else %>
                <article :for={position <- @positions} class="al-auction-detail-position-row">
                  <div class="al-auction-detail-position-top">
                    <div>
                      <strong>{position.amount} USDC</strong>
                      <p>{position.max_price} max price</p>
                    </div>
                    <.status_badge status={position.status} />
                  </div>

                  <div class="al-auction-detail-position-metrics">
                    <article>
                      <span>Tokens filled</span>
                      <strong>{position.tokens_filled}</strong>
                    </article>
                    <article>
                      <span>If end now</span>
                      <strong>{position.estimated_tokens_if_end_now}</strong>
                    </article>
                    <article>
                      <span>Inactive above</span>
                      <strong>{position.inactive_above_price}</strong>
                    </article>
                  </div>

                  <p class="al-inline-note">{position.next_action_label}</p>

                  <div class="al-action-row">
                    <.wallet_tx_button
                      :if={return_action(position)}
                      id={"auction-return-#{position.bid_id}"}
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
                      id={"auction-exit-#{position.bid_id}"}
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
                      id={"auction-claim-#{position.bid_id}"}
                      class="al-submit"
                      tx_request={tx_action(position, :claim).tx_request}
                      register_endpoint={~p"/v1/app/bids/#{position.bid_id}/claim"}
                      pending_message="Claim transaction sent. Waiting for confirmation."
                      success_message="Claim registered."
                    >
                      Claim tokens
                    </.wallet_tx_button>
                  </div>
                </article>
              <% end %>
            </article>
          </section>

          <section
            id="auction-detail-secondary"
            class="al-auction-detail-secondary"
            phx-hook="MissionMotion"
          >
            <details class="al-panel al-disclosure">
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

            <details class="al-panel al-disclosure">
              <summary class="al-disclosure-summary">
                <div>
                  <p class="al-kicker">Auction model</p>
                  <h3>Why the market behaves this way</h3>
                </div>
                <span class="al-network-badge">Secondary</span>
              </summary>

              <ul class="al-compact-list">
                <li>Bid early with your real budget and your real max price instead of waiting for a last-second entry.</li>
                <li>Each block uses one shared clearing price. Your bid participates while that price is at or below your max price.</li>
                <li>Slower, visible price discovery leaves less room for sniping and speed advantages.</li>
              </ul>
            </details>
          </section>
        </div>
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

  defp default_bid_form(nil),
    do: %{"amount" => "250.0", "max_price" => "0.0050", "desired_exposure" => "12"}

  defp default_bid_form(auction) do
    %{
      "amount" => "250.0",
      "max_price" => decimal_plus(auction.current_clearing_price, "0.0008"),
      "desired_exposure" => "12"
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
    form
    |> Map.put("max_price", decimal_plus(auction.current_clearing_price, "0.0005"))
    |> Map.put("desired_exposure", "8")
  end

  defp preset_form(auction, form, "stay_active") do
    form
    |> Map.put("max_price", decimal_plus(auction.current_clearing_price, "0.0009"))
    |> Map.put("desired_exposure", "16")
  end

  defp preset_form(auction, form, "aggressive") do
    form
    |> Map.put("amount", "500.0")
    |> Map.put("max_price", decimal_plus(auction.current_clearing_price, "0.0014"))
    |> Map.put("desired_exposure", "28")
  end

  defp preset_form(_auction, form, _preset), do: form

  defp auction_trust(nil), do: %{}
  defp auction_trust(%{trust: trust}) when is_map(trust), do: trust
  defp auction_trust(_auction), do: %{}

  defp auction_trust_summary(%{
         ens: %{connected: ens_connected, name: ens_name},
         world: %{connected: world_connected, human_id: human_id, launch_count: launch_count}
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
      ens: %{title: "Needs link", body: "The creator identity still needs an ENS name attached."},
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

  defp bid_planner(nil, form) do
    %{
      title: "Waiting for estimate",
      body: "Enter max spend and max price to preview the bid.",
      target_title: exposure_target(form),
      target_body: "The target check appears with the estimate."
    }
  end

  defp bid_planner(quote, form) do
    expected = decimal_from_text(Map.get(quote, :estimated_tokens_if_no_other_bids_change))
    target = decimal_from_text(Map.get(form, "desired_exposure"))
    spend = Map.get(quote, :amount) || Map.get(form, "amount") || "0"
    max_price = Map.get(quote, :max_price) || Map.get(form, "max_price") || "0"

    %{
      title: "~#{Map.get(quote, :estimated_tokens_if_no_other_bids_change, "0")} tokens",
      body: "This bid can spend up to #{spend} USDC while the price is at or below #{max_price}.",
      target_title: target_result_title(expected, target),
      target_body: target_result_body(expected, target)
    }
  end

  defp exposure_target(form) do
    case Map.get(form, "desired_exposure") do
      value when is_binary(value) and value != "" -> "#{value} tokens"
      _ -> "No target yet"
    end
  end

  defp target_result_title(nil, _target), do: "Waiting"
  defp target_result_title(_expected, nil), do: "Add a target"

  defp target_result_title(expected, target) do
    if Decimal.compare(expected, target) in [:eq, :gt],
      do: "On pace for target",
      else: "Below target"
  end

  defp target_result_body(nil, _target), do: "The estimate needs both bid fields."
  defp target_result_body(_expected, nil), do: "Add desired exposure to compare the estimate."

  defp target_result_body(expected, target) do
    gap = Decimal.sub(target, expected)

    if Decimal.compare(gap, Decimal.new(0)) == :gt do
      "About #{decimal_display(gap)} more tokens needed to reach the target."
    else
      "The current estimate meets the desired exposure."
    end
  end

  defp settlement_panel(nil, _position) do
    %{
      state: "open",
      label: "Open",
      tone: "is-muted",
      title: "Settlement status will appear here.",
      body: "Load an auction to see what happens next."
    }
  end

  defp settlement_panel(_auction, %{status: "claimable"}) do
    %{
      state: "claimable",
      label: "Claimable",
      tone: "is-live",
      title: "Tokens are ready to claim.",
      body: "Collect the purchased tokens when you are ready."
    }
  end

  defp settlement_panel(_auction, %{status: status}) when status in ["returnable", "exited"] do
    %{
      state: "refunded",
      label: "Refunded",
      tone: "is-warn",
      title: "USDC return is ready.",
      body: "Return the remaining USDC to finish this position."
    }
  end

  defp settlement_panel(_auction, %{status: status}) when status in ["claimed", "settled"] do
    %{
      state: "complete",
      label: "Complete",
      tone: "is-muted",
      title: "This position is complete.",
      body: "No wallet action is waiting for this bid."
    }
  end

  defp settlement_panel(auction, _position) do
    cond do
      truthy?(auction_value(auction, :returns_enabled)) ->
        %{
          state: "refunded",
          label: "Refunded",
          tone: "is-warn",
          title: "USDC return is available.",
          body: "This market ended below the minimum raise."
        }

      auction_value(auction, :phase) == "biddable" and detail_closing_soon?(auction) ->
        %{
          state: "closing",
          label: "Closing",
          tone: "is-warn",
          title: "This auction is closing soon.",
          body: "Review your bid before the market closes."
        }

      auction_value(auction, :phase) == "live" ->
        %{
          state: "complete",
          label: "Complete",
          tone: "is-muted",
          title: "The auction has closed.",
          body: "Check your position for any available claim."
        }

      true ->
        %{
          state: "open",
          label: "Open",
          tone: "is-live",
          title: "This auction is open.",
          body: "Use the planner to estimate the bid before signing."
        }
    end
  end

  defp settlement_step_class(current, step) do
    ["al-auction-detail-settlement-step", current == step && "is-active"]
  end

  defp detail_closing_soon?(auction) do
    case auction_value(auction, :ends_at) do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _} ->
            seconds = DateTime.diff(datetime, DateTime.utc_now(), :second)
            seconds > 0 and seconds <= 7_200

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp decimal_from_text(nil), do: nil

  defp decimal_from_text(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  defp decimal_from_text(value) when is_integer(value), do: Decimal.new(value)
  defp decimal_from_text(_value), do: nil

  defp decimal_display(%Decimal{} = value) do
    value
    |> Decimal.round(2)
    |> Decimal.to_string(:normal)
  end

  defp auction_description(auction) do
    case auction_value(auction, :notes) do
      notes when is_binary(notes) and notes != "" ->
        notes

      _ ->
        "Use the bid composer first, then confirm the live estimate, minimum raise pace, and your current position before you send the wallet action."
    end
  end

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
    case auction_value(auction, :symbol) do
      value when is_binary(value) and value != "" -> value
      _ -> "Token"
    end
  end

  defp detail_status_label(auction) do
    cond do
      truthy?(auction_value(auction, :returns_enabled)) -> "Returns ready"
      auction_value(auction, :status) in ["active", "biddable"] -> "Live"
      auction_value(auction, :phase) == "live" -> "Live"
      true -> LaunchComponents.time_left_label(auction_value(auction, :ends_at))
    end
  end

  defp detail_status_value(auction) do
    auction
    |> auction_value(:status, "active")
    |> to_string()
    |> String.capitalize()
  end

  defp bidder_copy(auction) do
    case auction_value(auction, :bidders) do
      bidders when is_integer(bidders) and bidders > 0 -> "#{bidders} bids"
      bidders when is_binary(bidders) and bidders != "" -> "#{bidders} bids"
      _ -> "Live auction activity"
    end
  end

  defp price_source_label(auction) do
    case auction_value(auction, :price_source) do
      "auction_clearing" -> "Auction clearing"
      "uniswap_spot" -> "Uniswap spot"
      "uniswap_spot_unavailable" -> "Quote pending"
      _ -> "Live price"
    end
  end

  defp latest_bid_value(nil), do: "No bid yet"
  defp latest_bid_value(position), do: "#{position.amount} USDC"

  defp latest_bid_copy(nil), do: "Run the estimate first to preview where a new bid would land."
  defp latest_bid_copy(position), do: "#{position.max_price} max price"

  defp returns_strip_title(auction, latest_position) do
    cond do
      latest_position && return_action(latest_position) -> "Return ready"
      truthy?(auction_value(auction, :returns_enabled)) -> "Open if needed"
      true -> "Not needed"
    end
  end

  defp returns_strip_copy(auction, latest_position) do
    cond do
      latest_position && return_action(latest_position) ->
        "This position can pull USDC back."

      truthy?(auction_value(auction, :returns_enabled)) ->
        "This market ended below the minimum raise."

      true ->
        "Returns only open if the market misses the minimum raise."
    end
  end

  defp status_strip_copy(nil), do: "No bid recorded"
  defp status_strip_copy(position), do: position.next_action_label

  defp human_position_status(nil), do: "No bid"
  defp human_position_status(position), do: String.capitalize(position.status)

  defp format_timestamp(nil), do: "Unknown"

  defp format_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> Calendar.strftime(datetime, "%b %-d, %Y %I:%M %p UTC")
      _ -> "Unknown"
    end
  end

  defp metrics_updated_copy(auction) do
    case auction_value(auction, :metrics_updated_at) do
      nil -> "Live estimate"
      value -> "Updated #{format_short_timestamp(value)}"
    end
  end

  defp format_short_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> Calendar.strftime(datetime, "%b %-d")
      _ -> "recently"
    end
  end

  defp quote_value(nil, _key, default), do: default
  defp quote_value(quote, key, default), do: Map.get(quote, key, default)

  defp price_curve_path(auction, quote) do
    with current when is_number(current) <-
           decimal_to_float(auction_value(auction, :current_clearing_price)),
         projected when is_number(projected) <-
           decimal_to_float(quote_value(quote, :projected_clearing_price, nil)) do
      top = max(current, projected)
      base = max(top * 1.18, 0.0001)
      start_y = scale_curve(base, current * 1.14)
      mid_y = scale_curve(base, (current + projected) / 2 + current * 0.08)
      end_y = scale_curve(base, current)
      projected_y = scale_curve(base, projected)

      "M 20 #{start_y} C 92 #{start_y + 4}, 132 #{mid_y}, 198 #{mid_y + 16} S 276 #{projected_y + 10}, 316 #{end_y}"
    else
      _ -> nil
    end
  end

  defp price_curve_current_y(auction, quote) do
    with current when is_number(current) <-
           decimal_to_float(auction_value(auction, :current_clearing_price)),
         projected when is_number(projected) <-
           decimal_to_float(quote_value(quote, :projected_clearing_price, nil)) do
      top = max(current, projected)
      scale_curve(max(top * 1.18, 0.0001), current)
    else
      _ -> 118
    end
  end

  defp scale_curve(base, value) do
    normalized = if base <= 0, do: 0.5, else: min(max(value / base, 0.05), 1.0)
    24 + Float.round((1.0 - normalized) * 112, 2)
  end

  defp decimal_to_float(nil), do: nil

  defp decimal_to_float(value) when is_binary(value) do
    case D.parse(value) do
      {decimal, ""} -> D.to_float(decimal)
      _ -> nil
    end
  end

  defp decimal_to_float(value) when is_integer(value), do: value * 1.0
  defp decimal_to_float(_value), do: nil

  defp status_tone(auction) do
    cond do
      truthy?(auction_value(auction, :returns_enabled)) -> "is-muted"
      auction_value(auction, :status) in ["active", "biddable"] -> "is-warn"
      true -> "is-muted"
    end
  end

  defp truthy?(value), do: value in [true, "true", 1, "1"]

  defp auction_value(auction, key, default \\ nil)
  defp auction_value(nil, _key, default), do: default

  defp auction_value(auction, key, default) when is_map(auction),
    do: Map.get(auction, key, default)

  defp return_action(position) when is_map(position), do: Map.get(position, :return_action)

  defp tx_action(position, action) when is_map(position) do
    position
    |> Map.get(:tx_actions, %{})
    |> Map.get(action)
  end

  defp network_label(auction) do
    case auction_value(auction, :chain) do
      chain when is_binary(chain) and chain != "" -> chain
      _ -> auction_value(auction, :network, "Unknown")
    end
  end

  defp launch_module do
    :autolaunch
    |> Application.get_env(:auction_live, [])
    |> Keyword.get(:launch_module, Launch)
  end

  defp route_css, do: @auctions_css
end
