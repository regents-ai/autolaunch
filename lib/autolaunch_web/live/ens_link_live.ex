defmodule AutolaunchWeb.EnsLinkLive do
  use AutolaunchWeb, :live_view

  alias AgentEns.Error
  alias Autolaunch.EnsLink
  alias Autolaunch.Launch

  def mount(params, _session, socket) do
    identities = list_identities(socket.assigns[:current_human])
    selected_identity = selected_identity_from_params(identities, params)
    form = default_form(selected_identity, params)

    {:ok,
     socket
     |> assign(:page_title, "ENS Link")
     |> assign(:active_view, "ens")
     |> assign(:identities, identities)
     |> assign(:selected_identity_id, selected_identity_id(selected_identity))
     |> assign(:selected_identity, selected_identity)
     |> assign(:form, form)
     |> assign(:prepared, nil)}
  end

  def handle_event("select_identity", %{"agent_id" => agent_id}, socket) do
    selected_identity = find_identity(socket.assigns.identities, agent_id)
    form = default_form(selected_identity, %{})

    {:noreply,
     socket
     |> assign(:selected_identity_id, selected_identity_id(selected_identity))
     |> assign(:selected_identity, selected_identity)
     |> assign(:form, form)
     |> assign(:prepared, nil)}
  end

  def handle_event("form_changed", %{"ens_link" => attrs}, socket) do
    form =
      socket.assigns.form
      |> Map.merge(attrs)
      |> normalize_checkbox()

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("plan_link", _params, socket) do
    case prepare_bidirectional(socket) do
      {:ok, prepared} ->
        {:noreply, socket |> assign(:prepared, prepared) |> clear_flash()}

      {:error, message} ->
        {:noreply, socket |> assign(:prepared, nil) |> put_flash(:error, message)}
    end
  end

  def handle_event("wallet_tx_started", %{"message" => message}, socket) do
    {:noreply, put_flash(socket, :info, message)}
  end

  def handle_event("wallet_tx_registered", %{"message" => message}, socket) do
    socket =
      case prepare_bidirectional(socket) do
        {:ok, prepared} -> assign(socket, :prepared, prepared)
        {:error, _message} -> assign(socket, :prepared, nil)
      end

    {:noreply, put_flash(socket, :info, message)}
  end

  def handle_event("wallet_tx_error", %{"message" => message}, socket) do
    {:noreply, put_flash(socket, :error, message)}
  end

  def render(assigns) do
    ready_actions = ready_action_count(assigns.prepared)
    verified? = match?(%{plan: %{verify_status: :verified}}, assigns.prepared)
    ens_synced? = match?(%{plan: %{erc8004_status: :ens_service_present}}, assigns.prepared)

    assigns =
      assigns
      |> assign(:ready_actions, ready_actions)
      |> assign(:verified?, verified?)
      |> assign(:ens_synced?, ens_synced?)

    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <.identity_page_styles />

      <section class="al-identity-route">
        <header id="ens-link-header" class="al-identity-header" phx-hook="MissionMotion">
          <div class="al-identity-header-copy">
            <.link navigate={~p"/profile"} class="al-identity-back">
              <span aria-hidden="true">←</span>
              <span>Back to profile</span>
            </.link>
            <p class="al-kicker">Profile trust</p>
            <h1>Link the ENS name people should trust.</h1>
            <p>
              Pick the right identity, check what is already in place, and only send the missing name updates.
            </p>
          </div>

          <div class="al-identity-header-links">
            <.link navigate={~p"/agentbook"} class="al-ghost">Open Agentbook</.link>
            <.link navigate={~p"/x-link"} class="al-ghost">Connect X</.link>
          </div>
        </header>

        <section id="ens-link-hero" class="al-hero al-panel" phx-hook="MissionMotion">
          <div>
            <p class="al-kicker">ENS</p>
            <h2>Choose an identity, choose an ENS name, then send only the missing writes.</h2>
            <p class="al-subcopy">
              This page checks the ENS side and the ERC-8004 side separately, then prepares only the
              wallet actions that still need to happen.
            </p>
          </div>

          <div class="al-stat-grid">
            <.stat_card title="Identities" value={Integer.to_string(length(@identities))} hint="Owned or operated by linked wallets" />
            <.stat_card title="Actionable writes" value={Integer.to_string(@ready_actions)} hint="Only counted after you run a plan" />
            <.stat_card title="ENS record" value={if @verified?, do: "Verified", else: "Unchecked"} hint="ENSIP-25 text record" />
            <.stat_card title="ERC-8004 file" value={if @ens_synced?, do: "Synced", else: "Unchecked"} hint="Registration file ENS service" />
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
                title="Sign in with Privy before planning ENS links."
                body="The planner uses the wallets linked to your current session to decide whether the ENS name and the ERC-8004 identity are writable."
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
                      <span class="al-network-badge">{short_address(identity.owner_address)}</span>
                    </div>

                    <p class="al-inline-note">
                      {identity.ens || "No ENS claim in the registration file yet."}
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
              <h3>Choose the ENS name</h3>
            </div>
          </div>

          <form phx-change="form_changed" phx-submit="plan_link" class="al-form">
            <div class="al-field-grid">
              <label>
                <span>ENS name</span>
                <input
                  type="text"
                  name="ens_link[ens_name]"
                  value={@form["ens_name"]}
                  placeholder="alice.eth"
                  autocomplete="off"
                />
              </label>

              <label class="al-check-item al-check-item--toggle">
                <input
                  type="checkbox"
                  name="ens_link[include_reverse]"
                  value="true"
                  checked={truthy?(@form["include_reverse"])}
                />
                <div>
                  <strong>Also prepare reverse name</strong>
                  <p>Optional. This adds a primary-name transaction when the network supports it.</p>
                </div>
              </label>
            </div>

            <div
              :if={@selected_identity_id && @form["ens_name"] not in [nil, ""]}
              class="al-inline-banner"
            >
              <strong>Launch follow-up</strong>
              <p>
                This planner is preloaded from the launch checklist. Review the missing writes, then send only the wallet actions that are still needed.
              </p>
            </div>

            <div class="al-action-row">
              <button type="submit" class="al-submit" disabled={is_nil(@selected_identity)}>
                Plan link actions
              </button>
            </div>
          </form>

          <%= if @selected_identity do %>
            <div class="al-inline-banner">
              <strong>Signer wallet</strong>
              <p>
                The planner uses one of the wallets linked to your Privy session. If that wallet is not the ENS manager or the ERC-8004 owner/operator, the relevant action will be blocked.
              </p>
            </div>
          <% end %>
        </article>
      </section>

      <%= if @prepared do %>
        <section class="al-ens-plan-layout">
          <article class="al-panel al-main-panel">
            <div class="al-section-head">
              <div>
                <p class="al-kicker">Plan</p>
                <h3>Current link state</h3>
              </div>
            </div>

            <div class="al-plan-grid">
              <article class="al-note-card">
                <span>ENSIP-25</span>
                <strong>{humanize_plan_status(@prepared.plan.verify_status)}</strong>
                <p>{verify_status_copy(@prepared.plan.verify_status)}</p>
              </article>

              <article class="al-note-card">
                <span>ERC-8004 file</span>
                <strong>{humanize_plan_status(@prepared.plan.erc8004_status)}</strong>
                <p>{erc8004_status_copy(@prepared.plan.erc8004_status)}</p>
              </article>

              <article class="al-note-card">
                <span>ENS write access</span>
                <strong>{humanize_plan_status(@prepared.plan.ens_write_status)}</strong>
                <p>{write_status_copy(@prepared.plan.ens_write_status)}</p>
              </article>

              <article class="al-note-card">
                <span>ERC-8004 write access</span>
                <strong>{humanize_plan_status(@prepared.plan.erc8004_write_status)}</strong>
                <p>{erc8004_write_status_copy(@prepared.plan.erc8004_write_status)}</p>
              </article>
            </div>

            <div class="al-review-grid">
              <article class="al-review-card">
                <span>ENS name</span>
                <strong>{@prepared.plan.normalized_ens_name}</strong>
                <p>Planner-normalized name used for hashing and record lookup.</p>
              </article>

              <article class="al-review-card">
                <span>Record key</span>
                <strong>{@prepared.plan.ensip25_key}</strong>
                <p>ENSIP-25 text key that proves the link back to the ERC-8004 registry entry.</p>
              </article>

              <article class="al-review-card">
                <span>ENS manager</span>
                <strong>{short_address(@prepared.plan.ens_manager)}</strong>
                <p>{manager_source_copy(@prepared.plan.ens_manager_source)}</p>
              </article>

              <article class="al-review-card">
                <span>Signer</span>
                <strong>{short_address(@prepared.plan.signer_address)}</strong>
                <p>Current linked wallet the planner evaluated for write permissions.</p>
              </article>
            </div>

            <%= if @prepared.plan.warnings != [] do %>
              <ul class="al-compact-list">
                <li :for={warning <- @prepared.plan.warnings}>{warning}</li>
              </ul>
            <% end %>
          </article>

          <article class="al-panel al-side-panel">
            <div class="al-section-head">
              <div>
                <p class="al-kicker">Step 3</p>
                <h3>Run the missing writes</h3>
              </div>
            </div>

            <div class="al-ens-action-stack">
              <.ens_action_card
                title="Update the ERC-8004 registration"
                action={action_for(@prepared.plan, :update_erc8004_registration)}
                tx_request={tx_request_for(@prepared.erc8004)}
                pending_message="ERC-8004 update sent. Waiting for confirmation."
                success_message="ERC-8004 registration updated. Rechecking the link."
              />

              <.ens_action_card
                title="Set the ENSIP-25 text record"
                action={action_for(@prepared.plan, :set_ens_text)}
                tx_request={tx_request_for(@prepared.ensip25)}
                pending_message="ENS write sent. Waiting for confirmation."
                success_message="ENS text record updated. Rechecking the link."
              />

              <.ens_action_card
                title="Set the primary name"
                action={action_for(@prepared.plan, :set_reverse_name)}
                tx_request={tx_request_for(@prepared.reverse)}
                pending_message="Primary-name update sent. Waiting for confirmation."
                success_message="Primary name updated. Rechecking the link."
              />
            </div>
          </article>
        </section>
      <% end %>
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

  attr :title, :string, required: true
  attr :action, :map, default: nil
  attr :tx_request, :map, default: nil
  attr :pending_message, :string, required: true
  attr :success_message, :string, required: true

  defp ens_action_card(assigns) do
    ~H"""
    <article class="al-note-card al-ens-action-card">
      <span>{@title}</span>
      <strong>{humanize_plan_status(@action && @action.status)}</strong>
      <p>{action_copy(@action)}</p>

      <%= cond do %>
        <% @tx_request -> %>
          <.wallet_tx_button
            id={"ens-action-#{slugify(@title)}"}
            class="al-submit"
            tx_request={@tx_request}
            pending_message={@pending_message}
            success_message={@success_message}
          >
            Send from wallet
          </.wallet_tx_button>
        <% @action && @action.status == :noop -> %>
          <div class="al-muted-box">Already complete.</div>
        <% @action && @action.status == :blocked -> %>
          <div class="al-muted-box">{blocked_reason_copy(@action.reason)}</div>
        <% @action && @action.status == :skipped -> %>
          <div class="al-muted-box">Skipped for this plan.</div>
        <% true -> %>
          <div class="al-muted-box">Run a plan to prepare this action.</div>
      <% end %>
    </article>
    """
  end

  defp list_identities(nil), do: []
  defp list_identities(current_human), do: launch_module().list_agents(current_human)

  defp default_identity(identities) do
    Enum.find(identities, &(&1.state in ["eligible", "wallet_bound"])) || List.first(identities)
  end

  defp default_form(identity, params) do
    %{
      "ens_name" => Map.get(params, "ens_name") || default_ens_name(identity),
      "include_reverse" => false
    }
  end

  defp selected_identity_from_params(identities, params) do
    requested_identity_id = Map.get(params, "identity_id")

    Enum.find(identities, &(&1.agent_id == requested_identity_id)) || default_identity(identities)
  end

  defp selected_identity_id(nil), do: nil
  defp selected_identity_id(identity), do: identity.agent_id

  defp default_ens_name(nil), do: ""
  defp default_ens_name(identity), do: identity.ens || ""

  defp normalize_checkbox(form) do
    Map.put(form, "include_reverse", truthy?(form["include_reverse"]))
  end

  defp prepare_bidirectional(socket) do
    with {:ok, current_human} <- ensure_current_human(socket.assigns.current_human),
         {:ok, identity} <- ensure_selected_identity(socket.assigns.selected_identity),
         {:ok, ens_name} <- ens_name_from_form(socket.assigns.form),
         {:ok, prepared} <-
           ens_link_module().prepare_bidirectional_link(current_human, %{
             "identity_id" => identity.agent_id,
             "ens_name" => ens_name,
             "include_reverse" => truthy?(socket.assigns.form["include_reverse"])
           }) do
      {:ok, prepared}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, %Error{} = error} -> {:error, Exception.message(error)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp ensure_current_human(nil), do: {:error, "Sign in with Privy first."}
  defp ensure_current_human(current_human), do: {:ok, current_human}

  defp ensure_selected_identity(nil), do: {:error, "Choose an ERC-8004 identity first."}
  defp ensure_selected_identity(identity), do: {:ok, identity}

  defp ens_name_from_form(form) do
    case String.trim(form["ens_name"] || "") do
      "" -> {:error, "Enter an ENS name first."}
      ens_name -> {:ok, ens_name}
    end
  end

  defp find_identity(identities, agent_id), do: Enum.find(identities, &(&1.agent_id == agent_id))

  defp ready_action_count(%{plan: %{actions: actions}}),
    do: Enum.count(actions, &(&1.status == :ready))

  defp ready_action_count(_prepared), do: 0

  defp tx_request_for(%{tx: tx}), do: tx
  defp tx_request_for(_value), do: nil

  defp action_for(%{actions: actions}, kind), do: Enum.find(actions, &(&1.kind == kind))
  defp action_for(_plan, _kind), do: nil

  defp network_label(identity) do
    case Enum.find(identity.supported_chains || [], &(&1.id == identity.chain_id)) do
      %{label: label} -> label
      _ -> "Ethereum"
    end
  end

  defp access_mode_label("owner"), do: "Owner controlled"
  defp access_mode_label("operator"), do: "Operator controlled"
  defp access_mode_label("wallet_bound"), do: "Wallet-bound only"
  defp access_mode_label(_mode), do: "Unknown"

  defp short_address(nil), do: "Unknown"

  defp short_address(value) when is_binary(value) and byte_size(value) > 12 do
    String.slice(value, 0, 6) <> "..." <> String.slice(value, -4, 4)
  end

  defp short_address(value), do: value || "Unknown"

  defp humanize_plan_status(nil), do: "Not prepared"

  defp humanize_plan_status(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp verify_status_copy(:verified),
    do: "The ENS text record already points back to this ERC-8004 identity."

  defp verify_status_copy(:ens_record_missing),
    do: "The ENS name does not yet carry the bidirectional proof record."

  defp verify_status_copy(_), do: "Planner state is unavailable."

  defp erc8004_status_copy(:ens_service_present),
    do: "The ERC-8004 registration file already advertises this ENS name."

  defp erc8004_status_copy(:ens_service_missing),
    do: "The ERC-8004 registration file does not list an ENS service yet."

  defp erc8004_status_copy(:ens_service_mismatch),
    do: "The ERC-8004 registration file points at a different ENS name."

  defp erc8004_status_copy(_), do: "Planner state is unavailable."

  defp write_status_copy(:ready), do: "This linked signer can write the ENS text record."
  defp write_status_copy(:no_resolver), do: "The ENS name has no resolver configured yet."

  defp write_status_copy(:resolver_unsupported),
    do: "The resolver does not expose the onchain text-write interface."

  defp write_status_copy(:unsupported_offchain_resolver),
    do: "The resolver looks offchain-only, so this app does not prepare writes for it."

  defp write_status_copy(:manager_mismatch),
    do: "A different wallet currently controls the ENS manager role."

  defp write_status_copy(:signer_required),
    do: "Sign in with a linked wallet before writing ENS records."

  defp write_status_copy(_), do: "Planner state is unavailable."

  defp erc8004_write_status_copy(:ready),
    do: "This linked signer can update the ERC-8004 token URI."

  defp erc8004_write_status_copy(:forbidden),
    do: "A different wallet controls ERC-8004 write access for this identity."

  defp erc8004_write_status_copy(:signer_required),
    do: "Sign in with a linked wallet before updating ERC-8004."

  defp erc8004_write_status_copy(_), do: "Planner state is unavailable."

  defp manager_source_copy(:name_wrapper_owner),
    do: "Manager was resolved through the ENS Name Wrapper."

  defp manager_source_copy(:registry_owner),
    do: "Manager was resolved directly from the ENS registry."

  defp manager_source_copy(_), do: "Manager source is unavailable."

  defp action_copy(%{status: :ready, description: description}), do: description

  defp action_copy(%{status: :noop}),
    do: "Nothing to do. This side of the link is already satisfied."

  defp action_copy(%{status: :blocked, reason: reason}), do: blocked_reason_copy(reason)

  defp action_copy(%{status: :skipped}),
    do: "This optional step was not requested in the current plan."

  defp action_copy(_), do: "Run a plan to see what this action needs."

  defp blocked_reason_copy(:manager_mismatch), do: "Use the ENS manager wallet for this name."

  defp blocked_reason_copy(:resolver_unsupported),
    do: "Move the name to a resolver that supports onchain text records."

  defp blocked_reason_copy(:unsupported_offchain_resolver),
    do: "This resolver is offchain-only, so the app will not write to it."

  defp blocked_reason_copy(:no_resolver), do: "Set a resolver on the ENS name first."

  defp blocked_reason_copy(:forbidden),
    do: "Use the ERC-8004 owner or an approved operator wallet."

  defp blocked_reason_copy(:signer_required), do: "Sign in with a linked wallet first."
  defp blocked_reason_copy(reason) when is_atom(reason), do: humanize_plan_status(reason)
  defp blocked_reason_copy(_reason), do: "This action is blocked."

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  defp truthy?(value), do: value in [true, "true", "1", 1, "on"]

  defp launch_module do
    Application.get_env(:autolaunch, :ens_link_live, [])
    |> Keyword.get(:launch_module, Launch)
  end

  defp ens_link_module do
    Application.get_env(:autolaunch, :ens_link_live, [])
    |> Keyword.get(:ens_link_module, EnsLink)
  end
end
