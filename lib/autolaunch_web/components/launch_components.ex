defmodule AutolaunchWeb.LaunchComponents do
  @moduledoc false
  use Phoenix.Component
  use Regent

  use Gettext, backend: AutolaunchWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: AutolaunchWeb.Endpoint,
    router: AutolaunchWeb.Router,
    statics: AutolaunchWeb.static_paths()

  attr :current_human, :map, default: nil
  attr :active_view, :string, default: "launch"
  attr :wallet_switch, :map, default: nil
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <div id="autolaunch-shell">
      <main class="al-stage">
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  attr :wallet_switch, :map, default: nil

  def wallet_switch_modal(%{wallet_switch: nil} = assigns) do
    ~H"""
    """
  end

  def wallet_switch_modal(assigns) do
    ~H"""
    <div
      id="autolaunch-wallet-switch-modal"
      class="modal modal-open modal-middle al-welcome-modal"
      phx-hook="WalletSwitchModal"
      phx-update="ignore"
      data-wallet-switch-address={@wallet_switch.wallet_address}
    >
      <div
        class="modal-box al-welcome-card"
        role="dialog"
        aria-modal="true"
        aria-labelledby="autolaunch-wallet-switch-title"
        aria-describedby="autolaunch-wallet-switch-copy"
      >
        <div class="al-welcome-hero">
          <div>
            <p class="al-kicker">Wallet required</p>
            <h2 id="autolaunch-wallet-switch-title">
              Switch to wallet '{@wallet_switch.wallet_address}' to access.
            </h2>
          </div>
        </div>

        <p id="autolaunch-wallet-switch-copy" class="al-welcome-copy">
          This page belongs to a different linked wallet. Continue when that wallet is active in
          your browser wallet.
        </p>

        <div class="al-welcome-actions">
          <button type="button" class="al-submit" data-wallet-switch-continue>Continue</button>
        </div>

        <p class="al-welcome-footnote" data-wallet-switch-status>
          Switch wallets in your browser wallet, then continue here.
        </p>
      </div>
    </div>
    """
  end

  def welcome_modal(assigns) do
    ~H"""
    <div
      id="autolaunch-welcome-modal"
      class="modal modal-middle al-welcome-modal"
      phx-hook="WelcomeModal"
      phx-update="ignore"
      hidden
      aria-hidden="true"
      data-cookie-name="autolaunch_welcome_seen"
    >
      <div
        class="modal-box al-welcome-card"
        role="dialog"
        aria-modal="true"
        aria-labelledby="autolaunch-welcome-title"
        aria-describedby="autolaunch-welcome-copy"
      >
        <button
          type="button"
          class="al-welcome-close"
          aria-label="Dismiss welcome"
          data-welcome-close
        >
          ×
        </button>

        <div class="al-welcome-hero">
          <img
            src={~p"/images/autolaunch-logo-large.png"}
            alt="Autolaunch"
            class="al-welcome-logo"
            width="360"
            height="360"
          />
          <div>
            <p class="al-kicker">Welcome to autolaunch.sh</p>
            <h2 id="autolaunch-welcome-title">Turn agent edge into runway.</h2>
          </div>
        </div>

        <p id="autolaunch-welcome-copy" class="al-welcome-copy">
          Launch a market around a real agent, bring in aligned backers, and keep one place for
          auctions, claims, staking, and revenue as the agent grows.
        </p>

        <div class="al-welcome-actions">
          <button type="button" class="al-submit" data-welcome-continue>Continue</button>
        </div>

        <p class="al-welcome-footnote">
          By continuing, you confirm that you are at least 18 years old and agree to the
          <.link navigate={~p"/terms"} class="al-inline-link">Terms and Conditions</.link> and
          <.link navigate={~p"/privacy"} class="al-inline-link">Privacy Policy</.link>.
        </p>
      </div>
    </div>
    """
  end

  attr :active, :boolean, default: false
  attr :navigate, :string, required: true
  slot :inner_block, required: true

  def nav_link(assigns) do
    ~H"""
    <.link navigate={@navigate} class={["al-nav-link", @active && "is-active"]}>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :active, :boolean, default: false
  attr :navigate, :string, required: true
  slot :inner_block, required: true

  def utility_link(assigns) do
    ~H"""
    <.link navigate={@navigate} class={["al-utility-link", @active && "is-active"]}>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :status, :string, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={["al-status-badge", status_class(@status)]}>{humanize_status(@status)}</span>
    """
  end

  attr :state, :string, required: true

  def agent_state_badge(assigns) do
    ~H"""
    <span class={["al-status-badge", agent_state_class(@state)]}>{humanize_state(@state)}</span>
    """
  end

  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :hint, :string, default: nil

  def stat_card(assigns) do
    ~H"""
    <article class="al-stat-card">
      <span>{@title}</span>
      <strong>{@value}</strong>
      <%= if @hint do %>
        <p>{@hint}</p>
      <% end %>
    </article>
    """
  end

  attr :index, :integer, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :complete, :boolean, default: false

  def step_chip(assigns) do
    ~H"""
    <div class={["al-step-chip", @active && "is-active", @complete && "is-complete"]}>
      <span class="al-step-index">{@index}</span>
      <span>{@label}</span>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :body, :string, required: true
  attr :kicker, :string, default: "Next step"
  attr :mark, :string, default: "AL"
  attr :action_label, :string, default: nil
  attr :action_href, :string, default: nil

  def empty_state(assigns) do
    ~H"""
    <article class="al-panel al-empty-state">
      <div class="al-empty-state-mark" aria-hidden="true">{@mark}</div>
      <div class="al-empty-state-copy">
        <p class="al-kicker">{@kicker}</p>
        <h3>{@title}</h3>
        <p>{@body}</p>
      </div>
      <a :if={@action_label && @action_href} href={@action_href} class="al-cta-link">
        {@action_label}
      </a>
    </article>
    """
  end

  attr :id, :string, required: true
  attr :tx_request, :map, required: true
  attr :register_endpoint, :string, default: nil
  attr :register_body, :map, default: %{}
  attr :pending_message, :string, required: true
  attr :success_message, :string, required: true
  attr :class, :string, default: "al-submit"
  slot :inner_block, required: true

  def wallet_tx_button(assigns) do
    assigns = assign(assigns, :encoded_register_body, Jason.encode!(assigns.register_body))

    ~H"""
    <button
      id={@id}
      type="button"
      class={@class}
      phx-hook="WalletTxButton"
      data-chain-id={@tx_request.chain_id}
      data-to={@tx_request.to}
      data-data={@tx_request.data}
      data-value={@tx_request.value}
      data-register-endpoint={@register_endpoint}
      data-register-body={@encoded_register_body}
      data-pending-message={@pending_message}
      data-success-message={@success_message}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :kicker, :string, default: "Action desk"
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, required: true
  attr :status_label, :string, default: nil
  attr :class, :string, default: nil
  slot :primary
  slot :secondary
  slot :aside

  def action_desk(assigns) do
    ~H"""
    <section id={@id} class={["al-action-desk", @class]} phx-hook="MissionMotion">
      <div class="al-action-desk-main">
        <div class="al-action-desk-copy">
          <div>
            <p class="al-kicker">{@kicker}</p>
            <h2>{@title}</h2>
          </div>
          <p>{@body}</p>
          <span :if={@status_label} class="al-action-desk-status">{@status_label}</span>
        </div>

        <div :if={@primary != [] or @secondary != []} class="al-action-desk-buttons">
          {render_slot(@primary)}
          {render_slot(@secondary)}
        </div>
      </div>

      <div :if={@aside != []} class="al-action-desk-aside">
        {render_slot(@aside)}
      </div>
    </section>
    """
  end

  attr :kicker, :string, required: true
  attr :title, :string, required: true
  attr :command, :string, required: true
  attr :output_label, :string, required: true
  attr :output, :string, required: true
  attr :copy_label, :string, default: "Copy command"

  def terminal_command_panel(assigns) do
    ~H"""
    <aside class="al-terminal-panel" aria-label={@title}>
      <div class="al-terminal-shell">
        <div class="al-terminal-topbar">
          <div class="al-terminal-dots" aria-hidden="true">
            <span></span>
            <span></span>
            <span></span>
          </div>
          <div>
            <p class="al-kicker">{@kicker}</p>
            <p class="al-terminal-title">{@title}</p>
          </div>
          <button
            type="button"
            class="al-copy-trigger"
            data-copy-value={@command}
            data-copy-label={@copy_label}
          >
            {@copy_label}
          </button>
        </div>

        <pre class="al-terminal-command"><code>{@command}</code></pre>

        <div class="al-terminal-output">
          <p class="al-terminal-output-label">{@output_label}</p>
          <pre><code>{@output}</code></pre>
        </div>
      </div>
    </aside>
    """
  end

  def time_left_label(nil), do: "Unknown"

  def time_left_label(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} ->
        diff = DateTime.diff(datetime, DateTime.utc_now(), :second)

        cond do
          diff <= 0 -> "Ended"
          diff >= 86_400 -> "#{div(diff, 86_400)}d #{rem(div(diff, 3_600), 24)}h"
          true -> "#{div(diff, 3_600)}h #{rem(div(diff, 60), 60)}m"
        end

      _ ->
        "Unknown"
    end
  end

  defp status_class(status) when status in ["ready", "active", "claimable"], do: "is-ready"

  defp status_class(status)
       when status in ["queued", "running", "borderline", "ending-soon", "pending-claim"],
       do: "is-warn"

  defp status_class(status)
       when status in ["inactive", "failed", "expired", "settled", "claimed", "exited"],
       do: "is-danger"

  defp status_class(_status), do: "is-muted"

  defp agent_state_class("eligible"), do: "is-ready"
  defp agent_state_class("missing_setup"), do: "is-warn"
  defp agent_state_class("wallet_bound"), do: "is-warn"
  defp agent_state_class("already_launched"), do: "is-muted"
  defp agent_state_class(_state), do: "is-muted"

  defp humanize_status(status) do
    status
    |> humanize_state()
  end

  defp humanize_state(status) do
    case to_string(status) do
      "ending-soon" ->
        "Ending soon"

      "pending-claim" ->
        "Pending claim"

      other ->
        other
        |> String.replace("-", " ")
        |> String.replace("_", " ")
        |> String.split()
        |> Enum.map_join(" ", &String.capitalize/1)
    end
  end
end
