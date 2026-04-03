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
            <h1>autolaunch.sh</h1>
            <p>Continuous clearing auctions built to help quality teams bootstrap liquidity with healthier market behavior and real price discovery.</p>
          </div>
        </div>

        <nav class="al-topnav" aria-label="Primary">
          <.nav_link active={@active_view == "guide"} navigate={~p"/"}>
            How It Works
          </.nav_link>
          <.nav_link active={@active_view == "launch"} navigate={~p"/launch"}>Launch</.nav_link>
          <.nav_link active={@active_view == "agentbook"} navigate={~p"/agentbook"}>Trust Check</.nav_link>
          <.nav_link active={@active_view == "ens"} navigate={~p"/ens-link"}>ENS Link</.nav_link>
          <.nav_link active={@active_view == "auctions"} navigate={~p"/auctions"}>Tokens</.nav_link>
          <.nav_link active={@active_view == "profile"} navigate={~p"/profile"}>Profile</.nav_link>
          <.nav_link active={@active_view == "positions"} navigate={~p"/positions"}>Positions</.nav_link>
          <.nav_link active={@active_view == "contracts"} navigate={~p"/contracts"}>Contracts</.nav_link>
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
              {if @current_human, do: "Logout", else: "Privy Login"}
            </button>
          </div>
        </div>
      </header>

      <main class="al-stage">
        {render_slot(@inner_block)}
      </main>
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
    with {:ok, datetime, _offset} <- DateTime.from_iso8601(iso) do
      diff = DateTime.diff(datetime, DateTime.utc_now(), :second)

      cond do
        diff <= 0 -> "Ended"
        diff >= 86_400 -> "#{div(diff, 86_400)}d #{rem(div(diff, 3_600), 24)}h"
        true -> "#{div(diff, 3_600)}h #{rem(div(diff, 60), 60)}m"
      end
    else
      _ -> "Unknown"
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
