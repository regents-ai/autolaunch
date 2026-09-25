defmodule AutolaunchWeb.BidSettlementComponent do
  @moduledoc """
  One bid position after its auction has ended, and what can be done with it.

  The auction's own answer decides what is on screen: a button to return the
  unspent currency, a button to claim the launch token, or the reason nothing
  can be done yet.

  With `early`, the same position is one of the bidder's bids while bidding is
  still open (`OutbidComponent` places it under an outbid bid, or one sharing
  at the price). The auction is asked in the background when the unspent money
  can come back, and again at most every half minute while it cannot yet; the
  answer is the card's one line (`AuctionBook.return_line/1`). Once it can, the
  return is reviewed and the button shown. When the price has passed the bid
  but the auction has not recorded it yet, the same button first records the
  price (its own review, one wallet confirmation); once that is confirmed, the
  auction is asked again at once and the return is reviewed against the
  recorded price.

  The wallet the customer signed in with, read from the mounted lease, drives
  every review and press; a press opens that wallet, or Privy's connect step when
  this tab has not connected it, and a note names both wallets while the browser
  is on another one. The browser reports a hash and stops, and every outcome on
  screen is the server's own read of that hash. Press plumbing is
  `WalletPressComponent`, shared with bids.
  """

  use AutolaunchWeb, :live_component

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [display_time: 1]

  alias Autolaunch.Actors.Human
  alias Autolaunch.{BidActions, BidSettlementActions, Lab}
  alias Autolaunch.Chain.Rpc
  alias Autolaunch.Stocks.Amounts
  alias AutolaunchWeb.Components.AuctionBook
  alias AutolaunchWeb.{Paths, SignedInWallet, TokenDisplay, UsdValue, WalletPressComponent}

  @copy %{
    authentication_required: "Sign in to settle this bid.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer: "You are now signed in with a different wallet. Reload the page to continue.",
    invalid_address:
      "You are now signed in with a different wallet. Reload the page to continue.",
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
       socket
       |> WalletPressComponent.consume(lease, result)
       |> recorded()
       |> notify_settled()
       |> early_check()}

  def update(%{early_refresh: action_id}, socket) do
    case socket.assigns.operation do
      %{action_id: ^action_id, state: :prepared} = operation ->
        if started?(operation),
          do: {:ok, socket},
          else: {:ok, socket |> assign(operation: nil, checked_at: nil) |> early_check()}

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
     |> assign_new(:status, fn -> nil end)
     |> assign_new(:checking, fn -> false end)
     |> assign_new(:checked_at, fn -> nil end)
     |> assign_new(:recorded, fn -> false end)
     |> assign_new(:market, fn -> nil end)
     |> assign_new(:wallet, fn -> nil end)
     |> assign_new(:browser_wallets, fn -> [] end)
     |> assign_new(:notice, fn -> nil end)
     |> assign_new(:wallet_press_history, fn -> %{} end)
     |> assign_new(:operation, fn -> nil end)
     |> assign_new(:after_claim, fn -> :wallet end)
     |> assign(:stake_path, stake_path(assigns.position.auction))
     |> assign_usd_rate()
     |> SignedInWallet.adopt(&adopt/2)
     |> early_check()}
  end

  @impl true
  def render(%{early: true} = assigns) do
    auction = assigns.position.auction

    assigns =
      assign(assigns,
        rate: assigns.usd_rate.result,
        auction: auction,
        line: line(assigns.status, auction)
      )

    ~H"""
    <div
      id={@id}
      class="bid-early-return"
      data-wallet-scope={WalletPressComponent.scope(assigns)}
      phx-hook="AutolaunchBidSettlement"
      phx-target={@myself}
    >
      <AuctionBook.return_line
        :if={@line}
        id={"#{@id}-when"}
        status={@line}
        unit={@auction.quote_token_symbol}
        usd_rate={@rate}
        ends_at={@auction.estimated_end_at}
      />
      <p
        :if={@notice}
        class="bid-notice"
        role={if @notice.tone == :error, do: "alert", else: "status"}
      >
        {@notice.message}
      </p>

      <div :if={@operation && WalletPressComponent.scope(assigns)} class="bid-early-return__offer">
        <p :if={@operation.step == :exit && @operation.state == :prepared}>
          <strong>
            {argument(@operation, "currency_refunded")} {argument(@operation, "currency_symbol")}
          </strong>
          <UsdValue.usd amount={argument(@operation, "currency_refunded")} rate={@rate} />
          comes back to your wallet now. The tokens this bid has bought are yours to claim after the auction.
        </p>
        <ol
          :if={@operation.step == :record || @recorded}
          class="bid-steps"
          role="list"
          aria-label="Getting your money back"
        >
          <li data-step="record">
            <span>Record the new price</span>
            <span class="bid-step-state">{record_state(@operation)}</span>
          </li>
          <li data-step="exit">
            <span>Send your unspent money back</span>
            <span class="bid-step-state">{return_state(@operation)}</span>
          </li>
        </ol>
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
        <SignedInWallet.note
          :if={sendable?(@operation, @wallet)}
          signed_in={@wallet}
          browser={@browser_wallets}
        />
        <p :if={early_progress(@operation)} role="status" aria-live="polite">
          {early_progress(@operation)}
        </p>
        <p :if={@operation.signer != @wallet && is_nil(@operation.terminal_at)} role="status">
          This belongs to another wallet. Sign in with that wallet to finish.
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
        action: action(assigns.position, auction),
        standing: standing(assigns.position, auction),
        rate: assigns.usd_rate.result
      )

    ~H"""
    <article
      id={@id}
      class="bid-settlement"
      data-wallet-scope={WalletPressComponent.scope(assigns)}
      phx-hook="AutolaunchBidSettlement"
      phx-target={@myself}
    >
      <header class="bid-settlement__head">
        <Regent.Primitives.status tone={elem(@standing, 1)}>
          {elem(@standing, 0)}
        </Regent.Primitives.status>
        <span class="bid-settlement__updated">Updated {display_time(@position.updated_at)}</span>
      </header>
      <dl class="bid-settlement__facts">
        <div>
          <dt>Your bid</dt>
          <dd>
            <TokenDisplay.price amount={@position.amount} unit={@auction.quote_token_symbol} />
            <UsdValue.usd amount={@position.amount} rate={@rate} />
          </dd>
        </div>
        <div>
          <dt>Max price</dt>
          <dd>
            <TokenDisplay.price
              amount={@position.max_price}
              unit={@auction.quote_token_symbol}
              round={:down}
            />
            <UsdValue.usd amount={@position.max_price} rate={@rate} per="per token" />
          </dd>
        </div>
        <div :if={@position.currency_refunded}>
          <dt>Returned</dt>
          <dd>
            <TokenDisplay.price
              amount={@position.currency_refunded}
              unit={@auction.quote_token_symbol}
              round={:down}
            />
            <UsdValue.usd amount={@position.currency_refunded} rate={@rate} />
          </dd>
        </div>
        <div :if={positive?(@position.tokens_filled)}>
          <dt>Tokens won</dt>
          <dd>
            {tokens(@position.tokens_filled)} {@auction.token_symbol}
          </dd>
        </div>
        <div :if={positive?(@position.tokens_claimed)}>
          <dt>Tokens claimed</dt>
          <dd>
            {tokens(@position.tokens_claimed)} {@auction.token_symbol}
          </dd>
        </div>
        <div>
          <dt>Wallet</dt>
          <dd class="bid-settlement__address" title={@position.owner_address}>
            {SignedInWallet.short(@position.owner_address)}
          </dd>
        </div>
      </dl>

      <p
        :if={@notice}
        class="bid-notice"
        role={if @notice.tone == :error, do: "alert", else: "status"}
      >
        {@notice.message}
      </p>

      <p
        :for={reason <- reasons(@position, @market, @auction)}
        class="bid-settlement__note"
        role="status"
      >
        {reason}
      </p>
      <p
        :if={@auction.state == :failed && @position.status == "returnable"}
        class="bid-settlement__note"
      >
        The auction for {@auction.token_symbol} did not meet its minimum raise. Your whole bid comes back in {@auction.quote_token_symbol} to the wallet above.
      </p>
      <.link
        :if={@stake_path && positive?(@position.tokens_claimed)}
        navigate={@stake_path}
        class="rg-button rg-button--primary"
      >
        {stake_label(@auction)} {@auction.token_symbol}
      </.link>

      <p :if={@action && !@authenticated} class="bid-empty">Sign in to settle this bid.</p>

      <div
        :if={@action && @authenticated && @wallet && !@operation}
        class="bid-settlement-actions"
      >
        <Regent.Primitives.button type="button" phx-click="review_settlement" phx-target={@myself}>
          {@action}
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
        <dl class="bid-settlement__facts">
          <div :if={argument(@operation, "currency_refunded")}>
            <dt>Comes back to you</dt>
            <dd>
              <TokenDisplay.price
                amount={argument(@operation, "currency_refunded")}
                unit={argument(@operation, "currency_symbol")}
                round={:down}
              />
              <UsdValue.usd amount={argument(@operation, "currency_refunded")} rate={@rate} />
            </dd>
          </div>
          <div :if={argument(@operation, "tokens_filled")}>
            <dt>Tokens won</dt>
            <dd>
              {tokens(argument(@operation, "tokens_filled"))} {argument(@operation, "token_symbol")}
            </dd>
          </div>
          <div :if={argument(@operation, "tokens_claimed")}>
            <dt>Tokens claimed</dt>
            <dd>
              {tokens(argument(@operation, "tokens_claimed"))} {argument(@operation, "token_symbol")}
            </dd>
          </div>
          <div>
            <dt>Receiving wallet</dt>
            <dd class="bid-settlement__address" title={@position.owner_address}>
              {SignedInWallet.short(@position.owner_address)}
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

        <SignedInWallet.note
          :if={sendable?(@operation, @wallet)}
          signed_in={@wallet}
          browser={@browser_wallets}
        />
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
          This settlement belongs to another wallet. Sign in with that wallet to finish.
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

  # The wallets this tab has connected, whenever they change: only for the note.
  def handle_event("browser_wallets", params, socket),
    do: {:noreply, assign(socket, browser_wallets: SignedInWallet.reported(params))}

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
  def handle_async(:early, {:ok, {wallet, {status, prepared}}}, socket) do
    socket = assign(socket, checking: false, checked_at: System.monotonic_time(:second))

    cond do
      # Signed in with another wallet while this was asked; the next check
      # starts from the wallet on screen now.
      wallet != socket.assigns.wallet ->
        {:noreply, socket |> assign(checked_at: nil) |> early_check()}

      status == :refused ->
        {:noreply,
         assign(socket,
           status: :refused,
           notice: %{tone: :error, message: copy(refusal(prepared))}
         )}

      # A review with a press on it is never replaced.
      held?(socket.assigns.operation) ->
        {:noreply, assign(socket, status: status)}

      true ->
        {:noreply, socket |> assign(status: status, notice: nil) |> offered(prepared)}
    end
  end

  def handle_async(:early, {:exit, _reason}, socket),
    do:
      {:noreply,
       assign(socket,
         status: :refused,
         checking: false,
         checked_at: System.monotonic_time(:second),
         notice: %{tone: :error, message: @generic}
       )}

  # The auction is asked while nothing of this card is with the wallet: first
  # on arrival, then again, at most every half minute, while the money cannot
  # come back yet. An unpressed review to record the price is asked about
  # too, so a price someone else records in the meantime turns it into the
  # return itself.
  defp early_check(%{assigns: %{early: true} = assigns} = socket) do
    cond do
      !assigns.authenticated -> socket
      assigns.checking or held?(assigns.operation) -> socket
      !early_due?(assigns) -> socket
      true -> start_early(socket)
    end
  end

  defp early_check(socket), do: socket

  # A review the card keeps: a return still open, one that went through, or a
  # record of the price that has been pressed.
  defp held?(%{terminal_at: nil, step: :record} = operation),
    do: operation.state != :prepared or started?(operation)

  defp held?(%{terminal_at: nil}), do: true
  defp held?(%{state: :confirmed}), do: true
  defp held?(_none_or_finished), do: false

  # Asked for the first time, or again at once: signed in with another
  # wallet, a price was recorded or the review offered before lapsed.
  defp early_due?(%{checked_at: nil}), do: true

  defp early_due?(%{checked_at: checked_at}),
    do: System.monotonic_time(:second) - checked_at >= @early_recheck_seconds

  defp start_early(socket) do
    %{position: position, wallet: wallet, operation: operation} = socket.assigns
    offered = offered_step(operation)
    opts = opts(socket)

    socket
    |> assign(checking: true)
    |> start_async(:early, fn -> {wallet, early_offer(position, wallet, offered, opts)} end)
  end

  # Read-only until the money can come back, now or after recording the
  # price, and a wallet is known: only then is a review prepared, and a review
  # already offered for the same answer is kept.
  defp early_offer(position, wallet, offered, opts) do
    case BidSettlementActions.return_status(position) do
      {:ok, status} when status in [:now, :record] and is_binary(wallet) and status != offered ->
        {status, BidSettlementActions.prepare(position.id, wallet, opts)}

      {:ok, status} ->
        {status, nil}

      {:error, error} ->
        {:refused, error}
    end
  end

  defp offered_step(%{terminal_at: nil, step: :record}), do: :record
  defp offered_step(_operation), do: nil

  defp offered(socket, nil), do: socket
  defp offered(socket, {:ok, _prepared} = result), do: result |> settled(socket) |> early_later()
  defp offered(socket, {:error, _error} = result), do: settled(result, socket)

  # A confirmed record of the price makes the return possible: the auction is
  # asked again at once, and the return reviewed against the recorded price.
  defp recorded(%{assigns: %{operation: %{step: :record, state: :confirmed}}} = socket),
    do: assign(socket, operation: nil, recorded: true, checked_at: nil)

  defp recorded(socket), do: socket

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

  # The one line under the bid, from the auction's answer; the minimum still
  # to raise is the auction's own minimum less what it has raised.
  defp line({:minimum, raised}, auction) do
    missing = String.to_integer(auction.required_currency_raised) - raised
    {:minimum, Rpc.format_units(max(missing, 0), auction.quote_token_decimals)}
  end

  defp line(status, _auction) when status in [:now, :record, :buying], do: status
  defp line(_status, _auction), do: nil

  defp record_state(%{step: :record} = operation), do: current_state(operation.state)
  defp record_state(_operation), do: "Confirmed"

  defp return_state(%{step: :record}), do: "Next"
  defp return_state(operation), do: current_state(operation.state)

  # What is happening to an early return that has left the button, in a line.
  defp early_progress(%{state: :dispatched}), do: "Confirm in your wallet."
  defp early_progress(%{state: :submitted, step: :record}), do: "Recording the new price…"
  defp early_progress(%{state: :submitted}), do: "Sending your money back…"

  defp early_progress(%{state: :confirmed} = operation), do: confirmed_copy(operation)

  defp early_progress(%{state: state} = operation) when state in [:cancelled, :expired],
    do: settled_copy(operation)

  defp early_progress(_operation), do: nil

  # Where claimed tokens are staked, once the auction's token exists.
  defp stake_path(%{state: :graduated, id: id} = auction) do
    case Autolaunch.get_public_token_by_auction(id) do
      {:ok, %{}} -> Paths.token(auction) <> "#stake"
      _ -> nil
    end
  end

  defp stake_path(_auction), do: nil
  defp stake_label(%{kind: :agent}), do: "Revstake"
  defp stake_label(_auction), do: "Memestake"

  # The exact action the position's status admits. A failed auction returns
  # the whole bid; a graduated one returns what the fill did not spend.
  defp action(%{status: "returnable"}, %{state: :failed, quote_token_symbol: symbol}),
    do: "Withdraw #{symbol}"

  defp action(%{status: "returnable"} = position, auction) do
    if spent?(position),
      do: "Claim #{auction.token_symbol}",
      else: "Withdraw unspent #{auction.quote_token_symbol}"
  end

  defp action(%{status: "claimable"}, %{token_symbol: symbol}), do: "Claim #{symbol}"
  defp action(_position, _auction), do: nil

  # Where the bid's settlement stands, with its tone, for the card's chip.
  defp standing(%{status: "active"}, _auction), do: {"In the auction", "neutral"}
  defp standing(%{status: "returnable"}, %{state: :failed}), do: {"Refund ready", "info"}

  defp standing(%{status: "returnable"} = position, _auction),
    do: if(spent?(position), do: {"Ready to claim", "info"}, else: {"Ready to withdraw", "info"})

  defp standing(%{status: "claimable"}, _auction), do: {"Ready to claim", "info"}

  defp standing(%{status: "returned"} = position, _auction),
    do:
      if(positive?(position.tokens_filled),
        do: {"Claim opens soon", "neutral"},
        else: {"Completed", "success"}
      )

  defp standing(%{status: "claimed"}, _auction), do: {"Completed", "success"}

  @doc """
  Whether an unsettled bid on a launched auction was wholly spent: its
  maximum is above the final price, so settling returns nothing and only
  delivers its tokens.
  """
  def spent?(%{status: "returnable", max_price: max, auction: %{state: :graduated} = auction}) do
    decimals = auction.quote_token_decimals

    with {:ok, max} <- BidActions.price_q96(max, decimals),
         {:ok, price} <- BidActions.price_q96(auction.current_clearing_price, decimals),
         do: max > price,
         else: (_unknown -> false)
  end

  def spent?(_position), do: false

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

  # The signed-in wallet, once per lease; another one asks the auction again.
  defp adopt(%{assigns: %{wallet: wallet}} = socket, wallet), do: socket
  defp adopt(socket, wallet), do: assign(socket, wallet: wallet, notice: nil, checked_at: nil)

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

  defp step_label("record", _operation), do: "Record the new price"

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
      "#{tokens(tokens)} #{argument(operation, "token_symbol")} tokens were delivered to your wallet."

  defp confirmed_copy(%{result: %{"currency_refunded_units" => refunded}} = operation),
    do:
      "#{TokenDisplay.short(refunded, :down)} #{argument(operation, "currency_symbol")} was returned to your wallet."

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

  # A token amount cut to four significant digits, never rounded up, its whole
  # part grouped in thousands: 68493.15 reads as 68,490.
  defp tokens(value), do: value |> TokenDisplay.short(:down) |> Amounts.grouped()

  defp short_hash("0x" <> hash),
    do: "0x#{String.slice(hash, 0, 6)}…#{String.slice(hash, -4, 4)}"
end
