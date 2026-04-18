defmodule AutolaunchWeb.XLinkLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.Launch
  alias Autolaunch.Trust

  def mount(params, _session, socket) do
    identities = list_identities(socket.assigns[:current_human])
    selected_identity = selected_identity_from_params(identities, params)

    {:ok,
     socket
     |> assign(:page_title, "X Link")
     |> assign(:active_view, "x-link")
     |> assign(:identities, identities)
     |> assign(:selected_identity_id, selected_identity_id(selected_identity))
     |> assign(:selected_identity, selected_identity)
     |> assign(:trust_summary, trust_summary_for_identity(selected_identity))
     |> assign(:connect_state, "idle")}
  end

  def handle_event("select_identity", %{"agent_id" => agent_id}, socket) do
    selected_identity = find_identity(socket.assigns.identities, agent_id)

    {:noreply,
     socket
     |> assign(:selected_identity_id, selected_identity_id(selected_identity))
     |> assign(:selected_identity, selected_identity)
     |> assign(:trust_summary, trust_summary_for_identity(selected_identity))
     |> assign(:connect_state, "idle")
     |> clear_flash()}
  end

  def handle_event("x_link_started", _params, socket) do
    {:noreply, assign(socket, :connect_state, "connecting")}
  end

  def handle_event("x_link_completed", %{"agent_id" => agent_id}, socket) do
    summary = normalize_trust_summary(trust_module().summary_for_agent(agent_id))

    {:noreply,
     socket
     |> assign(:trust_summary, summary)
     |> assign(:connect_state, "connected")
     |> put_flash(:info, "X connection saved for this agent identity.")}
  end

  def handle_event("x_link_error", %{"message" => message}, socket) do
    {:noreply, socket |> assign(:connect_state, "error") |> put_flash(:error, message)}
  end

  def render(assigns) do
    x_summary = get_in(assigns.trust_summary || %{}, [:x]) || %{}
    current_handle = x_summary[:handle] || x_summary["handle"]
    current_connected = truthy?(x_summary[:connected] || x_summary["connected"])

    assigns =
      assigns
      |> assign(:current_handle, current_handle)
      |> assign(:current_connected, current_connected)

    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <section id="x-link-hero" class="al-hero al-panel" phx-hook="MissionMotion">
        <div>
          <p class="al-kicker">Identity link</p>
          <h2>Choose an identity, then connect the matching X account.</h2>
          <p class="al-subcopy">
            This is a soft public trust signal. It shows the handle on auction pages when connected,
            but missing X does not block launch, bids, or staking.
          </p>
        </div>

        <div class="al-stat-grid">
          <.stat_card title="Identities" value={Integer.to_string(length(@identities))} hint="Owned or operated by linked wallets" />
          <.stat_card title="Signal" value="Optional" hint="Visible on auction cards and detail pages" />
          <.stat_card title="Provider" value="X" hint="Connected through the browser flow" />
          <.stat_card title="Current state" value={connect_state_label(@connect_state, @current_connected)} hint="Session and browser both need to be present" />
        </div>
      </section>

      <section class="al-ens-layout">
        <article class="al-panel al-main-panel">
          <div class="al-section-head">
            <div>
              <p class="al-kicker">Step 1</p>
              <h3>Choose the ERC-8004 identity</h3>
            </div>
          </div>

          <%= cond do %>
            <% is_nil(@current_human) -> %>
              <.empty_state
                title="Sign in with Privy before linking X."
                body="The browser flow checks that your current session controls the ERC-8004 identity before it saves the X handle."
              />
            <% @identities == [] -> %>
              <.empty_state
                title="No ERC-8004 identities are linked to this session."
                body="Connect a wallet that owns or operates an ERC-8004 identity, or mint one first in the CLI."
              />
            <% true -> %>
              <div class="al-ens-identity-grid">
                <%= for identity <- @identities do %>
                  <article class={["al-agent-card", "al-ens-identity-card", identity.agent_id == @selected_identity_id && "is-selected"]}>
                    <div class="al-agent-card-head">
                      <div>
                        <p class="al-kicker">{network_label(identity)}</p>
                        <h3>{identity.name}</h3>
                        <p class="al-inline-note">{identity.agent_id}</p>
                      </div>
                      <.agent_state_badge state={identity.state} />
                    </div>

                    <div class="al-pill-row">
                      <span class={["al-network-badge", "al-access-badge"]}>{access_mode_label(identity.access_mode)}</span>
                      <span class="al-network-badge">ERC-8004 #{identity.token_id}</span>
                    </div>

                    <p class="al-inline-note">
                      {identity.ens || "No ENS name is attached in the registration file yet."}
                    </p>

                    <button
                      type="button"
                      class={["al-submit", identity.agent_id == @selected_identity_id && "is-disabled"]}
                      phx-click="select_identity"
                      phx-value-agent_id={identity.agent_id}
                      disabled={identity.agent_id == @selected_identity_id}
                    >
                      {if identity.agent_id == @selected_identity_id, do: "Selected", else: "Use this identity"}
                    </button>
                  </article>
                <% end %>
              </div>
          <% end %>
        </article>

        <article class="al-panel al-side-panel">
          <div class="al-section-head">
            <div>
              <p class="al-kicker">Step 2</p>
              <h3>Choose the X account</h3>
            </div>
          </div>

          <%= if @selected_identity do %>
            <div class="al-inline-banner">
              <strong>Selected identity</strong>
              <p>
                {selected_identity_name(@selected_identity)} will show its X handle on auction cards and auction detail once the browser flow completes.
              </p>
            </div>

            <div class="al-note-grid">
              <article class="al-note-card">
                <span>Current X status</span>
                <strong>{if @current_connected, do: "@#{@current_handle}", else: "Not connected"}</strong>
                <p>
                  {if @current_connected,
                    do: "Reconnect any time to replace the handle on this agent identity.",
                    else: "Missing X is fine. This just gives the market one more public breadcrumb."}
                </p>
              </article>

              <article class="al-note-card">
                <span>Other trust signals</span>
                <strong>Shown together</strong>
                <p>
                  Auction pages also show the ENS name, World connection, launch count for the same World ID, and the ERC-8004 token id.
                </p>
              </article>
            </div>

            <div
              id="x-link-flow"
              class="al-inline-banner"
              phx-hook="XLinkFlow"
              data-agent-id={@selected_identity.agent_id}
              data-privy-app-id={privy_app_id()}
              data-start-endpoint={~p"/api/trust/x/start"}
              data-callback-endpoint={~p"/api/trust/x/callback"}
              data-redirect-path={~p"/x-link?identity_id=#{@selected_identity.agent_id}"}
            >
              <strong>Browser flow</strong>
              <p>
                The browser opens X, returns here, then saves the verified handle for the selected ERC-8004 identity.
              </p>

              <div class="al-action-row">
                <button type="button" class="al-submit" data-x-link-action="connect">
                  {if @current_connected, do: "Reconnect X", else: "Connect X"}
                </button>
                <.link navigate={~p"/home"} class="al-cta-link">Back to auctions</.link>
              </div>
            </div>
          <% else %>
            <.empty_state
              title="Choose an identity first."
              body="The X connection is attached to one ERC-8004 identity at a time so auction pages can show the right handle."
            />
          <% end %>
        </article>
      </section>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end

  defp list_identities(current_human), do: launch_module().list_agents(current_human)

  defp selected_identity_from_params(identities, %{"identity_id" => agent_id}) do
    find_identity(identities, agent_id)
  end

  defp selected_identity_from_params(identities, %{"agent_id" => agent_id}) do
    find_identity(identities, agent_id)
  end

  defp selected_identity_from_params([identity | _rest], _params), do: identity
  defp selected_identity_from_params([], _params), do: nil

  defp find_identity(identities, agent_id) do
    Enum.find(identities, &(&1.agent_id == agent_id or &1.id == agent_id))
  end

  defp selected_identity_id(nil), do: nil
  defp selected_identity_id(identity), do: identity.agent_id

  defp selected_identity_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp selected_identity_name(%{agent_id: agent_id}), do: agent_id
  defp selected_identity_name(_identity), do: "Selected identity"

  defp trust_summary_for_identity(nil), do: %{}

  defp trust_summary_for_identity(identity) do
    identity.agent_id
    |> trust_module().summary_for_agent()
    |> normalize_trust_summary()
  end

  defp normalize_trust_summary(%{} = summary), do: summary
  defp normalize_trust_summary(_value), do: %{}

  defp connect_state_label("connecting", _connected), do: "Connecting"
  defp connect_state_label("error", _connected), do: "Needs retry"
  defp connect_state_label(_state, true), do: "Connected"
  defp connect_state_label(_state, false), do: "Waiting"

  defp network_label(%{chain_id: 1}), do: "Ethereum mainnet"
  defp network_label(%{chain_id: 84_532}), do: "Base Sepolia"
  defp network_label(%{chain_id: 8_453}), do: "Base"
  defp network_label(_identity), do: "ERC-8004"

  defp access_mode_label("owner"), do: "Owner"
  defp access_mode_label("operator"), do: "Operator"
  defp access_mode_label("wallet_bound"), do: "Agent wallet"
  defp access_mode_label(_value), do: "Accessible"

  defp privy_app_id do
    Application.get_env(:autolaunch, :privy, [])
    |> Keyword.get(:app_id, "")
  end

  defp truthy?(value), do: value in [true, "true", "1", 1, "on", "yes"]

  defp launch_module do
    :autolaunch
    |> Application.get_env(:x_link_live, [])
    |> Keyword.get(:launch_module, Launch)
  end

  defp trust_module do
    :autolaunch
    |> Application.get_env(:x_link_live, [])
    |> Keyword.get(:trust_module, Trust)
  end
end
