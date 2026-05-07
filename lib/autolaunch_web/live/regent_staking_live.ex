defmodule AutolaunchWeb.RegentStakingLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.Evm
  alias Autolaunch.InfrastructureConfig
  alias Autolaunch.RegentStaking
  alias AutolaunchWeb.Live.Refreshable
  alias AutolaunchWeb.RegentStakingLive.Presenter

  @poll_ms 15_000
  @manual_balance_refresh_ms 180
  @post_tx_balance_refresh_ms 2_200
  @regent_decimals 18
  @usdc_decimals 6

  @impl true
  def mount(_params, _session, socket) do
    connected_wallet_address = connected_wallet_address(socket.assigns.current_human)

    {state, notice} =
      load_staking_for_wallet(connected_wallet_address, socket.assigns.current_human)

    {:ok,
     socket
     |> Refreshable.schedule(@poll_ms)
     |> Refreshable.subscribe([:regent, :system])
     |> assign(:page_title, "$REGENT Staking")
     |> assign(:active_view, "regent-staking")
     |> assign(:state, state)
     |> assign(:staking_notice, notice)
     |> assign(:connected_wallet_address, connected_wallet_address)
     |> assign(:token_balances_refreshing, false)
     |> assign(:base_rpc_url, rpc_url(:base))
     |> assign(:base_sepolia_rpc_url, rpc_url(:base_sepolia))
     |> assign_staking_form(default_staking_params())}
  end

  @impl true
  def handle_event("change_staking_amount", %{"staking" => attrs}, socket) do
    {:noreply, assign_staking_form(socket, staking_form_params(attrs))}
  end

  @impl true
  def handle_event("submit_staking", %{"action" => action}, socket) do
    if socket.assigns.current_human do
      prepare_staking_action(socket, action)
    else
      {:noreply,
       assign(socket, :staking_notice, %{
         tone: :error,
         message: "Connect your wallet before staking, unstaking, or claiming."
       })}
    end
  end

  @impl true
  def handle_event("wallet_connected", %{"wallet_address" => wallet_address}, socket) do
    case Evm.normalize_required_address(wallet_address) do
      {:ok, normalized_address} ->
        {state, notice} =
          load_staking_for_wallet(normalized_address, socket.assigns.current_human)

        {:noreply,
         socket
         |> assign(:connected_wallet_address, normalized_address)
         |> assign(:state, state)
         |> assign(:staking_notice, notice)}

      {:error, :invalid_address} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("wallet_disconnected", _params, socket) do
    wallet_address = connected_wallet_address(socket.assigns.current_human)
    {state, notice} = load_staking_for_wallet(wallet_address, socket.assigns.current_human)

    {:noreply,
     socket
     |> assign(:connected_wallet_address, wallet_address)
     |> assign(:state, state)
     |> assign(:staking_notice, notice)}
  end

  @impl true
  def handle_event("refresh_token_balances", _params, socket) do
    {:noreply, schedule_token_balance_refresh(socket, :manual, @manual_balance_refresh_ms)}
  end

  @impl true
  def handle_event("staking_tx_complete", %{"action" => action}, socket) do
    {:noreply,
     socket
     |> assign(:staking_notice, %{tone: :success, message: staking_success_copy(action)})
     |> schedule_token_balance_refresh(:post_tx, @post_tx_balance_refresh_ms)}
  end

  @impl true
  def handle_event("staking_tx_failed", %{"message" => message}, socket) do
    {:noreply, assign(socket, :staking_notice, %{tone: :error, message: message})}
  end

  @impl true
  def handle_event("staking_signature_requested", _params, socket) do
    {:noreply,
     assign(socket, :staking_notice, %{
       tone: :info,
       message: "Open your wallet to continue. Then choose the action again."
     })}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, Refreshable.refresh(socket, @poll_ms, &load_staking/1)}
  end

  @impl true
  def handle_info({:autolaunch_live_update, :changed}, socket) do
    {:noreply, load_staking(socket)}
  end

  @impl true
  def handle_info({:refresh_token_balances, mode}, socket) when mode in [:manual, :post_tx] do
    {:noreply, refresh_token_balances(socket, mode)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <.regent_staking_styles />

      <section id="regent-staking-page" class="al-regent-staking">
        <.flash_group flash={@flash} />

        <%= if @state do %>
          <section
            id="regent-staking-wallet-console"
            class="al-regent-console"
            phx-hook="RegentStaking"
            data-base-rpc-url={@base_rpc_url}
            data-base-sepolia-rpc-url={@base_sepolia_rpc_url}
          >
            <div class="al-regent-console-grid">
              <div class="al-regent-console-read">
                <div class="al-regent-copy-block">
                  <p class="al-kicker">
                    <span class="al-regent-mark" aria-hidden="true">⋰</span> Staking console
                  </p>
                  <h1>Stake and earn your slice of all Regents revenue</h1>
                  <p class="al-regent-subtitle">The remainder goes to buy back the token.</p>
                  <p>
                    Stake $REGENT and withdraw anytime. Earn a pro-rata share of USDC the Regents Protocol makes across all apps. Earn 20% bonus $REGENT on your stake in the first year.
                  </p>
                </div>

                <div class="al-regent-metrics" aria-label="$REGENT staking balances">
                  <.staking_metric label="Network" value={@state.chain_label || "Base"} />
                  <.staking_metric
                    label="Total staked"
                    value={regent_value(@state.total_staked)}
                    tooltip={exact_regent_value(@state, :total_staked_raw)}
                  />
                  <.staking_metric
                    label="Staked balance"
                    value={regent_value(@state.wallet_stake_balance)}
                    tooltip={exact_regent_value(@state, :wallet_stake_balance_raw)}
                  />
                  <.staking_metric
                    label="Wallet balance"
                    value={regent_value(@state.wallet_token_balance)}
                    tooltip={exact_regent_value(@state, :wallet_token_balance_raw)}
                  />
                  <.staking_metric
                    label="Claimable USDC"
                    value={usdc_value(@state.wallet_claimable_usdc)}
                    tooltip={exact_usdc_value(@state, :wallet_claimable_usdc_raw)}
                  />
                  <.staking_metric
                    label="Claimable REGENT"
                    value={regent_value(@state.wallet_claimable_regent)}
                    tooltip={exact_regent_value(@state, :wallet_claimable_regent_raw)}
                  />
                </div>

                <div class="al-regent-support-grid">
                  <article class="al-regent-support-card">
                    <p class="al-regent-small-title">What to expect</p>
                    <ul>
                      <li>Stake and unstake use the amount you enter.</li>
                      <li>Claim actions use your live staking balances automatically.</li>
                      <li>After a confirmed wallet action, this page refreshes your staking snapshot.</li>
                    </ul>
                  </article>

                  <article class="al-regent-support-card is-emphasis">
                    <p class="al-regent-small-title">Confidence check</p>
                    <div>
                      <strong>Shared rail</strong>
                      <p>Platform and Autolaunch point to the same staking contract and claims.</p>
                    </div>
                    <div>
                      <strong>Wallet confirmation</strong>
                      <p>Nothing happens until you confirm the action in your wallet.</p>
                    </div>
                  </article>
                </div>
              </div>

              <section class="al-regent-wallet-panel" aria-label="$REGENT wallet actions">
                <div class="al-regent-wallet-panel-header">
                  <div>
                    <p class="al-regent-small-title">Wallet actions</p>
                    <h2>Stake, unstake, and claim</h2>
                  </div>
                  <div class="al-regent-panel-tools">
                    <span>Live balances</span>
                    <button
                      id="regent-staking-refresh-balances"
                      type="button"
                      phx-click="refresh_token_balances"
                      aria-label="Refresh staking balances"
                      title="Refresh staking balances"
                      class={["al-regent-refresh-button", @token_balances_refreshing && "is-refreshing"]}
                    >
                      ↻
                    </button>
                  </div>
                </div>

                <%= if @staking_notice do %>
                  <.staking_notice notice={@staking_notice} />
                <% end %>

                <%= unless @current_human do %>
                  <div class="al-regent-connect-card">
                    <p>Connect your wallet to stake, unstake, or claim.</p>
                    <.connect_wallet_button id="regent-staking-connect" class="al-regent-primary-button">
                      Connect wallet
                    </.connect_wallet_button>
                  </div>
                <% end %>

                <form
                  id="regent-staking-form"
                  phx-change="change_staking_amount"
                  class="al-regent-form"
                >
                  <div class="al-regent-field">
                    <label for="regent-staking-amount">Amount</label>
                    <input
                      id="regent-staking-amount"
                      name="staking[amount]"
                      type="text"
                      inputmode="decimal"
                      autocomplete="off"
                      value={@staking_params["amount"]}
                      placeholder="Amount of REGENT"
                      disabled={is_nil(@current_human)}
                    />
                  </div>

                  <div class="al-regent-receiver-option">
                    <input type="hidden" name="staking[stake_for_different_address]" value="false" />
                    <label for="regent-staking-different-address">
                      <input
                        id="regent-staking-different-address"
                        type="checkbox"
                        name="staking[stake_for_different_address]"
                        value="true"
                        checked={stake_for_different_address?(@staking_params)}
                        disabled={is_nil(@current_human)}
                      />
                      <span>Stake for Different Address</span>
                    </label>

                    <%= if stake_for_different_address?(@staking_params) do %>
                      <div class="al-regent-field">
                        <label for="regent-staking-receiver">Receiving wallet</label>
                        <%= if @resolved_receiver_address do %>
                          <p id="regent-staking-resolved-receiver" class="al-regent-resolved-address">
                            {@resolved_receiver_address}
                          </p>
                        <% end %>
                        <input
                          id="regent-staking-receiver"
                          name="staking[receiver]"
                          type="text"
                          value={@staking_params["receiver"]}
                          placeholder="0x... or name.eth"
                          phx-debounce="500"
                          autocomplete="off"
                          disabled={is_nil(@current_human)}
                        />
                      </div>
                    <% else %>
                      <div class="al-regent-default-wallet">
                        <p>Staking to connected wallet</p>
                        <strong id="regent-staking-default-wallet">
                          {@connected_wallet_address || "Connect wallet first"}
                        </strong>
                      </div>
                    <% end %>
                  </div>
                </form>

                <div class="al-regent-button-grid">
                  <.staking_action_button
                    id="regent-stake-button"
                    action="stake"
                    label="Stake on Autolaunch"
                    tone={:primary}
                    disabled={action_disabled?(@current_human, @state, :stake, @staking_params)}
                  />
                  <.staking_action_button
                    id="regent-unstake-button"
                    action="unstake"
                    label="Unstake"
                    disabled={action_disabled?(@current_human, @state, :unstake, @staking_params)}
                  />
                  <.staking_action_button
                    id="regent-claim-usdc-button"
                    action="claim_usdc"
                    label="Claim USDC"
                    disabled={action_disabled?(@current_human, @state, :claim_usdc, @staking_params)}
                  />
                  <.staking_action_button
                    id="regent-claim-regent-button"
                    action="claim_regent"
                    label="Claim REGENT"
                    disabled={action_disabled?(@current_human, @state, :claim_regent, @staking_params)}
                  />
                </div>

                <.staking_action_button
                  id="regent-restake-button"
                  action="claim_and_restake_regent"
                  label="Claim and restake REGENT"
                  wide={true}
                  disabled={
                    action_disabled?(@current_human, @state, :claim_and_restake_regent, @staking_params)
                  }
                />
              </section>
            </div>
          </section>
        <% else %>
          <section class="al-regent-empty">
            <p class="al-kicker">$REGENT staking</p>
            <h2>Staking is not configured here yet.</h2>
            <p>This page will show live balances and wallet actions after the staking rail is configured.</p>
          </section>
        <% end %>
      </section>
    </.shell>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :tooltip, :string, default: nil

  defp staking_metric(assigns) do
    ~H"""
    <article class="al-regent-metric">
      <p>{@label}</p>
      <strong
        class="al-regent-tooltip-value"
        data-tooltip={@tooltip}
        title={@tooltip}
        tabindex={if(@tooltip, do: "0")}
      >
        {@value}
      </strong>
    </article>
    """
  end

  attr :id, :string, required: true
  attr :action, :string, required: true
  attr :label, :string, required: true
  attr :tone, :atom, default: :secondary
  attr :wide, :boolean, default: false
  attr :disabled, :boolean, default: false

  defp staking_action_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click="submit_staking"
      phx-value-action={@action}
      disabled={@disabled}
      class={[
        "al-regent-action-button",
        @tone == :primary && "is-primary",
        @wide && "is-wide"
      ]}
    >
      {@label}
    </button>
    """
  end

  attr :notice, :map, required: true

  defp staking_notice(assigns) do
    ~H"""
    <div class={["al-regent-notice", "is-#{@notice.tone}"]} role="status">
      {@notice.message}
    </div>
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
      phx-click={JS.dispatch("click", to: "#autolaunch-wallet [data-wallet-connect]")}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp prepare_staking_action(socket, action) do
    params = staking_action_params(action, socket.assigns.staking_params)

    case staking_action(action, params, staking_principal(socket)) do
      {:ok, %{prepared: %{wallet_action: wallet_action}}} ->
        {:noreply,
         socket
         |> assign(:staking_notice, %{tone: :info, message: staking_pending_copy(action)})
         |> push_event("regent-staking:wallet-action", %{
           action: action,
           wallet_action: wallet_action
         })}

      {:error, reason} ->
        {:noreply,
         assign(socket, :staking_notice, %{tone: :error, message: Presenter.action_error(reason)})}
    end
  end

  defp staking_action("stake", params, current_human),
    do: context_module().stake(params, current_human)

  defp staking_action("unstake", params, current_human),
    do: context_module().unstake(params, current_human)

  defp staking_action("claim_usdc", params, current_human),
    do: context_module().claim_usdc(params, current_human)

  defp staking_action("claim_regent", params, current_human),
    do: context_module().claim_regent(params, current_human)

  defp staking_action("claim_and_restake_regent", params, current_human),
    do: context_module().claim_and_restake_regent(params, current_human)

  defp staking_action(_action, _params, _current_human), do: {:error, :invalid_action}

  defp staking_action_params("stake", params) do
    %{
      "amount" => Map.get(params, "amount", ""),
      "receiver" =>
        if(stake_for_different_address?(params), do: Map.get(params, "receiver", ""), else: "")
    }
  end

  defp staking_action_params(_action, params), do: %{"amount" => Map.get(params, "amount", "")}

  defp staking_principal(socket) do
    case connected_wallet_address(socket.assigns) do
      nil -> socket.assigns.current_human
      wallet_address -> %{"wallet_address" => wallet_address}
    end
  end

  defp schedule_token_balance_refresh(socket, mode, delay_ms) do
    Process.send_after(self(), {:refresh_token_balances, mode}, delay_ms)
    assign(socket, :token_balances_refreshing, true)
  end

  defp refresh_token_balances(socket, mode) do
    {state, notice} = load_staking_for_socket(socket)

    socket
    |> assign(:state, state)
    |> assign(:staking_notice, refreshed_notice(mode, notice))
    |> assign(:token_balances_refreshing, false)
  end

  defp refreshed_notice(_mode, %{tone: :error} = notice), do: notice
  defp refreshed_notice(_mode, _notice), do: %{tone: :success, message: "Balances refreshed."}

  defp load_staking(socket) do
    {state, notice} = load_staking_for_socket(socket)

    socket
    |> assign(:state, state)
    |> assign(:staking_notice, notice)
  end

  defp load_staking_for_socket(socket) do
    socket.assigns
    |> connected_wallet_address()
    |> load_staking_for_wallet(socket.assigns.current_human)
  end

  defp load_staking_for_wallet(nil, current_human), do: load_staking_for_human(current_human)

  defp load_staking_for_wallet(wallet_address, current_human) do
    case context_module().account(wallet_address, current_human) do
      {:ok, state} ->
        {state, nil}

      {:error, :unconfigured} ->
        {nil, %{tone: :error, message: "Staking is unavailable right now."}}

      {:error, _reason} ->
        {nil, %{tone: :error, message: "Could not load staking details right now."}}
    end
  end

  defp load_staking_for_human(current_human) do
    case context_module().overview(current_human) do
      {:ok, state} ->
        {state, nil}

      {:error, :unconfigured} ->
        {nil, %{tone: :error, message: "Staking is unavailable right now."}}

      {:error, _reason} ->
        {nil, %{tone: :error, message: "Could not load staking details right now."}}
    end
  end

  defp context_module do
    :autolaunch
    |> Application.get_env(:regent_staking_live, [])
    |> Keyword.get(:context_module, RegentStaking)
  end

  defp default_staking_params do
    %{
      "amount" => "",
      "stake_for_different_address" => "false",
      "receiver" => ""
    }
  end

  defp assign_staking_form(socket, params) do
    socket
    |> assign(:staking_params, params)
    |> assign(:staking_form, to_form(params, as: :staking))
    |> assign(:resolved_receiver_address, resolved_receiver_address(params))
  end

  defp staking_form_params(attrs) when is_map(attrs) do
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

  defp connected_wallet_address(%{connected_wallet_address: wallet_address}),
    do: Evm.normalize_address(wallet_address)

  defp connected_wallet_address(%{wallet_address: wallet_address}),
    do: Evm.normalize_address(wallet_address)

  defp connected_wallet_address(_value), do: nil

  defp action_disabled?(nil, _state, _action, _params), do: true
  defp action_disabled?(_human, nil, _action, _params), do: true
  defp action_disabled?(_human, state, :stake, _params), do: stake_disabled?(state)

  defp action_disabled?(_human, state, :unstake, params),
    do: stake_for_different_address?(params) or unstake_disabled?(state)

  defp action_disabled?(_human, state, :claim_usdc, params),
    do: stake_for_different_address?(params) or claim_disabled?(state, :usdc)

  defp action_disabled?(_human, state, :claim_regent, params),
    do: stake_for_different_address?(params) or claim_disabled?(state, :regent)

  defp action_disabled?(_human, state, :claim_and_restake_regent, params),
    do: stake_for_different_address?(params) or claim_disabled?(state, :regent)

  defp stake_disabled?(state),
    do: not positive_raw_amount?(Map.get(state, :wallet_token_balance_raw))

  defp unstake_disabled?(state),
    do: not positive_raw_amount?(Map.get(state, :wallet_stake_balance_raw))

  defp claim_disabled?(state, :usdc),
    do: not positive_raw_amount?(Map.get(state, :wallet_claimable_usdc_raw))

  defp claim_disabled?(state, :regent),
    do: not positive_raw_amount?(Map.get(state, :wallet_claimable_regent_raw))

  defp positive_raw_amount?(value) when is_integer(value), do: value > 0

  defp positive_raw_amount?(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed > 0
      _other -> false
    end
  end

  defp positive_raw_amount?(_value), do: false

  defp staking_pending_copy("stake"), do: "Open your wallet to confirm the staking transaction."
  defp staking_pending_copy("unstake"), do: "Open your wallet to confirm the unstake transaction."
  defp staking_pending_copy("claim_usdc"), do: "Open your wallet to confirm the USDC claim."
  defp staking_pending_copy("claim_regent"), do: "Open your wallet to confirm the REGENT claim."

  defp staking_pending_copy("claim_and_restake_regent"),
    do: "Open your wallet to confirm the claim-and-restake transaction."

  defp staking_pending_copy(_action), do: "Open your wallet to confirm the staking transaction."

  defp staking_success_copy("stake"), do: "Stake sent. Refreshing your staking snapshot."
  defp staking_success_copy("unstake"), do: "Unstake sent. Refreshing your staking snapshot."

  defp staking_success_copy("claim_usdc"),
    do: "USDC claim sent. Refreshing your staking snapshot."

  defp staking_success_copy("claim_regent"),
    do: "REGENT claim sent. Refreshing your staking snapshot."

  defp staking_success_copy("claim_and_restake_regent"),
    do: "Claim-and-restake sent. Refreshing your staking snapshot."

  defp staking_success_copy(_action), do: "Transaction sent. Refreshing your staking snapshot."

  defp staking_value(nil), do: "--"
  defp staking_value(value) when is_binary(value), do: value
  defp staking_value(value), do: to_string(value)

  defp regent_value(nil), do: "--"

  defp regent_value(value) do
    value
    |> Decimal.new()
    |> compact_decimal()
  rescue
    _error -> staking_value(value)
  end

  defp usdc_value(nil), do: "--"

  defp usdc_value(value) do
    decimal = Decimal.new(value)

    cond do
      Decimal.equal?(decimal, Decimal.new(0)) ->
        "0.00"

      Decimal.compare(decimal, Decimal.new(1)) == :lt ->
        decimal
        |> Decimal.round(4)
        |> Decimal.normalize()
        |> Decimal.to_string(:normal)

      true ->
        decimal
        |> Decimal.round(2)
        |> Decimal.to_string(:normal)
        |> ensure_fixed_decimals(2)
    end
  rescue
    _error -> staking_value(value)
  end

  defp exact_regent_value(nil, _key), do: nil

  defp exact_regent_value(state, key),
    do: exact_units(Map.get(state, key), @regent_decimals, "REGENT")

  defp exact_usdc_value(nil, _key), do: nil
  defp exact_usdc_value(state, key), do: exact_units(Map.get(state, key), @usdc_decimals, "USDC")

  defp exact_units(value, decimals, suffix) do
    case raw_integer(value) do
      {:ok, integer} ->
        amount =
          integer
          |> Decimal.new()
          |> Decimal.div(Decimal.new(Integer.pow(10, decimals)))
          |> Decimal.normalize()
          |> Decimal.to_string(:normal)

        amount <> " " <> suffix

      :error ->
        nil
    end
  end

  defp raw_integer(value) when is_integer(value), do: {:ok, value}

  defp raw_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _other -> :error
    end
  end

  defp raw_integer(_value), do: :error

  defp compact_decimal(decimal) do
    cond do
      Decimal.compare(decimal, Decimal.new("1000000000")) != :lt ->
        decimal |> Decimal.div(Decimal.new("1000000000")) |> compact_suffix("B")

      Decimal.compare(decimal, Decimal.new("1000000")) != :lt ->
        decimal |> Decimal.div(Decimal.new("1000000")) |> compact_suffix("M")

      true ->
        decimal
        |> Decimal.round(6)
        |> Decimal.normalize()
        |> Decimal.to_string(:normal)
    end
  end

  defp compact_suffix(decimal, suffix) do
    decimal
    |> Decimal.round(1)
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
    |> Kernel.<>(suffix)
  end

  defp ensure_fixed_decimals(value, decimals) do
    case String.split(value, ".", parts: 2) do
      [whole] -> whole <> "." <> String.duplicate("0", decimals)
      [whole, fraction] -> whole <> "." <> String.pad_trailing(fraction, decimals, "0")
    end
  end

  defp rpc_url(:base) do
    case InfrastructureConfig.regent_staking_rpc_url() do
      {:ok, url} -> url
      {:error, _reason} -> nil
    end
  end

  defp rpc_url(:base_sepolia) do
    case InfrastructureConfig.launch_rpc_url() do
      {:ok, url} -> url
      {:error, _reason} -> nil
    end
  end

  defp regent_staking_styles(assigns) do
    ~H"""
    <style>
      .al-regent-staking {
        display: grid;
        gap: 1.35rem;
      }

      .al-regent-console,
      .al-regent-empty {
        border: 1px solid color-mix(in srgb, var(--brand-primary) 22%, transparent);
        border-radius: 1.25rem;
        background:
          radial-gradient(circle at 96% 4%, color-mix(in srgb, var(--brand-primary) 9%, transparent), transparent 28%),
          linear-gradient(180deg, color-mix(in srgb, white 97%, var(--color-bg) 3%), color-mix(in srgb, white 91%, var(--brand-primary) 9%));
        box-shadow: 0 24px 60px -44px rgba(21, 96, 66, 0.36);
      }

      :root[data-theme="dark"] .al-regent-console,
      :root[data-theme="dark"] .al-regent-empty {
        background:
          radial-gradient(circle at 88% 0%, rgba(50, 210, 145, 0.14), transparent 34%),
          linear-gradient(145deg, #073423, #06413a 78%);
      }

      .al-regent-console {
        padding: clamp(1rem, 2vw, 1.35rem);
      }

      .al-regent-console-grid {
        display: grid;
        grid-template-columns: minmax(0, 1.06fr) minmax(360px, 0.94fr);
        gap: 1.25rem;
        align-items: stretch;
      }

      .al-regent-console-read,
      .al-regent-wallet-panel {
        min-width: 0;
      }

      .al-regent-console-read {
        display: grid;
        align-content: start;
        gap: 1.05rem;
      }

      .al-regent-copy-block {
        display: grid;
        gap: 0.85rem;
      }

      .al-regent-copy-block h1 {
        max-width: 12ch;
        margin: 0;
        color: color-mix(in srgb, var(--brand-ink) 94%, black 6%);
        font-size: clamp(2.65rem, 5.8vw, 5.2rem);
        line-height: 0.88;
        letter-spacing: 0;
        text-wrap: balance;
      }

      .al-regent-copy-block p:not(.al-kicker) {
        max-width: 58rem;
        margin: 0;
        color: color-mix(in srgb, var(--brand-ink) 70%, transparent);
        font-size: 1rem;
        line-height: 1.65;
      }

      .al-regent-copy-block .al-regent-subtitle {
        color: color-mix(in srgb, var(--brand-primary) 78%, black 22%);
        font-size: 1.08rem;
        font-weight: 700;
      }

      .al-regent-mark {
        color: color-mix(in srgb, var(--brand-primary) 86%, black 14%);
      }

      .al-regent-metrics {
        display: grid;
        grid-template-columns: repeat(3, minmax(0, 1fr));
        gap: 0.75rem;
      }

      .al-regent-metric,
      .al-regent-support-card,
      .al-regent-wallet-panel,
      .al-regent-connect-card,
      .al-regent-receiver-option,
      .al-regent-default-wallet {
        border: 1px solid color-mix(in srgb, var(--brand-ink) 10%, transparent);
        background: color-mix(in srgb, white 94%, var(--color-bg) 6%);
        border-radius: 1.25rem;
      }

      :root[data-theme="dark"] .al-regent-metric,
      :root[data-theme="dark"] .al-regent-support-card,
      :root[data-theme="dark"] .al-regent-wallet-panel,
      :root[data-theme="dark"] .al-regent-connect-card,
      :root[data-theme="dark"] .al-regent-receiver-option,
      :root[data-theme="dark"] .al-regent-default-wallet {
        background: rgba(4, 41, 33, 0.74);
        border-color: rgba(172, 247, 211, 0.18);
      }

      .al-regent-metric {
        display: flex;
        min-height: 8.25rem;
        flex-direction: column;
        justify-content: center;
        padding: 1rem;
      }

      .al-regent-metric p,
      .al-regent-small-title,
      .al-regent-field label {
        margin: 0;
        color: color-mix(in srgb, var(--brand-ink) 58%, transparent);
        font-size: 0.72rem;
        font-weight: 700;
        letter-spacing: 0.18em;
        text-transform: uppercase;
      }

      .al-regent-metric strong {
        display: block;
        margin-top: 1rem;
        overflow-wrap: anywhere;
        color: color-mix(in srgb, var(--brand-ink) 92%, black 8%);
        font-size: clamp(1.1rem, 1.5vw, 1.42rem);
        line-height: 1;
      }

      .al-regent-support-grid {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 0.9rem;
      }

      .al-regent-support-card {
        padding: 1.05rem;
      }

      .al-regent-support-card ul {
        display: grid;
        gap: 0.7rem;
        margin: 1rem 0 0;
        padding: 0;
        list-style: none;
      }

      .al-regent-support-card li,
      .al-regent-support-card div {
        border: 1px solid color-mix(in srgb, var(--brand-ink) 9%, transparent);
        border-radius: 1rem;
        padding: 0.78rem 0.9rem;
        color: color-mix(in srgb, var(--brand-ink) 72%, transparent);
        line-height: 1.5;
      }

      .al-regent-support-card strong {
        display: block;
        color: color-mix(in srgb, var(--brand-ink) 88%, black 12%);
        font-size: 0.98rem;
      }

      .al-regent-support-card p {
        margin: 0.4rem 0 0;
        color: color-mix(in srgb, var(--brand-ink) 66%, transparent);
        line-height: 1.55;
      }

      .al-regent-support-card.is-emphasis {
        background: color-mix(in srgb, var(--brand-primary) 8%, white 92%);
      }

      :root[data-theme="dark"] .al-regent-support-card.is-emphasis {
        background: linear-gradient(145deg, rgba(10, 92, 70, 0.92), rgba(0, 72, 78, 0.88));
      }

      .al-regent-wallet-panel {
        display: grid;
        align-content: start;
        gap: 1rem;
        padding: clamp(1rem, 2vw, 1.35rem);
      }

      .al-regent-wallet-panel-header {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 1rem;
      }

      .al-regent-wallet-panel h2 {
        margin: 0.65rem 0 0;
        color: color-mix(in srgb, var(--brand-ink) 92%, black 8%);
        font-size: clamp(1.6rem, 3vw, 2.55rem);
        line-height: 0.94;
        letter-spacing: 0;
      }

      .al-regent-panel-tools {
        display: flex;
        align-items: center;
        gap: 0.65rem;
      }

      .al-regent-panel-tools span {
        border: 1px solid color-mix(in srgb, var(--brand-ink) 10%, transparent);
        border-radius: 999px;
        padding: 0.55rem 0.85rem;
        color: color-mix(in srgb, var(--brand-ink) 60%, transparent);
        font-size: 0.72rem;
        letter-spacing: 0.14em;
        text-transform: uppercase;
      }

      .al-regent-refresh-button {
        display: inline-flex;
        width: 2.75rem;
        height: 2.75rem;
        align-items: center;
        justify-content: center;
        border: 1px solid color-mix(in srgb, var(--brand-ink) 10%, transparent);
        border-radius: 999px;
        background: color-mix(in srgb, white 94%, var(--color-bg) 6%);
        color: color-mix(in srgb, var(--brand-ink) 82%, transparent);
        transition:
          transform 160ms cubic-bezier(0.23, 1, 0.32, 1),
          border-color 160ms ease,
          background-color 160ms ease;
      }

      .al-regent-refresh-button:active {
        transform: scale(0.96);
      }

      .al-regent-refresh-button.is-refreshing {
        animation: al-regent-spin 700ms linear infinite;
      }

      .al-regent-notice,
      .al-regent-connect-card {
        padding: 0.88rem 1rem;
        line-height: 1.5;
      }

      .al-regent-notice.is-error {
        border-color: color-mix(in srgb, #b94b39 28%, transparent);
        background: color-mix(in srgb, #b94b39 10%, white 90%);
      }

      .al-regent-notice.is-success {
        border-color: color-mix(in srgb, var(--brand-primary) 28%, transparent);
        background: color-mix(in srgb, var(--brand-primary) 10%, white 90%);
      }

      .al-regent-notice.is-info {
        border-color: color-mix(in srgb, var(--brand-ink) 10%, transparent);
        background: color-mix(in srgb, white 92%, var(--brand-primary) 8%);
      }

      .al-regent-connect-card {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 1rem;
      }

      .al-regent-connect-card p {
        margin: 0;
        color: color-mix(in srgb, var(--brand-ink) 68%, transparent);
      }

      .al-regent-form {
        display: grid;
        gap: 1rem;
      }

      .al-regent-field {
        display: grid;
        gap: 0.55rem;
      }

      .al-regent-field input,
      .al-regent-default-wallet {
        width: 100%;
        min-height: 3.4rem;
        border: 1px solid color-mix(in srgb, var(--brand-ink) 11%, transparent);
        border-radius: 1.05rem;
        background: color-mix(in srgb, white 96%, var(--color-bg) 4%);
        padding: 0.9rem 1rem;
        color: color-mix(in srgb, var(--brand-ink) 92%, black 8%);
      }

      .al-regent-field input:disabled {
        cursor: not-allowed;
        opacity: 0.58;
      }

      .al-regent-field input:focus-visible {
        outline: none;
        border-color: color-mix(in srgb, var(--brand-primary) 48%, transparent);
        box-shadow: 0 0 0 0.22rem color-mix(in srgb, var(--brand-primary) 14%, transparent);
      }

      .al-regent-receiver-option {
        display: grid;
        gap: 0.8rem;
        padding: 1rem;
      }

      .al-regent-receiver-option > label {
        display: flex;
        align-items: center;
        gap: 0.75rem;
        color: color-mix(in srgb, var(--brand-ink) 86%, black 8%);
      }

      .al-regent-receiver-option input[type="checkbox"] {
        width: 1.15rem;
        height: 1.15rem;
        accent-color: var(--brand-primary);
      }

      .al-regent-default-wallet p,
      .al-regent-resolved-address {
        margin: 0;
        color: color-mix(in srgb, var(--brand-ink) 58%, transparent);
        line-height: 1.45;
        overflow-wrap: anywhere;
      }

      .al-regent-default-wallet strong {
        display: block;
        margin-top: 0.35rem;
        overflow-wrap: anywhere;
      }

      .al-regent-button-grid {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 0.75rem;
      }

      .al-regent-primary-button,
      .al-regent-action-button {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        min-height: 3.15rem;
        border-radius: 999px;
        border: 1px solid color-mix(in srgb, var(--brand-ink) 10%, transparent);
        background: color-mix(in srgb, white 94%, var(--color-bg) 6%);
        color: color-mix(in srgb, var(--brand-ink) 90%, black 10%);
        padding: 0.85rem 1rem;
        font-weight: 700;
        transition:
          transform 160ms cubic-bezier(0.23, 1, 0.32, 1),
          border-color 160ms ease,
          background-color 160ms ease,
          box-shadow 160ms ease,
          color 160ms ease;
      }

      .al-regent-primary-button,
      .al-regent-action-button.is-primary {
        border-color: color-mix(in srgb, var(--brand-primary) 72%, black 8%);
        background: linear-gradient(
          180deg,
          color-mix(in srgb, var(--brand-primary) 80%, white 20%),
          var(--brand-primary)
        );
        color: var(--color-fg-on-primary, #fffaf0);
        box-shadow: 0 22px 42px -28px color-mix(in srgb, var(--brand-primary) 65%, transparent);
      }

      .al-regent-action-button.is-wide {
        width: 100%;
      }

      .al-regent-primary-button:active:not(:disabled),
      .al-regent-action-button:active:not(:disabled) {
        transform: scale(0.975);
      }

      .al-regent-action-button:disabled {
        cursor: not-allowed;
        opacity: 0.52;
        transform: none;
        box-shadow: none;
      }

      .al-regent-tooltip-value[data-tooltip] {
        position: relative;
        display: inline-flex;
        max-width: 100%;
        cursor: help;
        outline: none;
      }

      .al-regent-tooltip-value[data-tooltip]::after {
        content: attr(data-tooltip);
        position: absolute;
        bottom: calc(100% + 0.65rem);
        left: 0;
        z-index: 40;
        min-width: min(18rem, 80vw);
        max-width: min(24rem, 86vw);
        border: 1px solid color-mix(in srgb, var(--brand-ink) 14%, transparent);
        border-radius: 0.85rem;
        background: color-mix(in srgb, white 94%, var(--brand-ink) 6%);
        color: color-mix(in srgb, var(--brand-ink) 92%, black 8%);
        box-shadow: 0 18px 40px rgba(28, 51, 77, 0.14);
        padding: 0.65rem 0.75rem;
        font-size: 0.82rem;
        line-height: 1.45;
        opacity: 0;
        pointer-events: none;
        transform: translateY(0.25rem);
        transition:
          opacity 160ms ease,
          transform 160ms ease;
        white-space: normal;
        overflow-wrap: anywhere;
      }

      .al-regent-tooltip-value[data-tooltip]:hover::after,
      .al-regent-tooltip-value[data-tooltip]:focus-visible::after {
        opacity: 1;
        transform: translateY(0);
      }

      .al-regent-empty {
        padding: 1.25rem;
      }

      .al-regent-empty h2 {
        margin: 0.5rem 0 0;
        font-size: clamp(1.5rem, 3vw, 2.6rem);
        line-height: 1;
      }

      @media (hover: hover) and (pointer: fine) {
        .al-regent-metric,
        .al-regent-support-card,
        .al-regent-action-button,
        .al-regent-primary-button {
          transition:
            transform 180ms cubic-bezier(0.23, 1, 0.32, 1),
            border-color 180ms ease,
            box-shadow 180ms ease,
            background-color 180ms ease;
        }

        .al-regent-metric:hover,
        .al-regent-support-card:hover {
          transform: translateY(-2px);
          border-color: color-mix(in srgb, var(--brand-primary) 24%, transparent);
          box-shadow: 0 24px 52px -42px rgba(21, 96, 66, 0.34);
        }

        .al-regent-action-button:hover:not(:disabled),
        .al-regent-primary-button:hover:not(:disabled) {
          transform: translateY(-1px);
          border-color: color-mix(in srgb, var(--brand-primary) 42%, transparent);
        }
      }

      @keyframes al-regent-spin {
        to {
          transform: rotate(360deg);
        }
      }

      @media (max-width: 1100px) {
        .al-regent-console-grid {
          grid-template-columns: 1fr;
        }

        .al-regent-copy-block h1 {
          max-width: 18ch;
        }
      }

      @media (max-width: 760px) {
        .al-regent-metrics,
        .al-regent-support-grid,
        .al-regent-button-grid {
          grid-template-columns: 1fr;
        }

        .al-regent-wallet-panel-header,
        .al-regent-connect-card {
          align-items: stretch;
          flex-direction: column;
        }

        .al-regent-primary-button,
        .al-regent-action-button {
          width: 100%;
        }
      }
    </style>
    """
  end
end
