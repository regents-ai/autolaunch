defmodule AutolaunchWeb.RegentStakingLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.RegentStaking
  alias AutolaunchWeb.Live.Refreshable
  alias AutolaunchWeb.RegentStakingLive.Presenter

  @poll_ms 15_000

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> Refreshable.schedule(@poll_ms)
     |> Refreshable.subscribe([:regent, :system])
     |> assign(:page_title, "$REGENT Staking")
     |> assign(:active_view, "regent-staking")
     |> assign(:stake_form, default_stake_form())
     |> assign(:resolved_receiver_address, nil)
     |> assign(:unstake_form, %{"amount" => ""})
     |> assign(:pending_actions, %{})
     |> assign(:action_error, nil)
     |> load_staking()}
  end

  def handle_event("stake_changed", %{"stake" => attrs}, socket) do
    form =
      socket.assigns.stake_form
      |> Map.merge(attrs)
      |> stake_form_params()

    {:noreply, assign_stake_form(socket, form)}
  end

  def handle_event("unstake_changed", %{"unstake" => attrs}, socket) do
    {:noreply, assign(socket, :unstake_form, Map.merge(socket.assigns.unstake_form, attrs))}
  end

  def handle_event("prepare_action", %{"action" => action}, socket) do
    {:noreply, prepare_action(socket, action)}
  end

  def handle_event("wallet_tx_started", %{"message" => message}, socket) do
    {:noreply, Refreshable.wallet_started(socket, message)}
  end

  def handle_event("wallet_tx_registered", %{"message" => message}, socket) do
    {:noreply, Refreshable.wallet_registered(socket, message, &load_staking/1)}
  end

  def handle_event("wallet_tx_error", %{"message" => message}, socket) do
    {:noreply, Refreshable.wallet_error(socket, message)}
  end

  def handle_info(:refresh, socket) do
    {:noreply, Refreshable.refresh(socket, @poll_ms, &load_staking/1)}
  end

  def handle_info({:autolaunch_live_update, :changed}, socket) do
    {:noreply, load_staking(socket)}
  end

  def render(assigns) do
    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <.regent_staking_styles />

      <section id="regent-staking-page" class="al-regent-staking">
        <.flash_group flash={@flash} />

        <%= if @action_error do %>
          <p class="al-regent-inline-error" role="alert">{@action_error}</p>
        <% end %>

        <header id="regent-staking-hero" class="al-regent-hero" phx-hook="MissionMotion">
          <div>
            <p class="al-kicker">$REGENT staking</p>
            <h1>Stake for split of protocol stables</h1>
            <p>
              Stake $REGENT, claim USDC from the Regent rewards pool, and earn 20% bonus $REGENT in the first year.
            </p>
          </div>

          <div class={["al-regent-status", @state && @state.paused && "is-paused"]}>
            <span>{if @state && @state.paused, do: "Paused", else: "Live"}</span>
            <strong>{Presenter.chain_label(@state)}</strong>
            <p>{AutolaunchWeb.Format.short_address(@state && @state.contract_address, "No contract configured")}</p>
          </div>
        </header>

        <%= if @state do %>
          <section class="al-regent-metrics" aria-label="$REGENT staking totals">
            <.metric title="Total REGENT staked" value={AutolaunchWeb.Format.display(@state.total_staked)} />
            <.metric title="Total USDC received" value={AutolaunchWeb.Format.display(@state.total_usdc_received)} />
            <.metric title="Direct deposits" value={AutolaunchWeb.Format.display(@state.direct_deposit_usdc)} />
            <.metric title="Treasury USDC" value={AutolaunchWeb.Format.display(@state.treasury_residual_usdc)} />
            <.metric title="Bonus $REGENT available" value={AutolaunchWeb.Format.display(@state.available_reward_inventory)} />
            <.metric title="Outstanding bonus $REGENT" value={AutolaunchWeb.Format.display(@state.materialized_outstanding)} />
          </section>

          <.action_desk
            id="regent-staking-action-desk"
            kicker="Wallet actions"
            title="Stake and claim from one place"
            body="Stake, claim, and restake from the same wallet screen. Your wallet confirms each action."
            status_label={if @state.paused, do: "Paused", else: "Ready"}
            class="al-regent-action-desk"
          >
            <:primary>
              <%= if @pending_actions[:stake] do %>
                <.wallet_tx_button
                  id="regent-stake-primary"
                  class="al-regent-primary-button"
                  wallet_action={@pending_actions[:stake].wallet_action}
                  pending_message="Stake transaction sent. Waiting for confirmation."
                  success_message="Stake confirmed."
                >
                  Send stake transaction
                </.wallet_tx_button>
              <% else %>
                <%= if @current_human do %>
                  <button
                    type="button"
                    class="al-regent-primary-button"
                    phx-click="prepare_action"
                    phx-value-action="stake"
                  >
                    Prepare stake
                  </button>
                <% else %>
                  <.connect_wallet_button id="regent-stake-primary-connect" class="al-regent-primary-button">
                    Connect wallet
                  </.connect_wallet_button>
                <% end %>
              <% end %>
            </:primary>

            <:secondary>
              <%= if @pending_actions[:claim_usdc] do %>
                <.wallet_tx_button
                  id="regent-claim-usdc-primary"
                  class="al-regent-secondary-button"
                  wallet_action={@pending_actions[:claim_usdc].wallet_action}
                  pending_message="USDC claim sent. Waiting for confirmation."
                  success_message="USDC claim confirmed."
                >
                  Send USDC claim
                </.wallet_tx_button>
              <% else %>
                <%= if @current_human do %>
                  <button
                    type="button"
                    class="al-regent-secondary-button"
                    phx-click="prepare_action"
                    phx-value-action="claim_usdc"
                  >
                    Prepare USDC claim
                  </button>
                <% else %>
                  <.connect_wallet_button id="regent-claim-usdc-primary-connect" class="al-regent-secondary-button">
                    Connect wallet
                  </.connect_wallet_button>
                <% end %>
              <% end %>
            </:secondary>

            <:aside>
              <div class="al-regent-wallet-strip">
                <div>
                  <span>Wallet $REGENT</span>
                  <strong>{AutolaunchWeb.Format.display(@state.wallet_token_balance)}</strong>
                </div>
                <div>
                  <span>Staked</span>
                  <strong>{AutolaunchWeb.Format.display(@state.wallet_stake_balance)}</strong>
                </div>
                <div>
                  <span>USDC ready</span>
                  <strong>{AutolaunchWeb.Format.display(@state.wallet_claimable_usdc)}</strong>
                </div>
                <div>
                  <span>Bonus $REGENT ready</span>
                  <strong>{AutolaunchWeb.Format.display(@state.wallet_funded_claimable_regent)}</strong>
                </div>
              </div>
            </:aside>
          </.action_desk>

          <section class="al-regent-action-grid">
            <article class="al-regent-action-card">
              <div>
                <p class="al-kicker">Stake</p>
                <h2>Move $REGENT into staking.</h2>
                <p>Staked $REGENT participates in future deposits to this pool. It does not guarantee yield.</p>
              </div>
              <form phx-change="stake_changed" class="al-regent-form">
                <label for="regent-stake-amount">Amount</label>
                <input id="regent-stake-amount" name="stake[amount]" type="text" inputmode="decimal" value={@stake_form["amount"]} placeholder="0.0" />
                <div class="al-regent-receiver-option">
                  <input type="hidden" name="stake[stake_for_different_address]" value="false" />
                  <label for="regent-stake-different-address">
                    <input
                      id="regent-stake-different-address"
                      type="checkbox"
                      name="stake[stake_for_different_address]"
                      value="true"
                      checked={stake_for_different_address?(@stake_form)}
                    />
                    <span>Stake for another wallet</span>
                  </label>

                  <%= if stake_for_different_address?(@stake_form) do %>
                    <div class="al-regent-receiver-field">
                      <label for="regent-stake-receiver">Receiving wallet</label>
                      <%= if @resolved_receiver_address do %>
                        <p id="regent-stake-resolved-receiver" class="al-regent-resolved-address">
                          {@resolved_receiver_address}
                        </p>
                      <% end %>
                      <input
                        id="regent-stake-receiver"
                        name="stake[receiver]"
                        type="text"
                        value={@stake_form["receiver"]}
                        placeholder="0x... or name.eth"
                        phx-debounce="500"
                        autocomplete="off"
                      />
                    </div>
                  <% else %>
                    <p class="al-regent-receiver-note">Staking to connected wallet</p>
                  <% end %>
                </div>
              </form>
              <.prepared_button
                id="regent-stake"
                action={:stake}
                pending={@pending_actions[:stake]}
                current_human={@current_human}
                class="al-regent-primary-button"
                prepare_label="Prepare stake"
                send_label="Send stake transaction"
                pending_message="Stake transaction sent. Waiting for confirmation."
                success_message="Stake confirmed."
              />
            </article>

            <article class="al-regent-action-card">
              <div>
                <p class="al-kicker">Claims</p>
                <h2>Claim USDC or bonus $REGENT.</h2>
                <p>USDC and bonus $REGENT are shown separately so your available rewards are clear.</p>
              </div>
              <div class="al-regent-split-actions">
                <.prepared_button
                  id="regent-claim-usdc"
                  action={:claim_usdc}
                  pending={@pending_actions[:claim_usdc]}
                  current_human={@current_human}
                  class="al-regent-primary-button"
                  prepare_label="Prepare USDC claim"
                  send_label="Send USDC claim"
                  pending_message="USDC claim sent. Waiting for confirmation."
                  success_message="USDC claim confirmed."
                />
                <.prepared_button
                  id="regent-claim-regent"
                  action={:claim_regent}
                  pending={@pending_actions[:claim_regent]}
                  current_human={@current_human}
                  class="al-regent-secondary-button"
                  prepare_label="Prepare REGENT claim"
                  send_label="Send REGENT claim"
                  pending_message="REGENT claim sent. Waiting for confirmation."
                  success_message="REGENT claim confirmed."
                />
                <.prepared_button
                  id="regent-claim-restake"
                  action={:claim_and_restake_regent}
                  pending={@pending_actions[:claim_and_restake_regent]}
                  current_human={@current_human}
                  class="al-regent-secondary-button"
                  prepare_label="Prepare claim and restake"
                  send_label="Send claim and restake"
                  pending_message="Claim and restake sent. Waiting for confirmation."
                  success_message="Claim and restake confirmed."
                />
              </div>
            </article>

            <article class="al-regent-action-card">
              <div>
                <p class="al-kicker">Unstake</p>
                <h2>Move $REGENT back to your wallet.</h2>
                <p>Unstaking does not claim USDC or bonus $REGENT for you. Claim those separately when needed.</p>
              </div>
              <form phx-change="unstake_changed" class="al-regent-form">
                <label for="regent-unstake-amount">Amount</label>
                <input id="regent-unstake-amount" name="unstake[amount]" type="text" inputmode="decimal" value={@unstake_form["amount"]} placeholder="0.0" />
              </form>
              <.prepared_button
                id="regent-unstake"
                action={:unstake}
                pending={@pending_actions[:unstake]}
                current_human={@current_human}
                class="al-regent-secondary-button"
                prepare_label="Prepare unstake"
                send_label="Send unstake transaction"
                pending_message="Unstake transaction sent. Waiting for confirmation."
                success_message="Unstake confirmed."
              />
            </article>
          </section>

          <section class="al-regent-addresses">
            <div>
              <span>Stake token</span>
              <strong>{@state.stake_token_address}</strong>
            </div>
            <div>
              <span>USDC</span>
              <strong>{@state.usdc_address}</strong>
            </div>
            <div>
              <span>Owner</span>
              <strong>{@state.owner_address}</strong>
            </div>
            <div>
              <span>Treasury recipient</span>
              <strong>{@state.treasury_recipient}</strong>
            </div>
          </section>
        <% else %>
          <section class="al-regent-empty">
            <p class="al-kicker">$REGENT staking</p>
            <h2>Staking is not configured here yet.</h2>
            <p>The page will show live balances and wallet actions after the Regent staking contract is configured.</p>
          </section>
        <% end %>
      </section>
    </.shell>
    """
  end

  attr :title, :string, required: true
  attr :value, :string, required: true

  defp metric(assigns) do
    ~H"""
    <article class="al-regent-metric">
      <span>{@title}</span>
      <strong>{@value}</strong>
    </article>
    """
  end

  attr :id, :string, required: true
  attr :action, :atom, required: true
  attr :pending, :map, default: nil
  attr :current_human, :map, default: nil
  attr :class, :string, required: true
  attr :prepare_label, :string, required: true
  attr :send_label, :string, required: true
  attr :pending_message, :string, required: true
  attr :success_message, :string, required: true

  defp prepared_button(assigns) do
    ~H"""
    <%= if @pending do %>
      <.wallet_tx_button
        id={@id}
        class={@class}
        wallet_action={@pending.wallet_action}
        pending_message={@pending_message}
        success_message={@success_message}
      >
        {@send_label}
      </.wallet_tx_button>
    <% else %>
      <%= if @current_human do %>
        <button id={@id} type="button" class={@class} phx-click="prepare_action" phx-value-action={@action}>
          {@prepare_label}
        </button>
      <% else %>
        <.connect_wallet_button id={"#{@id}-connect"} class={@class}>
          Connect wallet
        </.connect_wallet_button>
      <% end %>
    <% end %>
    """
  end

  attr :id, :string, required: true
  attr :class, :string, required: true
  slot :inner_block, required: true

  defp connect_wallet_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      class={@class}
      phx-click={JS.dispatch("click", to: "#privy-auth [data-privy-action='toggle']")}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp prepare_action(socket, "stake") do
    prepare(socket, :stake, fn human ->
      context_module().stake(stake_action_params(socket.assigns.stake_form), human)
    end)
  end

  defp prepare_action(socket, "unstake") do
    prepare(socket, :unstake, fn human ->
      context_module().unstake(socket.assigns.unstake_form, human)
    end)
  end

  defp prepare_action(socket, "claim_usdc") do
    prepare(socket, :claim_usdc, fn human -> context_module().claim_usdc(%{}, human) end)
  end

  defp prepare_action(socket, "claim_regent") do
    prepare(socket, :claim_regent, fn human -> context_module().claim_regent(%{}, human) end)
  end

  defp prepare_action(socket, "claim_and_restake_regent") do
    prepare(socket, :claim_and_restake_regent, fn human ->
      context_module().claim_and_restake_regent(%{}, human)
    end)
  end

  defp prepare_action(socket, _unknown) do
    put_action_error(socket, "That staking action is not available.")
  end

  defp prepare(socket, key, fun) do
    case fun.(socket.assigns.current_human) do
      {:ok, %{prepared: %{wallet_action: tx_request}} = prepared} ->
        put_pending(socket, key, %{wallet_action: tx_request, prepared: prepared})

      {:error, reason} ->
        put_action_error(socket, Presenter.action_error(reason))
    end
  end

  defp put_pending(socket, key, prepared) do
    socket
    |> assign(:action_error, nil)
    |> assign(:pending_actions, Map.put(socket.assigns.pending_actions, key, prepared))
  end

  defp put_action_error(socket, message) do
    socket
    |> assign(:action_error, message)
    |> put_flash(:error, message)
  end

  defp load_staking(socket) do
    case context_module().overview(socket.assigns.current_human) do
      {:ok, state} ->
        socket
        |> assign(:state, state)
        |> assign(:load_error, nil)

      {:error, reason} ->
        socket
        |> assign(:state, nil)
        |> assign(:load_error, reason)
    end
  end

  defp context_module do
    :autolaunch
    |> Application.get_env(:regent_staking_live, [])
    |> Keyword.get(:context_module, RegentStaking)
  end

  defp default_stake_form do
    %{
      "amount" => "",
      "stake_for_different_address" => "false",
      "receiver" => ""
    }
  end

  defp assign_stake_form(socket, form) do
    socket
    |> assign(:stake_form, form)
    |> assign(:resolved_receiver_address, resolved_receiver_address(form))
  end

  defp stake_form_params(attrs) when is_map(attrs) do
    stake_for_different_address? = stake_for_different_address?(attrs)

    %{
      "amount" => Map.get(attrs, "amount", ""),
      "stake_for_different_address" =>
        if(stake_for_different_address?, do: "true", else: "false"),
      "receiver" => if(stake_for_different_address?, do: Map.get(attrs, "receiver", ""), else: "")
    }
  end

  defp stake_for_different_address?(params) when is_map(params) do
    Map.get(params, "stake_for_different_address") in [true, "true", "on", "1", 1]
  end

  defp stake_for_different_address?(_params), do: false

  defp resolved_receiver_address(params) when is_map(params) do
    if stake_for_different_address?(params) do
      params
      |> Map.get("receiver", "")
      |> resolve_receiver_address()
    end
  end

  defp resolved_receiver_address(_params), do: nil

  defp resolve_receiver_address(receiver) when is_binary(receiver) do
    case RegentStaking.resolve_receiver(receiver) do
      {:ok, address} -> address
      {:error, _reason} -> nil
    end
  end

  defp resolve_receiver_address(_receiver), do: nil

  defp stake_action_params(params) do
    %{
      "amount" => Map.get(params, "amount", ""),
      "receiver" =>
        if(stake_for_different_address?(params), do: Map.get(params, "receiver", ""), else: "")
    }
  end

  defp regent_staking_styles(assigns) do
    ~H"""
    <style>
      .al-regent-staking {
        display: grid;
        gap: 1.35rem;
      }

      .al-regent-hero {
        display: grid;
        grid-template-columns: minmax(0, 1fr) minmax(220px, 320px);
        gap: 1rem;
        align-items: end;
        padding: clamp(1.2rem, 2vw, 2rem);
        border: 1px solid color-mix(in oklab, currentColor 12%, transparent);
        background:
          linear-gradient(135deg, color-mix(in oklab, #315f96 10%, transparent), transparent 42%),
          color-mix(in oklab, var(--fallback-b1, #f8f4ec) 94%, #e7dcc8);
        border-radius: 8px;
      }

      .al-regent-hero h1 {
        margin: 0;
        font-size: clamp(2.1rem, 4vw, 4.6rem);
        line-height: 0.92;
        letter-spacing: 0;
      }

      .al-regent-hero p {
        max-width: 62ch;
        margin: 0.7rem 0 0;
        color: color-mix(in oklab, currentColor 68%, transparent);
      }

      .al-regent-inline-error {
        margin: 0;
        padding: 0.78rem 0.95rem;
        border: 1px solid color-mix(in oklab, #af4b25 30%, transparent);
        background: color-mix(in oklab, #af4b25 10%, transparent);
        border-radius: 6px;
      }

      .al-regent-status {
        padding: 1rem;
        border: 1px solid color-mix(in oklab, #2e7d58 28%, transparent);
        background: color-mix(in oklab, #2e7d58 10%, transparent);
        border-radius: 8px;
      }

      .al-regent-status.is-paused {
        border-color: color-mix(in oklab, #af6a25 34%, transparent);
        background: color-mix(in oklab, #af6a25 12%, transparent);
      }

      .al-regent-status span,
      .al-regent-metric span,
      .al-regent-addresses span,
      .al-regent-wallet-strip span {
        display: block;
        font-size: 0.76rem;
        text-transform: uppercase;
        letter-spacing: 0.08em;
        color: color-mix(in oklab, currentColor 56%, transparent);
      }

      .al-regent-status strong {
        display: block;
        margin-top: 0.25rem;
        font-size: 1.35rem;
      }

      .al-regent-status p {
        margin-top: 0.35rem;
        font-size: 0.92rem;
      }

      .al-regent-metrics {
        display: grid;
        grid-template-columns: repeat(6, minmax(0, 1fr));
        gap: 0.65rem;
      }

      .al-regent-metric,
      .al-regent-action-card,
      .al-regent-addresses,
      .al-regent-empty {
        border: 1px solid color-mix(in oklab, currentColor 11%, transparent);
        background: color-mix(in oklab, var(--fallback-b1, #f8f4ec) 96%, #ffffff);
        border-radius: 8px;
      }

      .al-regent-metric {
        min-height: 96px;
        padding: 0.9rem;
      }

      .al-regent-metric strong {
        display: block;
        margin-top: 0.55rem;
        overflow-wrap: anywhere;
        font-size: clamp(1.1rem, 1.4vw, 1.55rem);
      }

      .al-regent-action-grid {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 1rem;
      }

      .al-regent-action-card {
        display: grid;
        gap: 1rem;
        align-content: start;
        padding: 1rem;
      }

      .al-regent-action-card h2 {
        margin: 0;
        font-size: clamp(1.35rem, 1.9vw, 2rem);
        line-height: 1;
        letter-spacing: 0;
      }

      .al-regent-action-card p {
        margin: 0.5rem 0 0;
        color: color-mix(in oklab, currentColor 64%, transparent);
      }

      .al-regent-form {
        display: grid;
        gap: 0.45rem;
      }

      .al-regent-form label {
        font-size: 0.78rem;
        text-transform: uppercase;
        letter-spacing: 0.08em;
        color: color-mix(in oklab, currentColor 58%, transparent);
      }

      .al-regent-form input {
        min-height: 2.7rem;
        width: 100%;
        border: 1px solid color-mix(in oklab, currentColor 14%, transparent);
        background: color-mix(in oklab, var(--fallback-b1, #f8f4ec) 86%, #ffffff);
        border-radius: 6px;
        padding: 0.7rem 0.8rem;
      }

      .al-regent-receiver-option {
        display: grid;
        gap: 0.65rem;
        margin-top: 0.35rem;
        padding: 0.82rem;
        border: 1px solid color-mix(in srgb, var(--brand-ink) 9%, transparent);
        background: color-mix(in srgb, white 94%, var(--color-bg) 6%);
        border-radius: 0.85rem;
      }

      .al-regent-receiver-option > label {
        display: flex;
        align-items: center;
        gap: 0.55rem;
        color: color-mix(in srgb, var(--brand-ink) 82%, transparent);
      }

      .al-regent-receiver-option input[type="checkbox"] {
        min-height: 1.05rem;
        width: 1.05rem;
        padding: 0;
        border-radius: 0.3rem;
        accent-color: var(--brand-primary);
      }

      .al-regent-receiver-field {
        display: grid;
        gap: 0.45rem;
      }

      .al-regent-receiver-note,
      .al-regent-resolved-address {
        margin: 0;
        overflow-wrap: anywhere;
        color: color-mix(in srgb, var(--brand-ink) 58%, transparent);
        font-size: 0.92rem;
      }

      .al-regent-primary-button,
      .al-regent-secondary-button {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        min-height: 2.7rem;
        border-radius: 6px;
        padding: 0.72rem 0.95rem;
        font-weight: 700;
      }

      .al-regent-primary-button {
        background: #1f4f82;
        color: #fffaf0;
      }

      .al-regent-secondary-button {
        border: 1px solid color-mix(in oklab, currentColor 16%, transparent);
        background: transparent;
      }

      .al-regent-split-actions {
        display: flex;
        flex-wrap: wrap;
        gap: 0.65rem;
      }

      .al-regent-wallet-strip {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 0.65rem;
      }

      .al-regent-wallet-strip div {
        min-width: 0;
        padding: 0.8rem;
        border: 1px solid color-mix(in oklab, currentColor 10%, transparent);
        border-radius: 7px;
      }

      .al-regent-wallet-strip strong,
      .al-regent-addresses strong {
        display: block;
        margin-top: 0.3rem;
        overflow-wrap: anywhere;
      }

      .al-regent-addresses {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 0.8rem;
        padding: 1rem;
      }

      .al-regent-empty {
        padding: 1.2rem;
      }

      .al-regent-hero,
      .al-regent-status,
      .al-regent-metric,
      .al-regent-action-card,
      .al-regent-wallet-strip div,
      .al-regent-addresses,
      .al-regent-empty {
        border-color: color-mix(in srgb, var(--brand-ink) 10%, transparent);
        border-radius: 0.95rem;
        background:
          radial-gradient(circle at 96% 4%, color-mix(in srgb, var(--brand-primary) 7%, transparent), transparent 26%),
          linear-gradient(180deg, color-mix(in srgb, white 98%, var(--color-bg) 2%), color-mix(in srgb, white 93%, var(--color-bg) 7%));
        box-shadow: 0 20px 48px -38px rgba(28, 51, 77, 0.22);
      }

      .al-regent-status,
      .al-regent-status.is-paused {
        background: color-mix(in srgb, white 93%, var(--brand-primary) 7%);
      }

      .al-regent-hero h1,
      .al-regent-status strong,
      .al-regent-metric strong,
      .al-regent-action-card h2,
      .al-regent-wallet-strip strong,
      .al-regent-addresses strong {
        color: color-mix(in srgb, var(--brand-ink) 90%, black 10%);
        letter-spacing: 0;
        overflow-wrap: anywhere;
        text-wrap: balance;
      }

      .al-regent-status,
      .al-regent-metric,
      .al-regent-action-card,
      .al-regent-wallet-strip,
      .al-regent-wallet-strip div,
      .al-regent-addresses,
      .al-regent-addresses div,
      .al-regent-form {
        min-width: 0;
      }

      .al-regent-form label,
      .al-regent-status span,
      .al-regent-metric span,
      .al-regent-addresses span,
      .al-regent-wallet-strip span {
        letter-spacing: 0;
        text-transform: none;
      }

      .al-regent-form input {
        min-height: 2.95rem;
        border-radius: 0.85rem;
        border-color: color-mix(in srgb, var(--brand-ink) 10%, transparent);
        background: color-mix(in srgb, white 96%, var(--color-bg) 4%);
      }

      .al-regent-form input:focus-visible {
        outline: none;
        border-color: color-mix(in srgb, var(--brand-primary) 44%, transparent);
        box-shadow:
          0 0 0 0.22rem color-mix(in srgb, var(--brand-primary) 12%, transparent),
          inset 0 1px 0 rgba(255, 255, 255, 0.7);
      }

      .al-regent-primary-button,
      .al-regent-secondary-button {
        min-width: 0;
        min-height: 2.75rem;
        border-radius: 0.75rem;
        transition:
          transform 160ms cubic-bezier(0.23, 1, 0.32, 1),
          border-color 160ms ease,
          background-color 160ms ease,
          box-shadow 160ms ease,
          color 160ms ease;
      }

      .al-regent-primary-button {
        border: 1px solid color-mix(in srgb, var(--brand-primary) 62%, black 8%);
        background: linear-gradient(
          180deg,
          color-mix(in srgb, var(--brand-primary) 84%, white 16%),
          var(--brand-primary)
        );
      }

      .al-regent-secondary-button {
        border: 1px solid color-mix(in srgb, var(--brand-ink) 9%, transparent);
        background: color-mix(in srgb, white 96%, var(--color-bg) 4%);
      }

      .al-regent-primary-button:active,
      .al-regent-secondary-button:active {
        transform: scale(0.975);
      }

      @media (hover: hover) and (pointer: fine) {
        .al-regent-metric,
        .al-regent-action-card {
          transition:
            transform 180ms cubic-bezier(0.23, 1, 0.32, 1),
            border-color 180ms ease,
            box-shadow 180ms ease,
            background-color 180ms ease;
        }

        .al-regent-metric:hover,
        .al-regent-action-card:hover {
          transform: translateY(-2px);
          border-color: color-mix(in srgb, var(--brand-primary) 18%, transparent);
          box-shadow: 0 24px 52px -42px rgba(21, 96, 66, 0.34);
        }
      }

      @media (max-width: 980px) {
        .al-regent-hero,
        .al-regent-action-grid,
        .al-regent-addresses {
          grid-template-columns: 1fr;
        }

        .al-regent-metrics {
          grid-template-columns: repeat(2, minmax(0, 1fr));
        }
      }

      @media (max-width: 620px) {
        .al-regent-metrics,
        .al-regent-wallet-strip {
          grid-template-columns: 1fr;
        }

        .al-regent-split-actions {
          display: grid;
          grid-template-columns: 1fr;
        }

        .al-regent-primary-button,
        .al-regent-secondary-button {
          width: 100%;
        }
      }
    </style>
    """
  end
end
