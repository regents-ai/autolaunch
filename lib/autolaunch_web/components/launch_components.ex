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
    <div
      id="autolaunch-shell"
      class="al-app-shell rg-app-shell rg-regent-theme-autolaunch"
      phx-hook="ShellChrome"
    >
      <.background_grid id="autolaunch-background-grid" class="rg-regent-theme-autolaunch" />
      <header class="al-topbar al-panel">
        <div class="al-brand">
          <p class="al-kicker">Regent CCA</p>
          <div>
            <h1 translate="no">autolaunch.sh</h1>
            <p>Plan the launch, watch the auction, and manage revenue from one Sepolia view.</p>
          </div>
        </div>

        <div class="al-shell-nav">
          <nav class="al-topnav" aria-label="Primary">
            <.nav_link active={@active_view == "home"} navigate={~p"/"}>Home</.nav_link>
            <.nav_link active={@active_view == "launch"} navigate={~p"/launch"}>Launch</.nav_link>
            <.nav_link active={@active_view == "auctions"} navigate={~p"/auctions"}>Auctions</.nav_link>
            <.nav_link active={@active_view == "positions"} navigate={~p"/positions"}>Positions</.nav_link>
            <.nav_link active={@active_view == "profile"} navigate={~p"/profile"}>Profile</.nav_link>
          </nav>

          <div class="al-shell-utility-row">
            <nav class="al-topnav-secondary" aria-label="Utilities">
              <span class="al-utility-label">More</span>
              <.utility_link active={@active_view == "guide"} navigate={~p"/how-auctions-work"}>
                Guide
              </.utility_link>
              <.utility_link active={@active_view == "agentbook"} navigate={~p"/agentbook"}>
                Trust Check
              </.utility_link>
              <.utility_link active={@active_view == "ens"} navigate={~p"/ens-link"}>ENS Link</.utility_link>
              <.utility_link active={@active_view == "x-link"} navigate={~p"/x-link"}>X Link</.utility_link>
              <.utility_link active={@active_view == "contracts"} navigate={~p"/contracts"}>
                Contracts
              </.utility_link>
            </nav>

            <div class="al-topbar-actions">
              <button class="al-theme" type="button" data-theme-action="toggle">Theme</button>
              <div
                class="al-auth-chip"
                id="privy-auth"
                phx-hook="PrivyAuth"
                data-privy-app-id={privy_app_id()}
                data-session-state={if @current_human, do: "present", else: "missing"}
              >
                <div>
                  <span class="al-auth-label">Operator</span>
                  <strong data-privy-state>
                    {if @current_human,
                      do: @current_human.display_name || @current_human.wallet_address || "connected",
                      else: "guest"}
                  </strong>
                </div>
                <button type="button" data-privy-action="toggle">
                  {if @current_human, do: "Disconnect wallet", else: "Connect wallet"}
                </button>
              </div>
            </div>
          </div>
        </div>
      </header>

      <.welcome_modal />
      <.wallet_switch_modal wallet_switch={@wallet_switch} />

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
            <h2 id="autolaunch-welcome-title">The hub for agent companies to begin.</h2>
          </div>
        </div>

        <p id="autolaunch-welcome-copy" class="al-welcome-copy">
          A token auction lets anyone split in the onchain revenue an agent will make. Use the
          Autolaunch Skill with your OpenClaw or Hermes agent to fund its operations as a long-term
          agent business.
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
  attr :action_label, :string, default: nil
  attr :action_href, :string, default: nil

  def empty_state(assigns) do
    ~H"""
    <article class="al-panel al-empty-state">
      <p class="al-kicker">No result</p>
      <h3>{@title}</h3>
      <p>{@body}</p>
      <%= if @action_label && @action_href do %>
        <a href={@action_href} class="al-cta-link">{@action_label}</a>
      <% end %>
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

  defp privy_app_id do
    Application.get_env(:autolaunch, :privy, [])
    |> Keyword.get(:app_id, "")
  end
end
