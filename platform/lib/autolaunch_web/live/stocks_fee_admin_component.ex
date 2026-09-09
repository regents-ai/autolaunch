defmodule AutolaunchWeb.StocksFeeAdminComponent do
  @moduledoc """
  Fee administration of one graduated Stocks launch, on its pool page.

  Everyone sees the current administrator, any proposed successor and the
  subject lane's state. The signed-in account whose selected wallet is the
  administrator can turn the subject lane on or onto another revenue address,
  turn it off, or hand the role over; the proposed wallet can accept it. Each is
  one reviewed transaction on the shared wallet-press plumbing; the browser
  reports a hash and stops, and every outcome on screen is the server's own read.
  """

  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.Stocks.FeeAdminActions
  alias AutolaunchWeb.WalletPressComponent

  @copy %{
    authentication_required: "Sign in to administer this launch from your wallet.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer: "Switch back to a wallet on this account to continue.",
    invalid_address: "That is not a usable address.",
    subject_splitter_invalid: "The revenue address is not a usable address.",
    subject_splitter_unrecognised:
      "That address is not a recognised Agent revenue address. Use the revenue address shown on an Agent subject page.",
    not_fee_administrator: "Only this launch's fee administrator can do that.",
    not_proposed_administrator: "Only the wallet the administrator proposed can accept the role.",
    chain_unavailable:
      "The Base fork could not be read just now. Check that it is still running.",
    stocks_unavailable: "Stock launches are not open on this site.",
    launch_not_found: "This auction is not a stock launch the launchpad knows.",
    auction_not_found: "This auction is no longer available.",
    auction_unavailable: "This auction could not be read just now.",
    lab_config_changed: "The fork changed since this review. Review it again.",
    submitted_hash_conflict: "This step already has a transaction.",
    submitted_step_mismatch: "That transaction is not the step this action is waiting for.",
    operation_not_found: "That action is no longer open."
  }

  @generic "That did not go through. Try again in a moment."
  @unheld [:wrong_signer, :session_unavailable, :session_lease_required, :invalid_address]

  # A press the shared plumbing just verified as confirmed changed the
  # configuration, so the page rereads the pool and its lanes.
  @impl true
  def update(%{wallet_press_result: result, wallet_press_lease: lease}, socket) do
    before = socket.assigns[:operation]
    socket = WalletPressComponent.consume(socket, lease, result)
    if confirmed_now?(before, socket.assigns[:operation]), do: send(self(), :reload_pool)
    {:ok, socket}
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> WalletPressComponent.update_scope(assigns)
     |> assign(assigns)
     |> assign_new(:wallet, fn -> nil end)
     |> assign_new(:notice, fn -> nil end)
     |> assign_new(:wallet_press_history, fn -> %{} end)
     |> assign_new(:operation, fn -> nil end)
     |> assign_new(:splitter_input, fn -> "" end)
     |> assign_new(:proposed_input, fn -> "" end)}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, role: role(assigns.config, assigns.wallet))

    ~H"""
    <section
      id={@id}
      class="launch-wallet"
      data-wallet-scope={WalletPressComponent.scope(assigns)}
      phx-hook="AutolaunchFeeAdminWallet"
      phx-target={@myself}
      aria-label="Fee administration"
    >
      <h3>Fee administration</h3>
      <dl class="autolaunch-live-market">
        <div>
          <dt>Administrator</dt>
          <dd class="launch-wallet-mono">{@config.administrator}</dd>
        </div>
        <div>
          <dt>Proposed administrator</dt>
          <dd :if={@config.proposed_administrator} class="launch-wallet-mono">
            {@config.proposed_administrator} · awaiting acceptance
          </dd>
          <dd :if={!@config.proposed_administrator}>None</dd>
        </div>
        <div>
          <dt>Configuration version</dt>
          <dd>{@config.version}</dd>
        </div>
      </dl>
      <p class="launch-wallet-hint">
        The administrator can turn the subject revenue lane on, off or onto another Agent revenue
        address, and can hand the role over. {FeeAdminActions.future_only_copy()}
      </p>

      <p
        :if={@notice}
        class="launch-wallet-notice"
        role={if @notice.tone == :error, do: "alert", else: "status"}
      >
        {@notice.message}
      </p>

      <p :if={!@authenticated} class="launch-wallet-hint">
        Sign in with the administrator's wallet to change the subject revenue lane.
      </p>

      <div :if={@authenticated && !@wallet} class="launch-wallet-empty">
        <p>Choose the wallet you administer this launch from.</p>
        <Regent.Primitives.button type="button" data-fee-admin-connect>
          Connect or switch wallet
        </Regent.Primitives.button>
      </div>

      <p :if={@wallet && @role == :none && !@operation} class="launch-wallet-hint" role="status">
        {short(@wallet)} is neither the administrator nor a proposed administrator of this launch.
      </p>

      <div :if={@wallet && @role == :administrator && !@operation} class="launch-wallet-open">
        <form phx-submit="review_configure" phx-target={@myself} class="launch-wallet-open">
          <label for={"#{@id}-splitter"}>
            {if @config.splitter,
              do: "Send the subject lane to another revenue address",
              else: "Turn the subject lane on"}
          </label>
          <input
            id={"#{@id}-splitter"}
            name="splitter"
            type="text"
            inputmode="text"
            autocomplete="off"
            spellcheck="false"
            placeholder="0x… Agent subject revenue address"
            value={@splitter_input}
            class="launch-wallet-mono"
          />
          <div class="launch-wallet-controls">
            <Regent.Primitives.button type="submit">Review</Regent.Primitives.button>
            <Regent.Primitives.button
              :if={@config.splitter}
              type="button"
              variant="secondary"
              phx-click="review_off"
              phx-target={@myself}
            >
              Turn the subject lane off
            </Regent.Primitives.button>
          </div>
        </form>
        <form phx-submit="review_propose" phx-target={@myself} class="launch-wallet-open">
          <label for={"#{@id}-proposed"}>Hand the administrator role over to</label>
          <input
            id={"#{@id}-proposed"}
            name="proposed_administrator"
            type="text"
            inputmode="text"
            autocomplete="off"
            spellcheck="false"
            placeholder="0x… the next administrator"
            value={@proposed_input}
            class="launch-wallet-mono"
          />
          <div class="launch-wallet-controls">
            <Regent.Primitives.button type="submit" variant="secondary">
              Review hand-over
            </Regent.Primitives.button>
          </div>
        </form>
      </div>

      <div :if={@wallet && @role == :proposed && !@operation} class="launch-wallet-open">
        <p class="launch-wallet-hint">
          {short(@wallet)} has been proposed as this launch's next fee administrator.
        </p>
        <Regent.Primitives.button type="button" phx-click="review_accept" phx-target={@myself}>
          Review acceptance
        </Regent.Primitives.button>
      </div>

      <section
        :if={@operation && WalletPressComponent.scope(assigns)}
        id={"#{@id}-review"}
        class="launch-wallet-review"
        aria-label="Fee administration review"
      >
        <h4>{title(@operation.kind)}</h4>
        <dl>
          <div :for={{label, value} <- review_rows(@operation)}>
            <dt>{label}</dt>
            <dd class="launch-wallet-mono">{value}</dd>
          </div>
          <div>
            <dt>Wallet</dt>
            <dd class="launch-wallet-mono">{short(@operation.signer)}</dd>
          </div>
          <div>
            <dt>Network</dt>
            <dd>{Autolaunch.ChainMode.label()} · chain 31337</dd>
          </div>
        </dl>
        <p class="launch-wallet-risk">{@operation.envelope["risk_copy"]}</p>
        <ol class="launch-wallet-steps" role="list" aria-label="Progress">
          <li data-step="action">
            <span>{title(@operation.kind)}</span>
            <span class="launch-wallet-step-state">{current_state(@operation.state)}</span>
            <span
              :if={@operation.action_transaction_hash}
              class="launch-wallet-mono"
              data-local-transaction-hash
            >
              {short_hash(@operation.action_transaction_hash)}
            </span>
          </li>
        </ol>

        <section :if={@operation.state == :confirmed} class="launch-wallet-settled" role="status">
          <p>{confirmed_copy(@operation)}</p>
        </section>
        <p
          :if={@operation.state in [:reverted, :unverified]}
          class="launch-wallet-settled"
          role="alert"
        >
          {settled_copy(@operation)}
        </p>
        <p
          :if={@operation.state in [:not_sent, :cancelled, :expired, :submission_unknown]}
          class="launch-wallet-settled"
          role="status"
        >
          {settled_copy(@operation)}
        </p>

        <div class="launch-wallet-controls">
          <Regent.Primitives.button
            :if={sendable?(@operation, @wallet)}
            type="button"
            data-fee-admin-send={@operation.action_id}
            data-wallet-step="action"
          >
            Confirm in wallet
          </Regent.Primitives.button>
          <p :if={@operation.signer != @wallet && is_nil(@operation.terminal_at)} role="status">
            This review belongs to another wallet. Switch back to it to finish.
          </p>
          <Regent.Primitives.button
            :if={@operation.state == :submitted}
            type="button"
            phx-click="check_fee_admin_step"
            phx-value-action-id={@operation.action_id}
            phx-target={@myself}
            variant="secondary"
          >
            Check again
          </Regent.Primitives.button>
          <Regent.Primitives.button
            :if={@operation.state == :prepared}
            type="button"
            phx-click="cancel_fee_admin_review"
            phx-value-action-id={@operation.action_id}
            phx-target={@myself}
            variant="secondary"
          >
            Cancel
          </Regent.Primitives.button>
          <Regent.Primitives.button
            :if={@operation.state in [:dispatched, :submitted]}
            type="button"
            phx-click="start_new_fee_admin"
            phx-value-action-id={@operation.action_id}
            phx-target={@myself}
            variant="secondary"
          >
            Start something else
          </Regent.Primitives.button>
          <Regent.Primitives.button
            :if={@operation.terminal_at}
            type="button"
            phx-click="clear_fee_admin"
            phx-target={@myself}
            variant="secondary"
          >
            Done
          </Regent.Primitives.button>
        </div>
      </section>
      <WalletPressComponent.history
        :if={WalletPressComponent.scope(assigns)}
        history={@wallet_press_history}
        target={@myself}
      />
    </section>
    """
  end

  @impl true
  def handle_event("wallet_press_dispatch", params, socket),
    do:
      {:noreply,
       WalletPressComponent.dispatch(socket, :stocks_fee_admin, params, opts(socket), __MODULE__)}

  def handle_event("wallet_press_report", params, socket),
    do:
      {:noreply,
       WalletPressComponent.report(socket, :stocks_fee_admin, params, opts(socket), __MODULE__)}

  def handle_event("wallet_press_verify", params, socket),
    do:
      {:noreply,
       WalletPressComponent.verify(socket, :stocks_fee_admin, params, opts(socket), __MODULE__)}

  def handle_event("wallet_press_restore", params, socket),
    do: {:noreply, WalletPressComponent.restore(socket, :stocks_fee_admin, params, opts(socket))}

  def handle_event("fee_admin_active_wallet", %{"address" => address}, socket),
    do: {:noreply, adopt(socket, address)}

  def handle_event("review_configure", %{"splitter" => splitter}, socket) do
    {:noreply,
     socket
     |> assign(splitter_input: splitter)
     |> review(:configure_subject, %{"splitter" => splitter})}
  end

  def handle_event("review_off", _params, socket),
    do: {:noreply, review(socket, :configure_subject, %{"splitter" => ""})}

  def handle_event("review_propose", %{"proposed_administrator" => proposed}, socket) do
    {:noreply,
     socket
     |> assign(proposed_input: proposed)
     |> review(:propose_administrator, %{"proposed_administrator" => proposed})}
  end

  def handle_event("review_accept", _params, socket),
    do: {:noreply, review(socket, :accept_administrator, %{})}

  def handle_event("check_fee_admin_step", %{"action-id" => action_id}, socket),
    do: {:noreply, action_id |> FeeAdminActions.verify(opts(socket)) |> settled(socket)}

  def handle_event("cancel_fee_admin_review", %{"action-id" => action_id}, socket),
    do: {:noreply, action_id |> FeeAdminActions.cancel(opts(socket)) |> settled(socket)}

  def handle_event("start_new_fee_admin", %{"action-id" => action_id}, socket),
    do: {:noreply, action_id |> FeeAdminActions.start_new(opts(socket)) |> settled(socket)}

  def handle_event("clear_fee_admin", _params, socket) do
    send(self(), :reload_pool)
    {:noreply, socket |> assign(operation: nil, notice: nil) |> cleared()}
  end

  def handle_event("restore_fee_admin_operation", _params, socket) do
    case FeeAdminActions.open_operation(socket.assigns.auction.id, opts(socket)) do
      {:ok, %{operation: nil}} -> {:noreply, cleared(socket)}
      result -> {:noreply, settled(result, socket)}
    end
  end

  def handle_event(_other, _params, socket), do: {:noreply, socket}

  defp review(socket, kind, params) do
    socket.assigns.auction.id
    |> FeeAdminActions.prepare(socket.assigns.wallet, kind, params, opts(socket))
    |> settled(socket)
  end

  defp settled({:ok, %{operation: %{auction_id: auction_id} = operation}}, socket) do
    if auction_id == socket.assigns.auction.id do
      if operation.state == :confirmed, do: send(self(), :reload_pool)
      socket |> assign(operation: operation, notice: nil) |> published()
    else
      socket |> assign(operation: nil, notice: nil) |> cleared()
    end
  end

  defp settled({:ok, %{operation: nil}}, socket),
    do: socket |> assign(operation: nil) |> cleared()

  defp settled({:error, error}, socket),
    do: assign(socket, notice: notice(:error, refusal(error)))

  defp published(%{assigns: %{operation: operation}} = socket) do
    addressed(socket, "autolaunch-fee-admin:operation", %{
      action_id: operation.action_id,
      signer: operation.signer,
      chain_id: operation.envelope["chain_id"],
      lab: operation.envelope["metadata"]["lab"],
      lab_anchor: %{
        block_number: operation.envelope["arguments"]["block_number"],
        block_hash: operation.envelope["arguments"]["block_hash"]
      },
      terminal: not is_nil(operation.terminal_at),
      steps: FeeAdminActions.steps(operation)
    })
  end

  defp cleared(socket), do: addressed(socket, "autolaunch-fee-admin:cleared", %{})

  defp addressed(socket, event, payload),
    do: push_event(socket, event, Map.put(payload, :component_id, socket.assigns.id))

  defp adopt(socket, nil), do: assign(socket, wallet: nil, notice: nil)

  defp adopt(socket, address) do
    case FeeAdminActions.wallet_state(address, opts(socket)) do
      {:ok, %{signer: signer}} -> socket |> assign(wallet: signer, notice: nil) |> restored()
      {:error, error} -> refused(socket, address, refusal(error))
    end
  end

  defp restored(%{assigns: %{operation: nil}} = socket) do
    case FeeAdminActions.open_operation(socket.assigns.auction.id, opts(socket)) do
      {:ok, %{operation: %{}}} = result -> settled(result, socket)
      _none -> socket
    end
  end

  defp restored(socket), do: socket

  defp refused(socket, _address, reason) when reason in @unheld,
    do: assign(socket, wallet: nil, notice: notice(:error, reason))

  defp refused(socket, address, reason),
    do: assign(socket, wallet: address, notice: notice(:info, reason))

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  # Who the selected wallet is to this launch, read from the configuration the
  # pool page loaded. The contract, not this answer, decides what executes.
  defp role(_config, nil), do: :none

  defp role(config, wallet) do
    cond do
      Autolaunch.Chain.Address.equal?(config.administrator, wallet) -> :administrator
      same?(config.proposed_administrator, wallet) -> :proposed
      true -> :none
    end
  end

  defp same?(nil, _wallet), do: false
  defp same?(address, wallet), do: Autolaunch.Chain.Address.equal?(address, wallet)

  defp confirmed_now?(%{state: :confirmed}, _after), do: false
  defp confirmed_now?(_before, %{state: :confirmed}), do: true
  defp confirmed_now?(_before, _after), do: false

  defp sendable?(%{state: state, signer: signer, terminal_at: nil}, wallet)
       when state in [:prepared, :dispatched, :submitted],
       do: signer == wallet

  defp sendable?(_operation, _wallet), do: false

  defp title(:configure_subject), do: "Change the subject revenue lane"
  defp title(:propose_administrator), do: "Hand over the administrator role"
  defp title(:accept_administrator), do: "Accept the administrator role"

  defp review_rows(%{kind: :configure_subject} = operation) do
    [
      {"Subject lane now", lane(argument(operation, "current_splitter"))},
      {"Subject lane after this", lane(argument(operation, "splitter"))},
      {"Configuration version", argument(operation, "expected_version")},
      {"Launch", "##{argument(operation, "launch_id")} on #{argument(operation, "launchpad")}"}
    ]
  end

  defp review_rows(%{kind: :propose_administrator} = operation) do
    [
      {"Administrator now", argument(operation, "current_administrator")},
      {"Proposed administrator", argument(operation, "proposed_administrator")},
      {"Launch", "##{argument(operation, "launch_id")} on #{argument(operation, "launchpad")}"}
    ]
  end

  defp review_rows(%{kind: :accept_administrator} = operation) do
    [
      {"Administrator now", argument(operation, "current_administrator")},
      {"Administrator after this", operation.signer},
      {"Launch", "##{argument(operation, "launch_id")} on #{argument(operation, "launchpad")}"}
    ]
  end

  defp lane(nil), do: "Off"
  defp lane(splitter), do: "On · 1% to #{splitter}"

  defp current_state(:prepared), do: "Ready"
  defp current_state(:dispatched), do: "In your wallet"
  defp current_state(:submitted), do: "Sent"
  defp current_state(:confirmed), do: "Verified"
  defp current_state(:reverted), do: "Reverted"
  defp current_state(:unverified), do: "Unresolved"
  defp current_state(:not_sent), do: "Not sent"
  defp current_state(:cancelled), do: "Cancelled"
  defp current_state(:expired), do: "Expired"
  defp current_state(:submission_unknown), do: "Unresolved"

  defp confirmed_copy(%{kind: :configure_subject, result: result}),
    do:
      "Verified on the fork: the subject lane is now #{lane(result["splitter"])} (configuration version #{result["version"]}). " <>
        FeeAdminActions.future_only_copy()

  defp confirmed_copy(%{kind: :propose_administrator, result: result}),
    do:
      "Verified on the fork: #{result["proposed_administrator"]} can now accept the administrator role. Nothing changes until it does."

  defp confirmed_copy(%{kind: :accept_administrator, result: result}),
    do: "Verified on the fork: #{result["administrator"]} is now the fee administrator."

  defp settled_copy(%{state: :reverted}),
    do:
      "The launchpad refused this transaction and it reverted. The configuration may have changed since this review; check the current version above and review again."

  defp settled_copy(%{state: :unverified}),
    do: "This transaction did not record the change you reviewed."

  defp settled_copy(%{state: :submission_unknown}),
    do: "This one is still unresolved. Check your wallet activity before you try it again."

  defp settled_copy(%{state: :not_sent}), do: "Your wallet declined this. Nothing was sent."
  defp settled_copy(%{state: :cancelled}), do: WalletPressComponent.withdrawal_copy()

  defp settled_copy(%{state: :expired}),
    do: "This review expired before it was sent. Nothing was sent."

  defp notice(tone, reason), do: %{tone: tone, message: Map.get(@copy, reason, @generic)}

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil

  defp argument(%{envelope: envelope}, key), do: envelope["arguments"][key]

  defp short("0x" <> address),
    do: "0x#{String.slice(address, 0, 4)}…#{String.slice(address, -4, 4)}"

  defp short_hash("0x" <> hash),
    do: "0x#{String.slice(hash, 0, 6)}…#{String.slice(hash, -4, 4)}"
end
