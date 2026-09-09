defmodule AutolaunchWeb.BidSettlementComponent do
  @moduledoc """
  One bid position after its auction has ended, and what can be done with it.

  The auction's own answer decides what is on screen: a button to return the
  unspent currency, a button to claim the launch token, or the reason nothing
  can be done yet. The wallet Privy has selected drives every press; its address
  is proved against the mounted lease before any durable write, the browser
  reports a hash and stops, and every outcome on screen is the server's own read
  of that hash. Press plumbing is `WalletPressComponent`, shared with bids.
  """

  use AutolaunchWeb, :live_component

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [display_status: 1, display_time: 1]

  alias Autolaunch.Actors.Human
  alias Autolaunch.BidSettlementActions
  alias Autolaunch.Stocks.Amounts
  alias AutolaunchWeb.WalletPressComponent

  @copy %{
    authentication_required: "Sign in to settle this bid.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer: "Switch back to the wallet that placed this bid to continue.",
    invalid_address: "Switch back to the wallet that placed this bid to continue.",
    not_your_bid: "This bid was placed from a wallet this account does not hold.",
    position_not_on_chain: "This bid has no on-chain record to settle.",
    bid_not_found: "The auction has no record of this bid.",
    chain_unavailable:
      "The Base fork could not be read just now. Check that it is still running.",
    auction_not_started: "Bidding has not started on this auction.",
    auction_not_ended: "Bidding has not ended on this auction.",
    already_exited: "This bid has already been returned.",
    claim_not_open: "Tokens cannot be claimed yet.",
    nothing_to_claim: "This bid has no tokens to claim.",
    bid_not_exited: "Return this bid before claiming its tokens.",
    bid_needs_partial_exit_hints_unavailable:
      "This bid was only partly filled and the auction's records for it could not be traced. Try again in a moment.",
    settlement_reverted: "The auction refused this right now.",
    settlement_review_changed: "This review is out of date. Review it again.",
    settlement_step_moved: "This settlement moved on while you were looking. Check it again.",
    submitted_hash_conflict: "This step already has a transaction.",
    submitted_step_mismatch: "That transaction is not the step this settlement is waiting for.",
    settlement_operation_not_found: "That settlement is no longer open.",
    lab_config_changed: "The fork changed since this review. Review it again."
  }

  @generic "That did not go through. Try again in a moment."

  @impl true
  def update(%{wallet_press_result: result, wallet_press_lease: lease}, socket),
    do: {:ok, socket |> WalletPressComponent.consume(lease, result) |> notify_settled()}

  def update(assigns, socket) do
    {:ok,
     socket
     |> WalletPressComponent.update_scope(assigns)
     |> assign(assigns)
     |> assign_new(:market, fn -> nil end)
     |> assign_new(:wallet, fn -> nil end)
     |> assign_new(:notice, fn -> nil end)
     |> assign_new(:wallet_press_history, fn -> %{} end)
     |> assign_new(:operation, fn -> nil end)
     |> restored()}
  end

  @impl true
  def render(assigns) do
    auction = assigns.position.auction
    assigns = assign(assigns, auction: auction, actions: actions(assigns.position, auction))

    ~H"""
    <article
      id={@id}
      class="bid-settlement rg-panel rg-panel--surface"
      data-wallet-scope={WalletPressComponent.scope(assigns)}
      phx-hook="AutolaunchBidSettlement"
      phx-target={@myself}
    >
      <p class="autolaunch-kicker">{display_status(@position.status)}</p>
      <h3>{@auction.title}<span :if={@auction.token_symbol}> · {@auction.token_symbol}</span></h3>
      <dl>
        <div>
          <dt>Bid amount</dt>
          <dd>{@position.amount} {@auction.quote_token_symbol}</dd>
        </div>
        <div>
          <dt>Maximum price</dt>
          <dd title={@position.max_price}>
            {compact(@position.max_price)} {@auction.quote_token_symbol}
          </dd>
        </div>
        <div :if={@position.currency_refunded}>
          <dt>Returned</dt>
          <dd>{@position.currency_refunded} {@auction.quote_token_symbol}</dd>
        </div>
        <div :if={positive?(@position.tokens_filled)}>
          <dt>Tokens won</dt>
          <dd>{compact(@position.tokens_filled)} {@auction.token_symbol}</dd>
        </div>
        <div :if={positive?(@position.tokens_claimed)}>
          <dt>Tokens claimed</dt>
          <dd>{compact(@position.tokens_claimed)} {@auction.token_symbol}</dd>
        </div>
        <div>
          <dt>Wallet</dt>
          <dd class="bid-mono">{short(@position.owner_address)}</dd>
        </div>
        <div>
          <dt>Updated</dt>
          <dd>{display_time(@position.updated_at)}</dd>
        </div>
      </dl>

      <p
        :if={@notice}
        class="bid-notice"
        role={if @notice.tone == :error, do: "alert", else: "status"}
      >
        {@notice.message}
      </p>

      <p :for={reason <- reasons(@position, @market, @auction)} role="status">{reason}</p>

      <p :if={@actions != [] && !@authenticated} class="bid-empty">Sign in to settle this bid.</p>

      <div :if={@actions != [] && @authenticated && !@wallet} class="bid-empty">
        <p>Choose the wallet that placed this bid.</p>
        <Regent.Primitives.button type="button" data-settlement-connect>
          Connect or switch wallet
        </Regent.Primitives.button>
      </div>

      <div
        :if={@actions != [] && @authenticated && @wallet && !@operation}
        class="bid-settlement-actions"
      >
        <Regent.Primitives.button
          :for={label <- @actions}
          type="button"
          phx-click="review_settlement"
          phx-target={@myself}
        >
          {label}
        </Regent.Primitives.button>
      </div>

      <section
        :if={@operation && WalletPressComponent.scope(assigns)}
        id={"#{@id}-review"}
        class="bid-review"
        aria-label="Settlement review"
      >
        <dl>
          <div :if={argument(@operation, "currency_refunded")}>
            <dt>Returned to you</dt>
            <dd>
              {argument(@operation, "currency_refunded")} {argument(@operation, "currency_symbol")}
            </dd>
          </div>
          <div :if={argument(@operation, "tokens_filled")}>
            <dt>Tokens won</dt>
            <dd>
              {compact(argument(@operation, "tokens_filled"))} {argument(@operation, "token_symbol")}
            </dd>
          </div>
          <div :if={argument(@operation, "tokens_claimed")}>
            <dt>Tokens claimed</dt>
            <dd>
              {compact(argument(@operation, "tokens_claimed"))} {argument(@operation, "token_symbol")}
            </dd>
          </div>
          <div>
            <dt>Network</dt>
            <dd>{Autolaunch.ChainMode.label()} · chain 31337</dd>
          </div>
        </dl>
        <p class="bid-notice">{@operation.envelope["risk_copy"]}</p>

        <ol class="bid-steps" role="list" aria-label="Settlement progress">
          <li :for={step <- BidSettlementActions.steps(@operation)} data-step={step["step"]}>
            <span>{step_label(step["step"], @operation)}</span>
            <span class="bid-step-state">{step_state(@operation, step["step"])}</span>
            <span
              :if={BidSettlementActions.step_hash(@operation, step["step"])}
              class="bid-mono"
              data-local-transaction-hash
            >
              {short_hash(BidSettlementActions.step_hash(@operation, step["step"]))}
            </span>
          </li>
        </ol>

        <p :if={@operation.state == :confirmed} class="bid-settled" role="status">
          {confirmed_copy(@operation)}
        </p>
        <p :if={@operation.state in [:reverted, :unverified]} class="bid-settled" role="alert">
          {settled_copy(@operation)}
        </p>
        <p
          :if={@operation.state in [:not_sent, :cancelled, :expired, :submission_unknown]}
          class="bid-settled"
          role="status"
        >
          {settled_copy(@operation)}
        </p>

        <Regent.Primitives.button
          :if={sendable?(@operation, @wallet)}
          type="button"
          data-settlement-send={@operation.action_id}
          data-wallet-step={@operation.step}
          data-settlement-signer={@operation.signer}
        >
          {send_label(@operation)}
        </Regent.Primitives.button>
        <p :if={@operation.signer != @wallet && is_nil(@operation.terminal_at)} role="status">
          This settlement belongs to another wallet. Switch back to it to finish.
        </p>
        <Regent.Primitives.button
          :if={@operation.state == :submitted}
          type="button"
          phx-click="check_settlement_step"
          phx-value-action-id={@operation.action_id}
          phx-target={@myself}
          variant="secondary"
        >
          Check again
        </Regent.Primitives.button>
        <Regent.Primitives.button
          :if={@operation.state == :prepared && !started?(@operation)}
          type="button"
          phx-click="cancel_settlement_review"
          phx-value-action-id={@operation.action_id}
          phx-target={@myself}
          variant="secondary"
        >
          Cancel
        </Regent.Primitives.button>
        <Regent.Primitives.button
          :if={@operation.state in [:dispatched, :submitted]}
          type="button"
          phx-click="start_new_settlement"
          phx-value-action-id={@operation.action_id}
          phx-target={@myself}
          variant="secondary"
        >
          Start again
        </Regent.Primitives.button>
        <Regent.Primitives.button
          :if={@operation.terminal_at}
          type="button"
          phx-click="clear_settlement"
          phx-target={@myself}
          variant="secondary"
        >
          Done
        </Regent.Primitives.button>
      </section>
      <WalletPressComponent.history
        :if={WalletPressComponent.scope(assigns)}
        history={@wallet_press_history}
        target={@myself}
      />
    </article>
    """
  end

  @impl true
  def handle_event("wallet_press_dispatch", params, socket),
    do:
      {:noreply,
       WalletPressComponent.dispatch(socket, :bid_settlement, params, opts(socket), __MODULE__)}

  def handle_event("wallet_press_report", params, socket),
    do:
      {:noreply,
       WalletPressComponent.report(socket, :bid_settlement, params, opts(socket), __MODULE__)}

  def handle_event("wallet_press_verify", params, socket),
    do:
      {:noreply,
       WalletPressComponent.verify(socket, :bid_settlement, params, opts(socket), __MODULE__)}

  def handle_event("wallet_press_restore", params, socket),
    do: {:noreply, WalletPressComponent.restore(socket, :bid_settlement, params, opts(socket))}

  def handle_event("settlement_active_wallet", %{"address" => address}, socket),
    do: {:noreply, assign(socket, wallet: normalized(address), notice: nil)}

  def handle_event("review_settlement", _params, socket) do
    {:noreply,
     socket.assigns.position.id
     |> BidSettlementActions.prepare(socket.assigns.wallet, opts(socket))
     |> settled(socket)}
  end

  def handle_event("check_settlement_step", %{"action-id" => action_id}, socket),
    do: {:noreply, action_id |> BidSettlementActions.verify(opts(socket)) |> settled(socket)}

  def handle_event("cancel_settlement_review", %{"action-id" => action_id}, socket),
    do: {:noreply, action_id |> BidSettlementActions.cancel(opts(socket)) |> settled(socket)}

  def handle_event("start_new_settlement", %{"action-id" => action_id}, socket),
    do: {:noreply, action_id |> BidSettlementActions.start_new(opts(socket)) |> settled(socket)}

  def handle_event("clear_settlement", _params, socket),
    do: {:noreply, socket |> assign(operation: nil, notice: nil) |> refreshed()}

  def handle_event(_other, _params, socket), do: {:noreply, socket}

  # The exact action the position's status admits. A failed auction returns
  # the whole bid; a graduated one returns what the fill did not spend.
  defp actions(%{status: "returnable"}, %{state: :failed, quote_token_symbol: symbol}),
    do: ["Return #{symbol}"]

  defp actions(%{status: "returnable"}, %{quote_token_symbol: symbol}),
    do: ["Return unspent #{symbol}"]

  defp actions(%{status: "claimable"}, %{token_symbol: symbol}), do: ["Claim #{symbol} tokens"]
  defp actions(_position, _auction), do: []

  # The reason nothing can be done yet, from the auction's own blocks.
  defp reasons(%{status: "active"}, %{end_block: end_block}, _auction),
    do: ["Bidding ends at block #{end_block}."]

  defp reasons(%{status: "active"}, _market, _auction),
    do: ["Bidding has not ended on this auction."]

  defp reasons(
         %{status: "returned", tokens_filled: filled},
         %{claim_block: claim_block},
         _auction
       )
       when is_binary(filled) and filled != "" and filled != "0",
       do: ["Tokens can be claimed from block #{claim_block}."]

  defp reasons(%{status: "returned", currency_refunded: "0"}, _market, _auction),
    do: ["Your bid was fully spent; nothing to return."]

  defp reasons(_position, _market, _auction), do: []

  defp positive?(value) when is_binary(value) and value != "",
    do: Decimal.gt?(Decimal.new(value), 0)

  defp positive?(_value), do: false

  defp settled({:ok, %{operation: %{bid_position_id: id} = operation}}, socket)
       when id == socket.assigns.position.id,
       do: socket |> assign(operation: operation, notice: nil) |> published() |> notify_settled()

  defp settled({:ok, _other}, socket), do: socket

  defp settled({:error, error}, socket),
    do: assign(socket, notice: %{tone: :error, message: copy(refusal(error))})

  defp published(%{assigns: %{operation: operation}} = socket) do
    push_event(socket, "autolaunch-settlement:operation", %{
      component_id: socket.assigns.id,
      action_id: operation.action_id,
      signer: operation.signer,
      chain_id: operation.envelope["chain_id"],
      lab: operation.envelope["metadata"]["lab"],
      lab_anchor: %{
        block_number: operation.envelope["arguments"]["block_number"],
        block_hash: operation.envelope["arguments"]["block_hash"]
      },
      terminal: not is_nil(operation.terminal_at),
      steps: BidSettlementActions.steps(operation)
    })
  end

  # An open settlement of this position is shown as soon as the card mounts.
  defp restored(%{assigns: %{operation: nil, current_human_id: id}} = socket)
       when is_integer(id) do
    case BidSettlementActions.open_operations(opts(socket)) do
      {:ok, %{} = open} ->
        case Map.get(open, socket.assigns.position.id) do
          nil -> socket
          operation -> socket |> assign(:operation, operation) |> published()
        end

      _unavailable ->
        socket
    end
  end

  defp restored(socket), do: socket

  # A verified step changed the stored position, so the page that owns the
  # card reloads it; the card itself never guesses a status.
  defp notify_settled(%{assigns: %{operation: %{state: :confirmed}}} = socket),
    do: refreshed(socket)

  defp notify_settled(%{assigns: %{operation: %{step: :claim, state: :prepared}}} = socket),
    do: refreshed(socket)

  defp notify_settled(socket), do: socket

  defp refreshed(socket) do
    send(self(), {:bid_settlement_changed, socket.assigns.position.id})
    socket
  end

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  defp normalized(nil), do: nil

  defp normalized(address) do
    case Autolaunch.Chain.Address.normalize(address) do
      {:ok, normalized} -> normalized
      :error -> nil
    end
  end

  defp sendable?(%{state: state, signer: signer, terminal_at: nil}, wallet)
       when state in [:prepared, :dispatched, :submitted],
       do: signer == wallet

  defp sendable?(_operation, _wallet), do: false

  defp started?(operation),
    do:
      Enum.any?(
        BidSettlementActions.steps(operation),
        &BidSettlementActions.step_hash(operation, &1["step"])
      )

  defp send_label(%{step: :exit} = operation),
    do: "Return #{unspent(operation)}#{argument(operation, "currency_symbol")}"

  defp send_label(%{step: :claim} = operation),
    do: "Claim #{argument(operation, "token_symbol")} tokens"

  # A failed auction returns the whole bid; a graduated one returns what the
  # fill did not spend.
  defp unspent(operation), do: if(argument(operation, "graduated"), do: "unspent ", else: "")

  defp step_label("exit", operation),
    do: "Return #{unspent(operation)}#{argument(operation, "currency_symbol")}"

  defp step_label("claim", operation), do: "Claim #{argument(operation, "token_symbol")} tokens"

  defp step_state(%{step: step} = operation, step_name) do
    cond do
      Atom.to_string(step) == step_name -> current_state(operation.state)
      BidSettlementActions.step_hash(operation, step_name) -> "Confirmed"
      true -> "Waiting"
    end
  end

  defp current_state(:prepared), do: "Ready"
  defp current_state(:dispatched), do: "In your wallet"
  defp current_state(:submitted), do: "Sent"
  defp current_state(:confirmed), do: "Confirmed"
  defp current_state(:reverted), do: "Reverted"
  defp current_state(:unverified), do: "Unresolved"
  defp current_state(:not_sent), do: "Not sent"
  defp current_state(:cancelled), do: "Cancelled"
  defp current_state(:expired), do: "Expired"
  defp current_state(:submission_unknown), do: "Unresolved"

  defp confirmed_copy(%{result: %{"tokens_claimed_units" => tokens}} = operation),
    do:
      "#{compact(tokens)} #{argument(operation, "token_symbol")} tokens were delivered to your wallet."

  defp confirmed_copy(%{result: %{"currency_refunded_units" => refunded}} = operation),
    do: "#{refunded} #{argument(operation, "currency_symbol")} was returned to your wallet."

  defp confirmed_copy(_operation), do: "This settlement was verified on the fork."

  defp settled_copy(%{state: :reverted}), do: "This test transaction reverted."

  defp settled_copy(%{state: :unverified}),
    do: "This transaction did not record the settlement you reviewed."

  defp settled_copy(%{state: :submission_unknown}),
    do: "This one is still unresolved. Check your wallet activity before you try it again."

  defp settled_copy(%{state: :not_sent}), do: "Your wallet declined this."
  defp settled_copy(%{state: :cancelled}), do: WalletPressComponent.withdrawal_copy()
  defp settled_copy(%{state: :expired}), do: "This review expired before it was sent."

  defp copy(reason), do: Map.get(@copy, reason, @generic)

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil

  defp argument(%{envelope: envelope}, key), do: envelope["arguments"][key]

  defp compact(value) when is_binary(value) and value != "", do: Amounts.compact_decimal(value)
  defp compact(_value), do: "—"

  defp short("0x" <> address),
    do: "0x#{String.slice(address, 0, 4)}…#{String.slice(address, -4, 4)}"

  defp short_hash("0x" <> hash),
    do: "0x#{String.slice(hash, 0, 6)}…#{String.slice(hash, -4, 4)}"
end
