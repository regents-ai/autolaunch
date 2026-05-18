defmodule AutolaunchWeb.SubjectLive.Components do
  @moduledoc false

  use AutolaunchWeb, :html

  alias AutolaunchWeb.SubjectLive.Presenter

  attr :subject, :map, required: true
  attr :subject_id, :string, required: true
  attr :subject_heading, :string, required: true
  attr :subject_summary, :string, required: true
  attr :subject_symbol, :string, default: nil
  attr :subject_auction_href, :string, default: nil
  attr :recommended_action, :atom, required: true

  def header(assigns) do
    ~H"""
    <header class="al-subject-header">
      <div class="al-subject-title-group">
        <.link navigate={~p"/auctions"} class="al-subject-back">
          <span aria-hidden="true">←</span>
          <span>Back to auctions</span>
        </.link>

        <div class="al-subject-title-row">
          <div class="al-subject-mark">
            <span>{Presenter.subject_initials(@subject_heading)}</span>
          </div>

          <div class="al-subject-heading-block">
            <div class="al-subject-heading-line">
              <h1>{@subject_heading}</h1>
              <span :if={@subject_symbol} class="al-subject-chip">{@subject_symbol}</span>
            </div>

            <div class="al-subject-meta">
              <span>on {Map.get(@subject, :chain_label, "Base")}</span>
              <span class="al-subject-status">
                <span class="al-subject-status-dot"></span>
                <span>{Presenter.recommended_status_label(@recommended_action)}</span>
              </span>
            </div>

            <p class="al-subject-summary">
              {@subject_summary}
            </p>
          </div>
        </div>
      </div>

      <div class="al-subject-header-actions">
        <.link
          :if={@subject_auction_href}
          navigate={@subject_auction_href}
          class="al-subject-secondary-button"
        >
          Open auction page
        </.link>
        <.link navigate={~p"/contracts?subject_id=#{@subject_id}"} class="al-subject-primary-button">
          Open contracts
        </.link>
      </div>
    </header>
    """
  end

  attr :wallet_position, :map, required: true

  def metric_grid(assigns) do
    ~H"""
    <section class="al-subject-metric-grid">
      <.subject_metric
        label="Claimable USDC"
        value={@wallet_position.claimable_usdc}
        hint={@wallet_position.claimable_usdc_line}
      />
      <.subject_metric
        label="Your staked agent tokens"
        value={@wallet_position.wallet_stake_balance}
        hint={@wallet_position.staked_line}
      />
      <.subject_metric
        label="Wallet agent-token balance"
        value={@wallet_position.wallet_token_balance}
        hint={@wallet_position.wallet_line}
      />
      <.subject_metric
        label="Claimable agent-token emissions"
        value={@wallet_position.claimable_stake_token}
        hint={@wallet_position.claimable_emissions_line}
      />
    </section>
    """
  end

  attr :routing_snapshot, :map, required: true
  attr :subject, :map, required: true

  def revenue_routing(assigns) do
    ~H"""
    <section class="al-routing-policy-panel">
      <div class="al-routing-policy-copy">
        <div>
          <p class="al-kicker">Revenue routing</p>
          <h2>Follow the live share, the queued change, and every tracked dollar.</h2>
        </div>
        <p>
          Agent revenue counts when USDC reaches this subject's revenue contract. Money waiting in an intake account can be swept before a pending share change takes effect; money swept later follows the live share at that time.
        </p>

        <div class="al-routing-policy-stats">
          <article>
            <span>Live eligible share</span>
            <strong>{@routing_snapshot.live_share}</strong>
            <p>The share of agent revenue after the fixed Regent platform skim that stays eligible for agent-token stakers.</p>
          </article>
          <article>
            <span>Pending share</span>
            <strong>{@routing_snapshot.pending_share}</strong>
            <p>{@routing_snapshot.pending_note}</p>
          </article>
          <article>
            <span>Activation date</span>
            <strong>{@routing_snapshot.activation_date}</strong>
            <p>When the pending share can first go live.</p>
          </article>
          <article>
            <span>Cooldown end</span>
            <strong>{@routing_snapshot.cooldown_end}</strong>
            <p>When another proposal can be queued after the latest cancel or activation.</p>
          </article>
        </div>

        <%= if @routing_snapshot.change_chart do %>
          <section
            class="al-routing-change-visual"
            role="img"
            aria-label={"Upcoming eligible share change from #{@routing_snapshot.change_chart.current_rate} on #{@routing_snapshot.change_chart.current_date} to #{@routing_snapshot.change_chart.next_rate} on #{@routing_snapshot.change_chart.next_date}"}
          >
            <div class="al-routing-change-copy">
              <div>
                <span>Upcoming change</span>
                <strong>{@routing_snapshot.change_chart.headline}</strong>
              </div>
              <p>{@routing_snapshot.change_chart.summary}</p>
            </div>

            <div class="al-routing-change-chart">
              <div class="al-routing-change-point is-current">
                <span>{@routing_snapshot.change_chart.current_date}</span>
                <strong>{@routing_snapshot.change_chart.current_rate}</strong>
              </div>

              <svg viewBox="0 0 240 132" aria-hidden="true">
                <line x1="22" y1="108" x2="218" y2="108" class="al-routing-change-axis" />
                <polyline
                  points={@routing_snapshot.change_chart.line_points}
                  class="al-routing-change-line"
                />
                <circle
                  cx={@routing_snapshot.change_chart.current_x}
                  cy={@routing_snapshot.change_chart.current_y}
                  r="5"
                  class="al-routing-change-dot is-current"
                />
                <circle
                  cx={@routing_snapshot.change_chart.next_x}
                  cy={@routing_snapshot.change_chart.next_y}
                  r="5"
                  class="al-routing-change-dot is-next"
                />
                <text
                  x={@routing_snapshot.change_chart.current_x}
                  y={@routing_snapshot.change_chart.current_label_y}
                  text-anchor="middle"
                  class="al-routing-change-rate"
                >
                  {@routing_snapshot.change_chart.current_rate}
                </text>
                <text
                  x={@routing_snapshot.change_chart.next_x}
                  y={@routing_snapshot.change_chart.next_label_y}
                  text-anchor="middle"
                  class="al-routing-change-rate"
                >
                  {@routing_snapshot.change_chart.next_rate}
                </text>
              </svg>

              <div class="al-routing-change-point is-next">
                <span>{@routing_snapshot.change_chart.next_date}</span>
                <strong>{@routing_snapshot.change_chart.next_rate}</strong>
              </div>
            </div>
          </section>
        <% end %>
      </div>

      <div class="al-routing-ledger">
        <article class="al-routing-ledger-card">
          <span>Total USDC received</span>
          <strong>{@routing_snapshot.total_received}</strong>
          <p>All USDC that has reached this subject.</p>
        </article>
        <article class="al-routing-ledger-card">
          <span>Verified revenue</span>
          <strong>{@routing_snapshot.verified_revenue}</strong>
          <p>USDC from intake wallets.</p>
        </article>
        <article class="al-routing-ledger-card">
          <span>Regent skim</span>
          <strong>{@routing_snapshot.regent_skim}</strong>
          <p>The fixed platform fee kept for Regent.</p>
        </article>
        <article class="al-routing-ledger-card">
          <span>Staker-eligible inflow</span>
          <strong>{@routing_snapshot.staker_eligible_inflow}</strong>
          <p>The agent revenue portion that feeds agent-token staker claims before stake-based allocation.</p>
        </article>
        <article class="al-routing-ledger-card">
          <span>Treasury-reserved inflow</span>
          <strong>{@routing_snapshot.treasury_reserved_inflow}</strong>
          <p>The agent revenue portion routed straight into the subject reserve lane.</p>
        </article>
        <article class="al-routing-ledger-card">
          <span>Subject reserve now</span>
          <strong>{@routing_snapshot.treasury_reserved_balance}</strong>
          <p>The reserve balance still sitting inside the splitter.</p>
        </article>
        <article class="al-routing-ledger-card">
          <span>Staker lane residual</span>
          <strong>{@routing_snapshot.treasury_residual}</strong>
          <p>The unstaked remainder still inside the eligible lane.</p>
        </article>
      </div>

      <div class="al-routing-ledger">
        <article class="al-routing-ledger-card">
          <span>Public revenue proof</span>
          <strong>{proof_status(@subject)}</strong>
          <p>Public chain facts for recognized agent revenue. Private work details stay out of this view.</p>
        </article>
        <article
          :for={row <- Presenter.public_revenue_proof_rows(@subject)}
          class="al-routing-ledger-card"
        >
          <span>{row.label}</span>
          <strong>{row.value}</strong>
        </article>
      </div>
    </section>

    <section class="al-routing-history-panel">
      <div class="al-routing-history-head">
        <div>
          <p class="al-kicker">Share history</p>
          <h3>See every proposal, cancel, and activation in order.</h3>
        </div>
        <span>{@routing_snapshot.history_count}</span>
      </div>

      <%= if @subject.share_change_history == [] do %>
        <p class="al-subject-muted-copy">
          No share changes have been recorded yet. The live routing rule is still the original launch setting.
        </p>
      <% else %>
        <div class="al-routing-history-list">
          <article :for={entry <- @subject.share_change_history} class="al-routing-history-item">
            <div class="al-routing-history-meta">
              <span class="al-routing-history-pill">{Presenter.history_label(entry)}</span>
              <strong>{Presenter.history_primary_value(entry)}</strong>
            </div>
            <p>{Presenter.history_copy(entry)}</p>
            <span>{Presenter.history_timestamp(entry)}</span>
          </article>
        </div>
      <% end %>
    </section>
    """
  end

  attr :subject, :map, required: true
  attr :subject_id, :string, required: true

  def advanced_review(assigns) do
    ~H"""
    <details class="al-subject-review-panel">
      <summary>
        <div>
          <p class="al-kicker">Advanced review</p>
          <h3>Contracts, balances, and ingress details</h3>
        </div>
        <span>Open</span>
      </summary>

      <div class="al-subject-review-grid">
        <.review_card
          label="Token"
          value={AutolaunchWeb.Format.short_address(@subject.token_address, "pending")}
          note="Staking token for this subject."
        />
        <.review_card
          label="Splitter"
          value={AutolaunchWeb.Format.short_address(@subject.splitter_address, "pending")}
          note="Revenue lands here before claims."
        />
        <.review_card
          label="Default ingress"
          value={AutolaunchWeb.Format.short_address(@subject.default_ingress_address, "pending")}
          note="Known USDC intake account."
        />
        <.review_card
          label="Total staked"
          value={@subject.total_staked}
          note="Committed agent tokens."
        />
        <.review_card
          label="Treasury residual"
          value={@subject.treasury_residual_usdc}
          note="Residual USDC after staker allocation."
        />
        <.review_card
          label="Protocol reserve"
          value={@subject.protocol_reserve_usdc}
          note="Platform fee retained in the subject revenue contract."
        />
      </div>

      <div class="al-subject-review-actions">
        <.link navigate={~p"/contracts?subject_id=#{@subject_id}"} class="al-subject-secondary-button">
          Open advanced contracts console
        </.link>
      </div>
    </details>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :hint, :string, default: nil

  defp subject_metric(assigns) do
    ~H"""
    <article class="al-subject-metric-card">
      <p>{@label}</p>
      <strong>{@value || "0"}</strong>
      <span :if={@hint}>{@hint}</span>
    </article>
    """
  end

  defp proof_status(%{recognized_revenue_proof: %{status: status}}) when is_binary(status),
    do: status

  defp proof_status(_subject), do: "Unavailable"

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :note, :string, required: true

  defp review_card(assigns) do
    ~H"""
    <article class="al-subject-review-card">
      <span>{@label}</span>
      <strong>{@value}</strong>
      <p>{@note}</p>
    </article>
    """
  end
end
