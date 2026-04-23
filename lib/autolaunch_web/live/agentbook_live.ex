defmodule AutolaunchWeb.AgentbookLive do
  use AutolaunchWeb, :live_view

  def mount(params, _session, socket) do
    register_form = default_register_form(params)
    lookup_form = default_lookup_form(params)

    {:ok,
     socket
     |> assign(:page_title, "Trust Check")
     |> assign(:active_view, "agentbook")
     |> assign(:register_form, register_form)
     |> assign(:lookup_form, lookup_form)
     |> assign(:launch_job_id, register_form["launch_job_id"])
     |> assign(:active_session, nil)
     |> assign(:lookup_result, nil)
     |> assign(:recent_sessions, context_module().list_recent_sessions())}
  end

  def handle_event("register_changed", %{"register" => attrs}, socket) do
    {:noreply, assign(socket, :register_form, Map.merge(socket.assigns.register_form, attrs))}
  end

  def handle_event("lookup_changed", %{"lookup" => attrs}, socket) do
    {:noreply, assign(socket, :lookup_form, Map.merge(socket.assigns.lookup_form, attrs))}
  end

  def handle_event("create_session", _params, socket) do
    case context_module().create_session(socket.assigns.register_form) do
      {:ok, session} ->
        {:noreply,
         socket
         |> assign(:active_session, session)
         |> assign(:recent_sessions, context_module().list_recent_sessions())
         |> clear_flash()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("lookup_human", _params, socket) do
    case context_module().lookup_human(socket.assigns.lookup_form) do
      {:ok, result} ->
        {:noreply, socket |> assign(:lookup_result, result) |> clear_flash()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event(
        "agentbook_connector_ready",
        %{"session_id" => session_id, "connector_uri" => connector_uri},
        socket
      ) do
    case context_module().store_connector_uri(session_id, connector_uri) do
      {:ok, session} ->
        {:noreply, assign(socket, :active_session, session)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "agentbook_proof_ready",
        %{"session_id" => session_id, "proof" => proof},
        socket
      ) do
    case context_module().submit_session(session_id, %{"proof" => proof}) do
      {:ok, session} ->
        {:noreply, refresh_after_session(socket, session)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event(
        "agentbook_failed",
        %{"session_id" => session_id, "message" => message},
        socket
      ) do
    _ = context_module().fail_session(session_id, message)

    session =
      socket.assigns.active_session &&
        socket.assigns.active_session.session_id == session_id &&
        context_module().get_session(session_id)

    {:noreply,
     socket
     |> assign(:active_session, session || socket.assigns.active_session)
     |> put_flash(:error, message)}
  end

  def handle_event("wallet_tx_started", %{"message" => message}, socket) do
    {:noreply, put_flash(socket, :info, message)}
  end

  def handle_event("wallet_tx_registered", %{"message" => message, "tx_hash" => tx_hash}, socket) do
    session_id = socket.assigns.active_session && socket.assigns.active_session.session_id

    case session_id && context_module().submit_session(session_id, %{"tx_hash" => tx_hash}) do
      {:ok, session} ->
        {:noreply, socket |> refresh_after_session(session) |> put_flash(:info, message)}

      _ ->
        {:noreply, put_flash(socket, :info, message)}
    end
  end

  def handle_event("wallet_tx_error", %{"message" => message}, socket) do
    {:noreply, put_flash(socket, :error, message)}
  end

  def render(assigns) do
    session_json =
      case assigns.active_session do
        nil -> ""
        session -> Jason.encode!(session)
      end

    assigns = assign(assigns, :session_json, session_json)

    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <.identity_page_styles />

      <section class="al-identity-route">
        <header id="agentbook-header" class="al-identity-header" phx-hook="MissionMotion">
          <div class="al-identity-header-copy">
            <.link navigate={~p"/profile"} class="al-identity-back">
              <span aria-hidden="true">←</span>
              <span>Back to profile</span>
            </.link>
            <p class="al-kicker">Profile trust</p>
            <h1>Verify the human behind an agent.</h1>
            <p>
              Start a trust check, finish the registration, and keep a separate lookup panel nearby when you need to confirm an existing record.
            </p>
          </div>

          <div class="al-identity-header-links">
            <.link navigate={~p"/ens-link"} class="al-ghost">Link ENS</.link>
            <.link navigate={~p"/x-link"} class="al-ghost">Connect X</.link>
          </div>
        </header>

        <section id="agentbook-hero" class="al-hero al-panel" phx-hook="MissionMotion">
          <div>
            <p class="al-kicker">Agentbook</p>
            <h2>Public trust check</h2>
            <p class="al-subcopy">
              This flow creates the request, waits for proof, and then helps you finish registration.
            </p>
          </div>

          <div class="al-stat-grid">
            <.stat_card title="Public flow" value="No app login" hint="Works for web pages and CLI callers" />
            <.stat_card title="Submission" value="Relay first" hint="Falls back to wallet send if sponsorship is unavailable" />
            <.stat_card title="Networks" value="World + Base" hint="World mainnet, Base mainnet, and Base Sepolia" />
            <.stat_card title="Lookup" value={lookup_label(@lookup_result)} hint="Reads the live registration record" />
          </div>
        </section>

        <section class="al-agentbook-layout">
        <article class="al-panel al-main-panel">
          <div class="al-section-head">
            <div>
              <p class="al-kicker">Register agent wallet</p>
              <h3>Create a World App trust request</h3>
            </div>
          </div>

          <form phx-change="register_changed" phx-submit="create_session" class="al-form">
            <input
              :if={@register_form["launch_job_id"]}
              type="hidden"
              name="register[launch_job_id]"
              value={@register_form["launch_job_id"]}
            />

            <div class="al-field-grid">
              <label>
                <span>Agent wallet</span>
                <input
                  type="text"
                  name="register[agent_address]"
                  value={@register_form["agent_address"]}
                  placeholder="0x..."
                  autocomplete="off"
                />
              </label>

              <label>
                <span>Network</span>
                <select name="register[network]" value={@register_form["network"]}>
                  <option value="world">World Mainnet</option>
                  <option value="base">Base Mainnet</option>
                  <option value="base-sepolia">Base Sepolia</option>
                </select>
              </label>
            </div>

            <div :if={@launch_job_id} class="al-inline-banner">
              <strong>Launch follow-up</strong>
              <p>
                This registration will be written back to launch job <code>{@launch_job_id}</code> so listings can show the attached trust record and launch count.
              </p>
            </div>

            <div class="al-action-row">
              <button type="submit" class="al-submit">Start verification</button>
            </div>
          </form>

          <div
            id="agentbook-flow"
            class={["al-agentbook-session", @active_session && "is-active"]}
            phx-hook="AgentBookFlow"
            data-session={@session_json}
          >
            <div class="al-agentbook-session-head">
              <div>
                <span>Session status</span>
                <strong>{session_status_label(@active_session)}</strong>
              </div>
              <%= if @active_session do %>
                <span class="al-network-badge">{network_label(@active_session.network)}</span>
              <% end %>
            </div>

            <%= if @active_session do %>
              <div class="al-agentbook-session-grid">
                <div class="al-note-card">
                  <span>Agent wallet</span>
                  <strong>{short_address(@active_session.agent_address)}</strong>
                  <p>Nonce {@active_session.nonce} on {@active_session.contract_address}</p>
                </div>

                <div :if={session_human_id(@active_session)} class="al-note-card">
                  <span>Human ID</span>
                  <strong>{session_human_id(@active_session)}</strong>
                  <p>Stored back onto the launch record after registration.</p>
                </div>

                <div class="al-note-card">
                  <span>Deep link</span>
                  <strong>{if @active_session.deep_link_uri, do: "Ready", else: "Preparing"}</strong>
                  <p id="agentbook-uri-text" data-agentbook-uri-text>
                    {session_uri_copy(@active_session)}
                  </p>
                </div>
              </div>

              <div class="al-agentbook-qr-wrap">
                <div class="al-agentbook-qr-frame" data-agentbook-qr-frame>
                  <img data-agentbook-qr alt="World App connection QR" />
                </div>
                <p class="al-inline-note">
                  Scan in World App or open the deep link directly from this browser.
                </p>
              </div>

              <%= if session_tx_request(@active_session) && @active_session.status == "proof_ready" do %>
                <div class="al-inline-banner">
                  <strong>Wallet confirmation needed</strong>
                  <p>
                    Confirm this registration from your wallet to finish the trust check.
                  </p>
                </div>

                <.wallet_tx_button
                  id="agentbook-register-wallet-tx"
                  class="al-submit"
                  tx_request={session_tx_request(@active_session)}
                  register_endpoint={"/v1/app/agentbook/sessions/#{@active_session.session_id}/submit"}
                  register_body={%{}}
                  pending_message="AgentBook registration sent. Waiting for confirmation."
                  success_message="AgentBook registration confirmed."
                >
                  Send register transaction
                </.wallet_tx_button>
              <% end %>
            <% else %>
              <.empty_state
                title="No active verification yet."
                body="Start a session above to generate a World App request, deep link, and QR code."
              />
            <% end %>
          </div>
        </article>

        <article class="al-panel al-side-panel">
          <div class="al-section-head">
            <div>
              <p class="al-kicker">Lookup existing record</p>
              <h3>Inspect a wallet that may already be registered</h3>
            </div>
          </div>

          <div class="al-inline-banner">
            <strong>Separate job</strong>
            <p>
              Use this side only when you want to inspect an existing trust record. Start a new
              verification from the main panel instead.
            </p>
          </div>

          <form phx-change="lookup_changed" phx-submit="lookup_human" class="al-form">
            <div class="al-field-grid">
              <label>
                <span>Agent wallet</span>
                <input
                  type="text"
                  name="lookup[agent_address]"
                  value={@lookup_form["agent_address"]}
                  placeholder="0x..."
                  autocomplete="off"
                />
              </label>

              <label>
                <span>Network</span>
                <select name="lookup[network]" value={@lookup_form["network"]}>
                  <option value="world">World Mainnet</option>
                  <option value="base">Base Mainnet</option>
                  <option value="base-sepolia">Base Sepolia</option>
                </select>
              </label>
            </div>

            <div class="al-action-row">
              <button type="submit" class="al-submit">Lookup</button>
            </div>
          </form>

          <%= if @lookup_result do %>
            <div class="al-plan-grid">
              <article class="al-note-card">
                <span>Status</span>
                <strong>{if @lookup_result.registered, do: "Registered", else: "Unregistered"}</strong>
                <p>{lookup_detail(@lookup_result)}</p>
              </article>

              <article class="al-note-card">
                <span>Contract</span>
                <strong>{network_label(@lookup_result.network)}</strong>
                <p>{@lookup_result.contract_address}</p>
              </article>
            </div>
          <% end %>

          <div class="al-inline-banner">
            <strong>Recent sessions</strong>
            <p>
              Public session state is persisted so the website and CLI can keep polling even if the Phoenix process restarts.
            </p>
          </div>

          <ul class="al-compact-list">
            <li :for={session <- @recent_sessions}>
              <strong>{short_address(session.agent_address)}</strong>
              <span> · {network_label(session.network)} · {session.status}</span>
            </li>
          </ul>
        </article>
        </section>
      </section>
    </.shell>
    """
  end

  defp identity_page_styles(assigns) do
    ~H"""
    <style>
      .al-identity-route {
        display: grid;
        gap: clamp(1rem, 2vw, 1.5rem);
      }

      .al-identity-header {
        border: 1px solid color-mix(in srgb, var(--al-border) 88%, white 12%);
        background: color-mix(in srgb, var(--al-panel-strong) 94%, white 6%);
        box-shadow: 0 20px 60px -48px rgba(17, 35, 64, 0.2);
        border-radius: 1.5rem;
        padding: clamp(1.1rem, 2.4vw, 1.45rem);
        display: flex;
        justify-content: space-between;
        gap: 1rem;
        align-items: flex-start;
      }

      .al-identity-header-copy,
      .al-identity-header-links {
        display: grid;
        gap: 0.5rem;
      }

      .al-identity-header-copy h1 {
        margin: 0;
        font-size: clamp(2rem, 4vw, 3rem);
        line-height: 0.95;
      }

      .al-identity-header-copy p:not(.al-kicker) {
        margin: 0;
        color: var(--al-muted);
        max-width: 52rem;
      }

      .al-identity-back {
        display: inline-flex;
        align-items: center;
        gap: 0.45rem;
        color: var(--al-muted);
        text-decoration: none;
      }

      .al-identity-header-links {
        justify-items: end;
      }

      @media (max-width: 900px) {
        .al-identity-header {
          flex-direction: column;
        }

        .al-identity-header-links {
          justify-items: start;
          grid-auto-flow: column;
        }
      }
    </style>
    """
  end

  defp refresh_after_session(socket, session) do
    socket
    |> assign(:active_session, session)
    |> assign(:recent_sessions, context_module().list_recent_sessions())
    |> assign(:lookup_result, auto_lookup(session))
  end

  defp auto_lookup(%{status: "registered", agent_address: agent_address, network: network}) do
    case context_module().lookup_human(%{"agent_address" => agent_address, "network" => network}) do
      {:ok, result} -> result
      _ -> nil
    end
  end

  defp auto_lookup(_session), do: nil

  defp session_status_label(nil), do: "Idle"
  defp session_status_label(%{status: "pending"}), do: "Waiting for World App"
  defp session_status_label(%{status: "proof_ready"}), do: "Proof verified"
  defp session_status_label(%{status: "registered"}), do: "Registered"
  defp session_status_label(%{status: "failed"}), do: "Failed"
  defp session_status_label(_session), do: "Unknown"

  defp session_uri_copy(%{deep_link_uri: value}) when is_binary(value) and value != "", do: value
  defp session_uri_copy(_session), do: "The browser is preparing the World App request."

  defp lookup_label(%{registered: true}), do: "Registered"
  defp lookup_label(%{registered: false}), do: "Unregistered"
  defp lookup_label(_value), do: "Unchecked"

  defp lookup_detail(%{registered: true, human_id: human_id}), do: "Human identifier #{human_id}"
  defp lookup_detail(_value), do: "No human-backed registration found for this wallet."

  defp network_label("world"), do: "World Mainnet"
  defp network_label("base"), do: "Base Mainnet"
  defp network_label("base-sepolia"), do: "Base Sepolia"
  defp network_label(value), do: to_string(value)

  defp short_address(nil), do: "unknown"

  defp short_address(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "0x" <> rest when byte_size(rest) > 10 ->
        "0x" <> String.slice(rest, 0, 4) <> "…" <> String.slice(rest, -4, 4)

      trimmed ->
        trimmed
    end
  end

  defp error_message(%AgentWorld.Error{} = error), do: error.message
  defp error_message(error) when is_binary(error), do: error
  defp error_message(error), do: inspect(error)

  defp session_tx_request(session) when is_map(session) do
    Map.get(session, :tx_request)
  end

  defp session_tx_request(_session), do: nil

  defp session_human_id(session) when is_map(session) do
    Map.get(session, :human_id)
  end

  defp session_human_id(_session), do: nil

  defp default_register_form(params) do
    %{
      "agent_address" => Map.get(params, "agent_address", ""),
      "network" => Map.get(params, "network", "world"),
      "launch_job_id" => Map.get(params, "launch_job_id", "")
    }
  end

  defp default_lookup_form(params) do
    %{
      "agent_address" => Map.get(params, "agent_address", ""),
      "network" => Map.get(params, "network", "world")
    }
  end

  defp context_module do
    Application.get_env(:autolaunch, :agentbook_live, [])
    |> Keyword.get(:context_module, Autolaunch.Agentbook)
  end
end
