defmodule AutolaunchWeb.RegentStakingLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.RegentStaking
  alias AutolaunchWeb.Live.Refreshable

  @poll_ms 15_000

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> Refreshable.schedule(@poll_ms)
     |> Refreshable.subscribe([:regent, :system])
     |> assign(:page_title, "$REGENT Staking")
     |> assign(:active_view, "regent-staking")
     |> assign(:stake_form, %{"amount" => ""})
     |> assign(:unstake_form, %{"amount" => ""})
     |> assign(:deposit_form, %{
       "amount" => "",
       "source_tag" => "manual",
       "source_ref" => "regent-staking"
     })
     |> assign(:treasury_form, %{"amount" => "", "recipient" => ""})
     |> assign(:pending_actions, %{})
     |> assign(:action_error, nil)
     |> load_staking()}
  end

  def handle_event("stake_changed", %{"stake" => attrs}, socket) do
    {:noreply, assign(socket, :stake_form, Map.merge(socket.assigns.stake_form, attrs))}
  end

  def handle_event("unstake_changed", %{"unstake" => attrs}, socket) do
    {:noreply, assign(socket, :unstake_form, Map.merge(socket.assigns.unstake_form, attrs))}
  end

  def handle_event("deposit_changed", %{"deposit" => attrs}, socket) do
    {:noreply, assign(socket, :deposit_form, Map.merge(socket.assigns.deposit_form, attrs))}
  end

  def handle_event("treasury_changed", %{"treasury" => attrs}, socket) do
    {:noreply, assign(socket, :treasury_form, Map.merge(socket.assigns.treasury_form, attrs))}
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
            <h1>Company rewards rail</h1>
            <p>
              Stake REGENT, claim USDC, and claim funded REGENT rewards from the standalone Regent contract.
            </p>
          </div>

          <div class={["al-regent-status", @state && @state.paused && "is-paused"]}>
            <span>{if @state && @state.paused, do: "Paused", else: "Live"}</span>
            <strong>{chain_label(@state)}</strong>
            <p>{short_address(@state && @state.contract_address)}</p>
          </div>
        </header>

        <%= if @state do %>
          <section class="al-regent-metrics" aria-label="$REGENT staking totals">
            <.metric title="Total REGENT staked" value={display(@state.total_staked)} />
            <.metric title="Total USDC received" value={display(@state.total_usdc_received)} />
            <.metric title="Direct deposits" value={display(@state.direct_deposit_usdc)} />
            <.metric title="Treasury USDC" value={display(@state.treasury_residual_usdc)} />
            <.metric title="Funded REGENT rewards" value={display(@state.available_reward_inventory)} />
            <.metric title="Outstanding REGENT" value={display(@state.materialized_outstanding)} />
          </section>

          <.action_desk
            id="regent-staking-action-desk"
            kicker="Wallet actions"
            title="Stake and claim from one place"
            body="This page prepares transactions for the unique $REGENT staking contract. Your wallet signs each action."
            status_label={if @state.paused, do: "Paused", else: "Ready"}
            class="al-regent-action-desk"
          >
            <:primary>
              <%= if @pending_actions[:stake] do %>
                <.wallet_tx_button
                  id="regent-stake-primary"
                  class="al-regent-primary-button"
                  tx_request={@pending_actions[:stake].tx_request}
                  pending_message="Stake transaction sent. Waiting for confirmation."
                  success_message="Stake confirmed."
                >
                  Send stake transaction
                </.wallet_tx_button>
              <% else %>
                <button
                  type="button"
                  class="al-regent-primary-button"
                  phx-click="prepare_action"
                  phx-value-action="stake"
                >
                  Prepare stake
                </button>
              <% end %>
            </:primary>

            <:secondary>
              <%= if @pending_actions[:claim_usdc] do %>
                <.wallet_tx_button
                  id="regent-claim-usdc-primary"
                  class="al-regent-secondary-button"
                  tx_request={@pending_actions[:claim_usdc].tx_request}
                  pending_message="USDC claim sent. Waiting for confirmation."
                  success_message="USDC claim confirmed."
                >
                  Send USDC claim
                </.wallet_tx_button>
              <% else %>
                <button
                  type="button"
                  class="al-regent-secondary-button"
                  phx-click="prepare_action"
                  phx-value-action="claim_usdc"
                >
                  Prepare USDC claim
                </button>
              <% end %>
            </:secondary>

            <:aside>
              <div class="al-regent-wallet-strip">
                <div>
                  <span>Wallet REGENT</span>
                  <strong>{display(@state.wallet_token_balance)}</strong>
                </div>
                <div>
                  <span>Staked</span>
                  <strong>{display(@state.wallet_stake_balance)}</strong>
                </div>
                <div>
                  <span>USDC ready</span>
                  <strong>{display(@state.wallet_claimable_usdc)}</strong>
                </div>
                <div>
                  <span>Funded rewards</span>
                  <strong>{display(@state.wallet_funded_claimable_regent)}</strong>
                </div>
              </div>
            </:aside>
          </.action_desk>

          <section class="al-regent-action-grid">
            <article class="al-regent-action-card">
              <div>
                <p class="al-kicker">Stake</p>
                <h2>Move REGENT into staking.</h2>
                <p>Staked REGENT participates in future USDC deposits and funded reward claims.</p>
              </div>
              <form phx-change="stake_changed" class="al-regent-form">
                <label for="regent-stake-amount">Amount</label>
                <input id="regent-stake-amount" name="stake[amount]" type="text" inputmode="decimal" value={@stake_form["amount"]} placeholder="0.0" />
              </form>
              <.prepared_button
                id="regent-stake"
                action={:stake}
                pending={@pending_actions[:stake]}
                class="al-regent-primary-button"
                prepare_label="Prepare stake"
                send_label="Send stake transaction"
                pending_message="Stake transaction sent. Waiting for confirmation."
                success_message="Stake confirmed."
              />
            </article>

            <article class="al-regent-action-card">
              <div>
                <p class="al-kicker">Unstake</p>
                <h2>Move REGENT back to your wallet.</h2>
                <p>Unstaking does not claim USDC or funded rewards for you. Claim those separately when needed.</p>
              </div>
              <form phx-change="unstake_changed" class="al-regent-form">
                <label for="regent-unstake-amount">Amount</label>
                <input id="regent-unstake-amount" name="unstake[amount]" type="text" inputmode="decimal" value={@unstake_form["amount"]} placeholder="0.0" />
              </form>
              <.prepared_button
                id="regent-unstake"
                action={:unstake}
                pending={@pending_actions[:unstake]}
                class="al-regent-secondary-button"
                prepare_label="Prepare unstake"
                send_label="Send unstake transaction"
                pending_message="Unstake transaction sent. Waiting for confirmation."
                success_message="Unstake confirmed."
              />
            </article>

            <article class="al-regent-action-card">
              <div>
                <p class="al-kicker">Claims</p>
                <h2>Claim USDC or funded REGENT rewards.</h2>
                <p>Accrued rewards and funded rewards are shown separately so claimable inventory is clear.</p>
              </div>
              <div class="al-regent-split-actions">
                <.prepared_button
                  id="regent-claim-usdc"
                  action={:claim_usdc}
                  pending={@pending_actions[:claim_usdc]}
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
                  class="al-regent-secondary-button"
                  prepare_label="Prepare claim and restake"
                  send_label="Send claim and restake"
                  pending_message="Claim and restake sent. Waiting for confirmation."
                  success_message="Claim and restake confirmed."
                />
              </div>
            </article>

            <article class="al-regent-action-card is-operator">
              <div>
                <p class="al-kicker">Treasury</p>
                <h2>Prepare operator funding and withdrawal.</h2>
                <p>These actions are for funding the company rail and moving treasury USDC to the configured recipient.</p>
              </div>
              <form phx-change="deposit_changed" class="al-regent-form">
                <label for="regent-deposit-amount">USDC deposit amount</label>
                <input id="regent-deposit-amount" name="deposit[amount]" type="text" inputmode="decimal" value={@deposit_form["amount"]} placeholder="0.0" />
                <label for="regent-deposit-source-tag">Source label</label>
                <input id="regent-deposit-source-tag" name="deposit[source_tag]" type="text" value={@deposit_form["source_tag"]} />
                <label for="regent-deposit-source-ref">Source reference</label>
                <input id="regent-deposit-source-ref" name="deposit[source_ref]" type="text" value={@deposit_form["source_ref"]} />
              </form>
              <form phx-change="treasury_changed" class="al-regent-form">
                <label for="regent-treasury-amount">Treasury withdrawal amount</label>
                <input id="regent-treasury-amount" name="treasury[amount]" type="text" inputmode="decimal" value={@treasury_form["amount"]} placeholder="0.0" />
                <label for="regent-treasury-recipient">Recipient</label>
                <input id="regent-treasury-recipient" name="treasury[recipient]" type="text" value={@treasury_form["recipient"]} placeholder={@state.treasury_recipient} />
              </form>
              <div class="al-regent-split-actions">
                <.prepared_button
                  id="regent-deposit-usdc"
                  action={:deposit_usdc}
                  pending={@pending_actions[:deposit_usdc]}
                  class="al-regent-primary-button"
                  prepare_label="Prepare USDC deposit"
                  send_label="Send USDC deposit"
                  pending_message="USDC deposit sent. Waiting for confirmation."
                  success_message="USDC deposit confirmed."
                />
                <.prepared_button
                  id="regent-withdraw-treasury"
                  action={:withdraw_treasury}
                  pending={@pending_actions[:withdraw_treasury]}
                  class="al-regent-secondary-button"
                  prepare_label="Prepare treasury withdrawal"
                  send_label="Send treasury withdrawal"
                  pending_message="Treasury withdrawal sent. Waiting for confirmation."
                  success_message="Treasury withdrawal confirmed."
                />
              </div>
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
        tx_request={@pending.tx_request}
        pending_message={@pending_message}
        success_message={@success_message}
      >
        {@send_label}
      </.wallet_tx_button>
    <% else %>
      <button id={@id} type="button" class={@class} phx-click="prepare_action" phx-value-action={@action}>
        {@prepare_label}
      </button>
    <% end %>
    """
  end

  defp prepare_action(socket, "stake") do
    prepare(socket, :stake, fn human ->
      context_module().stake(socket.assigns.stake_form, human)
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

  defp prepare_action(socket, "deposit_usdc") do
    prepare_operator_action(socket, :deposit_usdc, fn ->
      context_module().prepare_deposit_usdc(socket.assigns.deposit_form)
    end)
  end

  defp prepare_action(socket, "withdraw_treasury") do
    prepare_operator_action(socket, :withdraw_treasury, fn ->
      context_module().prepare_withdraw_treasury(socket.assigns.treasury_form)
    end)
  end

  defp prepare_action(socket, _unknown) do
    put_action_error(socket, "That staking action is not available.")
  end

  defp prepare(socket, key, fun) do
    case fun.(socket.assigns.current_human) do
      {:ok, %{tx_request: tx_request}} ->
        put_pending(socket, key, %{tx_request: tx_request})

      {:ok, %{prepared: %{tx_request: tx_request}} = prepared} ->
        put_pending(socket, key, %{tx_request: tx_request, prepared: prepared})

      {:error, reason} ->
        put_action_error(socket, action_error(reason))
    end
  end

  defp prepare_operator_action(%{assigns: %{current_human: nil}} = socket, _key, _fun) do
    put_action_error(socket, action_error(:unauthorized))
  end

  defp prepare_operator_action(socket, key, fun) do
    case fun.() do
      {:ok, %{tx_request: tx_request}} ->
        put_pending(socket, key, %{tx_request: tx_request})

      {:ok, %{prepared: %{tx_request: tx_request}} = prepared} ->
        put_pending(socket, key, %{tx_request: tx_request, prepared: prepared})

      {:error, reason} ->
        put_action_error(socket, action_error(reason))
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

  defp action_error(:unauthorized), do: "Connect a wallet first."
  defp action_error(:unconfigured), do: "Regent staking is not configured here yet."
  defp action_error(:amount_required), do: "Enter an amount first."
  defp action_error(:invalid_amount_precision), do: "Amount precision is too high."
  defp action_error(:invalid_address), do: "Address is invalid."
  defp action_error(:source_tag_required), do: "Source label is required."
  defp action_error(:source_ref_required), do: "Source reference is required."
  defp action_error(:invalid_source_ref), do: "Source label or reference is invalid."
  defp action_error(_reason), do: "Staking action could not be prepared."

  defp chain_label(nil), do: "Not configured"
  defp chain_label(%{chain_label: label}) when is_binary(label), do: label
  defp chain_label(_state), do: "Base"

  defp display(nil), do: "-"
  defp display(""), do: "-"
  defp display(value) when is_binary(value), do: value
  defp display(value), do: to_string(value)

  defp short_address(nil), do: "No contract configured"

  defp short_address("0x" <> rest = address) when byte_size(rest) > 12 do
    String.slice(address, 0, 6) <> "..." <> String.slice(address, -4, 4)
  end

  defp short_address(address), do: address

  defp context_module do
    :autolaunch
    |> Application.get_env(:regent_staking_live, [])
    |> Keyword.get(:context_module, RegentStaking)
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
      }
    </style>
    """
  end
end
