defmodule AutolaunchWeb.BidSettlementComponent do
  @moduledoc """
  One bid position after its auction has ended, and what can be done with it.

  The auction's own answer decides what is on screen: a button to return the
  unspent currency, a button to claim the launch token, or the reason nothing
  can be done yet.

  With `early`, the same position is an outbid bid while bidding is still open
  (`OutbidComponent` places it). The auction is asked in the background
  whether it would return the unspent money now, and again at most every half
  minute while it would not. Only once it would is the return reviewed and the
  button shown; the `parent` component is told either way, so its line can say
  when the money can come back.

  The wallet Privy has selected drives every press; its address
  is proved against the mounted lease before any durable write, the browser
  reports a hash and stops, and every outcome on screen is the server's own read
  of that hash. Press plumbing is `WalletPressComponent`, shared with bids.
  """

  use AutolaunchWeb, :live_component

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [display_status: 1, display_time: 1]

  alias Autolaunch.Actors.Human
  alias Autolaunch.{BidSettlementActions, Lab}
  alias Autolaunch.Stocks.Amounts
  alias AutolaunchWeb.{UsdValue, WalletPressComponent}

  @copy %{
    authentication_required: "Sign in to settle this bid.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer:
      "Switch back to the wallet you signed in with, or sign out and sign in with this one.",
    invalid_address:
      "Switch back to the wallet you signed in with, or sign out and sign in with this one.",
    not_your_bid:
      "This bid was placed from a different wallet. Sign in with that wallet to settle it.",
    position_not_on_chain: "This bid has no on-chain record to settle.",
    bid_not_found: "The auction has no record of this bid.",
    chain_unavailable: "Base could not be read just now. Try again in a moment.",
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
    lab_config_changed: "This review is out of date. Review it again."
  }

  @generic "That did not go through. Try again in a moment."

  # While bidding is open, the auction is asked again at most this often.
  @early_recheck_seconds 30
  # A prepared review lives ten minutes; an unsent early one is prepared again first.
  @early_refresh_ms 8 * 60_000

  @impl true
  def update(%{wallet_press_result: result, wallet_press_lease: lease}, socket),
    do:
      {:ok,
       socket |> WalletPressComponent.consume(lease, result) |> notify_settled() |> early_check()}

  def update(%{early_refresh: action_id}, socket) do
    case socket.assigns.operation do
      %{action_id: ^action_id, state: :prepared} = operation ->
        if started?(operation),
          do: {:ok, socket},
          else: {:ok, socket |> assign(operation: nil, early_state: nil) |> early_check()}

      _other ->
        {:ok, socket}
    end
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> WalletPressComponent.update_scope(assigns)
     |> assign(assigns)
     |> assign_new(:early, fn -> false end)
     |> assign_new(:early_state, fn -> nil end)
     |> assign_new(:market, fn -> nil end)
     |> assign_new(:wallet, fn -> nil end)
     |> assign_new(:notice, fn -> nil end)
     |> assign_new(:wallet_press_history, fn -> %{} end)
     |> assign_new(:operation, fn -> nil end)
     |> assign_new(:after_claim, fn -> :wallet end)
     |> assign(:stake_path, stake_path(assigns.position.auction))
     |> assign_usd_rate()
     |> early_check()}
  end

  @impl true
  def render(%{early: true} = assigns) do
    assigns = assign(assigns, :rate, assigns.usd_rate.result)

    ~H"""
    <div
      id={@id}
      class="bid-early-return"
      data-wallet-scope={WalletPressComponent.scope(assigns)}
      phx-hook="AutolaunchBidSettlement"
      phx-target={@myself}
    >
      <p
        :if={@notice}
        class="bid-notice"
        role={if @notice.tone == :error, do: "alert", else: "status"}
      >
        {@notice.message}
      </p>

      <Regent.Primitives.button
        :if={@authenticated && !@wallet && @early_state == :ready}
        type="button"
        variant="secondary"
        data-settlement-connect
      >
        Connect your wallet to get your unspent money back
      </Regent.Primitives.button>

      <div :if={@operation && WalletPressComponent.scope(assigns)} class="bid-early-return__offer">
        <p :if={@operation.state == :prepared}>
          <strong>
            {argument(@operation, "currency_refunded")} {argument(@operation, "currency_symbol")}
          </strong>
          <UsdValue.usd amount={argument(@operation, "currency_refunded")} rate={@rate} />
          comes back to your wallet now. The tokens this bid has bought are yours to claim after the auction.
        </p>
        <Regent.Primitives.button
          :if={sendable?(@operation, @wallet)}
          type="button"
          data-settlement-send={@operation.action_id}
          data-wallet-step={@operation.step}
          data-settlement-signer={@operation.signer}
          variant={if @operation.state == :prepared, do: "primary", else: "secondary"}
        >
          Get my unspent money back
        </Regent.Primitives.button>
        <p :if={early_progress(@operation)} role="status" aria-live="polite">
          {early_progress(@operation)}
        </p>
        <p :if={@operation.signer != @wallet && is_nil(@operation.terminal_at)} role="status">
          This belongs to another wallet. Switch back to it to finish.
        </p>
        <Regent.Primitives.button
          :if={@operation.state == :submitted}
          type="button"
          phx-click="wallet_press_verify"
          phx-value-action_id={@operation.action_id}
          phx-value-press_id={submitted_press(@operation)}
          phx-target={@myself}
          variant="secondary"
        >
          Check again
        </Regent.Primitives.button>
      </div>
    </div>
    """
  end

  def render(assigns) do
    auction = assigns.position.auction

    assigns =
      assign(assigns,
        auction: auction,
        actions: actions(assigns.position, auction),
        rate: assigns.usd_rate.result
      )

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
          <dd>
            {@position.amount} {@auction.quote_token_symbol}
            <UsdValue.usd amount={@position.amount} rate={@rate} />
          </dd>
        </div>
        <div>
          <dt>Maximum price</dt>
          <dd title={@position.max_price}>
            {compact(@position.max_price)} {@auction.quote_token_symbol}
            <UsdValue.usd amount={@position.max_price} rate={@rate} per="per token" />
          </dd>
        </div>
        <div :if={@position.currency_refunded}>
          <dt>Returned</dt>
          <dd>
            {@position.currency_refunded} {@auction.quote_token_symbol}
            <UsdValue.usd amount={@position.currency_refunded} rate={@rate} />
          </dd>
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
          <dd class="autolaunch-exact-value">{@position.owner_address}</dd>
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
      <p :if={@auction.state == :failed && @position.status == "returnable"}>
        The auction for {@auction.token_symbol} did not meet its minimum raise. Your bid returns in {@auction.quote_token_symbol} to the wallet shown above.
      </p>
      <.link
        :if={@stake_path && positive?(@position.tokens_claimed)}
        navigate={@stake_path}
        class="rg-button rg-button--primary"
      >
        {stake_label(@auction)} {@auction.token_symbol}
      </.link>

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
        <Regent.Primitives.button
          :if={@stake_path && @position.status == "claimable"}
          type="button"
          phx-click="review_settlement"
          phx-value-after="stake"
          phx-target={@myself}
          variant="secondary"
        >
          {stake_label(@auction)} {@auction.token_symbol}
        </Regent.Primitives.button>
      </div>

      <section
        :if={@operation && WalletPressComponent.scope(assigns)}
        id={"#{@id}-review"}
        class="bid-review"
        aria-label="Settlement review"
      >
        <p :if={@after_claim == :stake}>
          First claim to your wallet, then continue to staking. Your wallet confirms each step. Tokens are not locked.
        </p>
        <p class="autolaunch-exact-value">Receiving wallet: {@position.owner_address}</p>
        <dl>
          <div :if={argument(@operation, "currency_refunded")}>
            <dt>Returned to you</dt>
            <dd>
              {argument(@operation, "currency_refunded")} {argument(@operation, "currency_symbol")}
              <UsdValue.usd amount={argument(@operation, "currency_refunded")} rate={@rate} />
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
            <dd>{Lab.network_name(@operation.envelope["chain_id"])}</dd>
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
        <p
          :if={@operation.state in [:cancelled, :expired]}
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
          phx-click="wallet_press_verify"
          phx-value-action_id={@operation.action_id}
          phx-value-press_id={submitted_press(@operation)}
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
        label={&step_label/2}
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

  def handle_event("settlement_active_wallet", %{"address" => address}, socket),
    do: {:noreply, socket |> assign(wallet: normalized(address), notice: nil) |> early_check()}

  def handle_event("review_settlement", params, socket) do
    socket =
      assign(socket, :after_claim, if(params["after"] == "stake", do: :stake, else: :wallet))

    {:noreply,
     socket.assigns.position.id
     |> BidSettlementActions.prepare(socket.assigns.wallet, opts(socket))
     |> settled(socket)}
  end

  def handle_event("cancel_settlement_review", %{"action-id" => action_id}, socket),
    do: {:noreply, action_id |> BidSettlementActions.cancel(opts(socket)) |> settled(socket)}

  def handle_event("start_new_settlement", %{"action-id" => action_id}, socket),
    do: {:noreply, action_id |> BidSettlementActions.start_new(opts(socket)) |> settled(socket)}

  def handle_event("clear_settlement", _params, socket),
    do: {:noreply, socket |> assign(operation: nil, notice: nil) |> refreshed()}

  def handle_event(_other, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:early, {:ok, {wallet, result}}, socket) do
    socket = assign(socket, early_checked_at: System.monotonic_time(:second))

    cond do
      # The wallet changed or a review arrived while this was asked; the next
      # check starts from what is on screen now.
      wallet != socket.assigns.wallet or open_review?(socket.assigns.operation) ->
        {:noreply, socket |> assign(early_state: nil) |> early_check()}

      result in [:waiting, :ready] ->
        {:noreply, socket |> assign(early_state: result, notice: nil) |> early_told()}

      match?({:ok, _}, result) ->
        {:noreply,
         result |> settled(assign(socket, early_state: :ready)) |> early_told() |> early_later()}

      true ->
        {:noreply,
         socket
         |> assign(
           early_state: :refused,
           notice: %{tone: :error, message: copy(refusal(elem(result, 1)))}
         )
         |> early_told()}
    end
  end

  def handle_async(:early, {:exit, _reason}, socket),
    do:
      {:noreply,
       assign(socket,
         early_state: :refused,
         early_checked_at: System.monotonic_time(:second),
         notice: %{tone: :error, message: @generic}
       )}

  # The auction is asked while nothing of this card is with the wallet: first
  # on arrival, then again, at most every half minute, while the answer was
  # no. The return is reviewed once it would go through and a wallet is known.
  # A review that has been pressed is never replaced.
  defp early_check(%{assigns: %{early: true} = assigns} = socket) do
    cond do
      !assigns.authenticated -> socket
      assigns.early_state == :checking or open_review?(assigns.operation) -> socket
      match?(%{state: :confirmed}, assigns.operation) -> socket
      !early_due?(assigns) -> socket
      true -> start_early(socket)
    end
  end

  defp early_check(socket), do: socket

  # A review that is still open, whether or not it has been pressed.
  defp open_review?(%{terminal_at: nil}), do: true
  defp open_review?(_none_or_finished), do: false

  # Asked for the first time, or ready with a wallet and no review yet: one
  # just connected, or the review offered before lapsed. A recorded price
  # stays recorded, so a ready bid is not asked about again.
  defp early_due?(%{early_state: nil}), do: true
  defp early_due?(%{early_state: :ready, wallet: wallet}), do: is_binary(wallet)

  defp early_due?(%{early_checked_at: checked_at}),
    do: System.monotonic_time(:second) - checked_at >= @early_recheck_seconds

  # Read-only until the auction would return the money and a wallet is known:
  # only then is the return reviewed, so a bid still waiting never opens one.
  defp start_early(socket) do
    %{position: position, wallet: wallet} = socket.assigns
    opts = opts(socket)

    socket
    |> assign(early_state: :checking)
    |> start_async(:early, fn -> {wallet, early_offer(position, wallet, opts)} end)
  end

  defp early_offer(position, wallet, opts) do
    case BidSettlementActions.exit_ready?(position) do
      {:ok, true} when is_nil(wallet) -> :ready
      {:ok, true} -> BidSettlementActions.prepare(position.id, wallet, opts)
      {:ok, false} -> :waiting
      {:error, _reason} = refused -> refused
    end
  end

  defp early_told(%{assigns: %{parent: parent, early_state: state}} = socket) do
    send_update(AutolaunchWeb.OutbidComponent, id: parent, early_return: state)
    socket
  end

  defp early_later(%{assigns: %{operation: %{action_id: action_id}}} = socket) do
    send_update_after(
      self(),
      __MODULE__,
      [id: socket.assigns.id, early_refresh: action_id],
      @early_refresh_ms
    )

    socket
  end

  defp early_later(socket), do: socket

  # What is happening to an early return that has left the button, in a line.
  defp early_progress(%{state: :dispatched}), do: "Confirm in your wallet."
  defp early_progress(%{state: :submitted}), do: "Sending your money back…"

  defp early_progress(%{state: :confirmed} = operation), do: confirmed_copy(operation)

  defp early_progress(%{state: state} = operation) when state in [:cancelled, :expired],
    do: settled_copy(operation)

  defp early_progress(_operation), do: nil

  # The exact action the position's status admits. A failed auction returns
  # the whole bid; a graduated one returns what the fill did not spend.
  defp stake_path(%{state: :graduated, id: id}) do
    case Autolaunch.get_public_token_by_auction(id) do
      {:ok, %{id: token_id}} -> "/tokens/#{token_id}#stake"
      _ -> nil
    end
  end

  defp stake_path(_auction), do: nil
  defp stake_label(%{kind: :agent}), do: "Revstake"
  defp stake_label(_auction), do: "Memestake"

  defp actions(%{status: "returnable"}, %{state: :failed, quote_token_symbol: symbol}),
    do: ["Return #{symbol}"]

  defp actions(%{status: "returnable"}, %{quote_token_symbol: symbol}),
    do: ["Return unspent #{symbol}"]

  defp actions(%{status: "claimable"}, %{token_symbol: symbol}), do: ["Claim #{symbol} to wallet"]
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

  # A verified step changed the stored position, so the page that owns the
  # card reloads it; the card itself never guesses a status.
  defp notify_settled(
         %{
           assigns: %{
             operation: %{state: :confirmed, step: :claim},
             after_claim: :stake,
             stake_path: path
           }
         } = socket
       )
       when is_binary(path) do
    amount = argument(socket.assigns.operation, "tokens_claimed") || ""

    path =
      String.replace_suffix(path, "#stake", "?" <> URI.encode_query(%{stake: amount}) <> "#stake")

    send(self(), {:stake_claimed_tokens, path})
    assign(socket, after_claim: :wallet)
  end

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
    do:
      "Withdraw #{argument(operation, "currency_refunded")} #{argument(operation, "currency_symbol")}"

  defp send_label(%{step: :claim} = operation),
    do: "Claim #{argument(operation, "token_symbol")} to wallet"

  # A failed auction returns the whole bid; a graduated one returns what the
  # fill did not spend.
  defp unspent(operation), do: if(argument(operation, "graduated"), do: "unspent ", else: "")

  defp step_label("exit", operation),
    do: "Withdraw #{unspent(operation)}#{argument(operation, "currency_symbol")}"

  defp step_label("claim", operation),
    do: "Claim #{argument(operation, "token_symbol")} to wallet"

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
  defp current_state(:cancelled), do: "Cancelled"
  defp current_state(:expired), do: "Expired"

  defp confirmed_copy(%{result: %{"tokens_claimed_units" => tokens}} = operation),
    do:
      "#{compact(tokens)} #{argument(operation, "token_symbol")} tokens were delivered to your wallet."

  defp confirmed_copy(%{result: %{"currency_refunded_units" => refunded}} = operation),
    do: "#{refunded} #{argument(operation, "currency_symbol")} was returned to your wallet."

  defp confirmed_copy(%{envelope: %{"chain_id" => chain_id}}) do
    if Lab.test_chain?(chain_id),
      do: "This settlement was verified on the fork.",
      else: "This settlement is confirmed on Base."
  end

  defp settled_copy(%{state: :cancelled}), do: WalletPressComponent.withdrawal_copy()
  defp settled_copy(%{state: :expired}), do: "This review expired before it was sent."

  # The press whose transaction the card is waiting on: the submitted attempt of
  # the current step, whose hash the chain has not answered about yet.
  defp submitted_press(operation),
    do:
      Enum.find_value(
        operation.attempts,
        &(&1.state == :submitted and &1.step == operation.step and &1.id)
      )

  defp copy(:chain_unavailable) do
    if Lab.test_chain?(),
      do: "The Base fork could not be read just now. Check that it is still running.",
      else: Map.fetch!(@copy, :chain_unavailable)
  end

  defp copy(reason), do: Map.get(@copy, reason, @generic)

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil

  defp argument(%{envelope: envelope}, key), do: envelope["arguments"][key]

  # The dollar price of the bid's currency, read once per auction and apart
  # from the card, so a slow price never holds a settlement back.
  defp assign_usd_rate(%{assigns: %{position: %{auction: %{id: id}}, usd_rate_for: id}} = socket),
    do: socket

  defp assign_usd_rate(%{assigns: %{position: %{auction: auction}}} = socket) do
    socket
    |> assign(:usd_rate_for, auction.id)
    |> UsdValue.assign_rate(:usd_rate, :base, fn -> {:ok, %{usd_rate: UsdValue.rate(auction)}} end)
  end

  defp compact(value) when is_binary(value) and value != "", do: Amounts.compact_decimal(value)
  defp compact(_value), do: "—"

  defp short_hash("0x" <> hash),
    do: "0x#{String.slice(hash, 0, 6)}…#{String.slice(hash, -4, 4)}"
end
