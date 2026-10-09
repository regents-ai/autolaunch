defmodule AutolaunchWeb.BidSettlementComponent do
  @moduledoc """
  One bid position after its auction has ended, and what can be done with it.

  The auction's own answer decides what is on screen: a button to return the
  unspent currency, a button to claim the launch token, or the reason nothing
  can be done yet. The settlement is prepared as soon as the card knows the
  wallet that may act, so the button sends at once.

  With `early`, the same position is one of the bidder's bids while bidding is
  still open (`OutbidComponent` places it under an outbid bid, or one sharing
  at the price). The auction is asked in the background when the unspent money
  can come back, and again at most every half minute while it cannot yet; the
  answer is the card's one line (`AuctionBook.return_line/1`). Once it can, the
  return is prepared and the button shown. When the price has passed the bid
  but the auction has not recorded it yet, the same button first records the
  price (its own review, one wallet confirmation); once that is confirmed, the
  auction is asked again at once and the return is prepared against the
  recorded price.

  The wallet that acts is Privy's active wallet when the signed-in account
  links it (`AutolaunchWeb.OnchainSteps`), and only the wallet that placed the
  bid can settle it; a note names both while the wallet app has another one
  open. Nothing is stored while a settlement is on its way: the review lives on
  this page only, the browser reports a hash and stops, and every outcome on
  screen is the server's own read of that hash against the review it was sent
  from. A confirmed return or claim is recorded on the position from its
  receipt.

  Both cards answer the page tool that settles a bid, named by the bid's id
  (`AutolaunchWeb.AgentPress`): the call presses what the card offers now.
  """

  use AutolaunchWeb, :live_component

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [display_time: 1]
  import AutolaunchWeb.Components.StepState

  alias Autolaunch.Actors.Human
  alias Autolaunch.{BidActions, BidSettlementActions, Lab, LabProjection}
  alias Autolaunch.Chain.{Client, Rpc}
  alias Autolaunch.Stocks.Amounts
  alias AutolaunchWeb.{AgentPress, OnchainSteps, Paths, TokenDisplay, UsdValue}
  alias AutolaunchWeb.Components.{AuctionBook, SwapForm}
  alias RegentChain.{Address, Presses, Review}

  @copy %{
    authentication_required: "Sign in to settle this bid.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer: "Switch to a wallet on your account in your wallet app, then press again.",
    invalid_address: "Connect your wallet, then press again.",
    not_your_bid:
      "This bid was placed from a different wallet. Switch to that wallet to settle it.",
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
    settlement_reverted: "The auction refused this right now."
  }

  @generic "That did not go through. Try again in a moment."

  # While bidding is open, the auction is asked again at most this often.
  @early_recheck_seconds 30
  # A review that has sent nothing is prepared again this often, so it stays
  # current with the auction.
  @refresh_ms 8 * 60_000

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> OnchainSteps.init(&followed/1)
     |> assign(
       signer: nil,
       mismatch: nil,
       prepared: nil,
       prepared_for: nil,
       preparing: nil,
       reviews: %{},
       notice: nil,
       settled: nil,
       status: nil,
       checking: false,
       checked_at: nil,
       recorded: false
     )}
  end

  @impl true
  def update(%{refresh_review: review_id}, socket) do
    case socket.assigns.review do
      %{id: ^review_id} = review ->
        if started?(socket.assigns.presses, review),
          do: {:ok, socket},
          else: {:ok, socket |> withdrawn() |> assign(checked_at: nil) |> offer()}

      _other ->
        {:ok, socket}
    end
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:early, fn -> false end)
     |> assign_new(:market, fn -> nil end)
     |> assign(:stake_path, stake_path(assigns.position.auction))
     |> assign_usd_rate()
     |> OnchainSteps.adopt()
     |> followed()
     |> offer()}
  end

  # The card follows the wallet that may act. A review is built for one
  # signer, so another one withdraws it, and an early card asks again.
  defp followed(socket) do
    %{linked: linked, active: active} = socket.assigns
    signer = OnchainSteps.signer(linked, active)
    socket = assign(socket, mismatch: OnchainSteps.mismatch_note(linked, active))

    if signer == socket.assigns.signer,
      do: socket,
      else: socket |> assign(signer: signer, checked_at: nil) |> reviewed_for_signer(signer)
  end

  defp reviewed_for_signer(%{assigns: %{review: %{signer: signer}}} = socket, signer), do: socket
  defp reviewed_for_signer(%{assigns: %{review: nil}} = socket, _signer), do: socket
  defp reviewed_for_signer(socket, _signer), do: withdrawn(socket)

  defp withdrawn(socket),
    do: socket |> assign(prepared_for: nil) |> put_review(nil, nil)

  defp offer(%{assigns: %{early: true}} = socket), do: early_check(socket)
  defp offer(socket), do: prepare_when_ready(socket)

  @impl true
  def render(%{early: true} = assigns) do
    auction = assigns.position.auction
    steps = steps(assigns)

    assigns =
      assign(assigns,
        rate: assigns.usd_rate.result,
        auction: auction,
        line: line(assigns.status, auction),
        steps: steps,
        next_step: early_next(assigns, steps),
        other_wallet: other_wallet(assigns)
      )

    ~H"""
    <div
      id={@id}
      class="bid-early-return"
      phx-hook="OnchainSteps"
      data-agent-tools="autolaunch_settle_bid"
      data-agent-bid={@position.bid_id}
    >
      <div hidden={!@line}>
        <AuctionBook.return_line
          :if={@line}
          id={"#{@id}-when"}
          status={@line}
          unit={@auction.quote_token_symbol}
          usd_rate={@rate}
          ends_at={@auction.estimated_end_at}
        />
      </div>
      <p class="bid-notice" role="status" hidden={!@notice}>{@notice}</p>

      <div class="bid-early-return__offer" hidden={!@authenticated}>
        <p hidden={!returning(@prepared)}>
          <%= if returning(@prepared) do %>
            <TokenDisplay.price
              amount={@prepared.facts.currency_refunded}
              unit={@prepared.facts.currency_symbol}
              round={:down}
            />
            <UsdValue.usd amount={@prepared.facts.currency_refunded} rate={@rate} />
            comes back to your wallet now. The tokens this bid has bought are yours to claim after the auction.
          <% end %>
        </p>
        <ol
          class="bid-steps"
          role="list"
          aria-label="Getting your money back"
          hidden={!(recording?(@review) || @recorded)}
        >
          <li data-step="record">
            <span>Record the new price</span>
            <.step_state state={record_state(@steps, @recorded)} />
          </li>
          <li data-step="exit">
            <span>Send your unspent money back</span>
            <.step_state state={return_state(@steps)} />
          </li>
        </ol>
        <p role="status" aria-live="polite" hidden={!early_progress(@steps, @settled)}>
          <TokenDisplay.marked
            text={early_progress(@steps, @settled) || ""}
            tickers={tickers(@auction)}
          />
        </p>
        <p role="status" hidden={!@other_wallet}>{@other_wallet}</p>
        <p class="bid-notice" role="status" hidden={!@press_note}>{@press_note}</p>
        <SwapForm.wallet_step
          next_step={@next_step}
          steps={@steps}
          reverted={reverted(@steps, @auction)}
          signer={@review && @review.signer}
          chain_name={@review && @review.chain.name}
          mismatch={@mismatch}
          check_event="check_again"
          target={@myself}
        />
      </div>
    </div>
    """
  end

  def render(assigns) do
    auction = assigns.position.auction
    action = action(assigns.position, auction)
    steps = steps(assigns)

    assigns =
      assign(assigns,
        auction: auction,
        action: action,
        standing: standing(assigns.position, auction),
        rate: assigns.usd_rate.result,
        steps: steps,
        next_step: next_step(assigns, steps, action),
        other_wallet: other_wallet(assigns),
        claimed: claimed(assigns.settled, assigns.position)
      )

    ~H"""
    <article
      id={@id}
      class="bid-settlement"
      phx-hook="OnchainSteps"
      data-agent-tools="autolaunch_settle_bid"
      data-agent-bid={@position.bid_id}
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
            <TokenDisplay.written
              value={tokens(@position.tokens_filled)}
              unit={@auction.token_symbol}
            />
          </dd>
        </div>
        <div :if={positive?(@position.tokens_claimed)}>
          <dt>Tokens claimed</dt>
          <dd>
            <TokenDisplay.written
              value={tokens(@position.tokens_claimed)}
              unit={@auction.token_symbol}
            />
          </dd>
        </div>
        <div>
          <dt>Wallet</dt>
          <dd class="bid-settlement__address" title={@position.owner_address}>
            {RegentFormat.short_address(@position.owner_address)}
          </dd>
        </div>
      </dl>

      <p
        :for={reason <- reasons(@position, @market, @auction)}
        class="bid-settlement__note"
        role="status"
      >
        <TokenDisplay.marked text={reason} tickers={tickers(@auction)} />
      </p>
      <p
        class="bid-settlement__note"
        hidden={!(@auction.state == :failed && @position.status == "returnable")}
      >
        The auction for <span class="ticker">{@auction.token_symbol}</span>
        did not meet its minimum raise. Withdraw your whole bid in
        <span class="ticker">{@auction.quote_token_symbol}</span>
        to the wallet above.
      </p>
      <.link
        :if={@stake_path && @claimed}
        navigate={stake_link(@stake_path, @claimed)}
        class="rg-button rg-button--primary"
      >
        {stake_label(@auction)} {@auction.token_symbol}
      </.link>

      <p :if={@action && !@authenticated} class="bid-empty">Sign in to settle this bid.</p>

      <%!-- The panel stays in the page and is only hidden, so its wallet button
           is never replaced while a person presses it. --%>
      <section
        id={"#{@id}-review"}
        class="bid-review"
        aria-label="Settlement"
        hidden={!(@authenticated && (@action || @review))}
      >
        <.summary
          prepared={@prepared}
          rate={@rate}
          position={@position}
          chain={@review && @review.chain}
        />
        <ol class="bid-steps" role="list" aria-label="Settlement progress" hidden={@steps == []}>
          <li :for={step <- @steps} data-step={step.name}>
            <span>
              <TokenDisplay.marked text={step.label} tickers={tickers(@auction)} />
            </span>
            <.step_state state={chip(step, @next_step)} />
          </li>
        </ol>
        <p class="bid-notice" role="status" hidden={!@notice}>{@notice}</p>
        <p
          class="bid-progress__status"
          role="status"
          aria-live="polite"
          hidden={!progress_copy(@steps, @settled, @auction)}
        >
          <TokenDisplay.marked
            text={progress_copy(@steps, @settled, @auction) || ""}
            tickers={tickers(@auction)}
          />
        </p>
        <p role="status" hidden={!@other_wallet}>{@other_wallet}</p>
        <p class="bid-notice" role="status" hidden={!@press_note}>{@press_note}</p>
        <SwapForm.wallet_step
          next_step={@next_step}
          steps={@steps}
          reverted={reverted(@steps, @auction)}
          signer={@review && @review.signer}
          chain_name={@review && @review.chain.name}
          mismatch={@mismatch}
          check_event="check_again"
          target={@myself}
        />
        <Regent.Primitives.button
          type="button"
          phx-click="clear_settlement"
          phx-target={@myself}
          variant="secondary"
          hidden={!finished?(@steps)}
        >
          Done
        </Regent.Primitives.button>
      </section>
    </article>
    """
  end

  attr :prepared, :map, default: nil
  attr :rate, :any, required: true
  attr :position, :map, required: true
  attr :chain, :map, default: nil

  # What the settlement returns, where to and on which network.
  defp summary(assigns) do
    ~H"""
    <dl class="bid-settlement__facts" aria-label="What you get" hidden={!@prepared}>
      <%= if @prepared do %>
        <div :if={@prepared.facts.currency_refunded}>
          <dt>You get back</dt>
          <dd>
            <TokenDisplay.price
              amount={@prepared.facts.currency_refunded}
              unit={@prepared.facts.currency_symbol}
              round={:down}
            />
            <UsdValue.usd amount={@prepared.facts.currency_refunded} rate={@rate} />
          </dd>
        </div>
        <div :if={@prepared.facts.tokens_claimed || @prepared.facts.tokens_filled}>
          <dt>You get</dt>
          <dd>
            <TokenDisplay.written
              value={tokens(@prepared.facts.tokens_claimed || @prepared.facts.tokens_filled)}
              unit={@prepared.facts.token_symbol}
            />
          </dd>
        </div>
        <div>
          <dt>Receiving wallet</dt>
          <dd class="bid-settlement__address" title={@position.owner_address}>
            {RegentFormat.short_address(@position.owner_address)}
          </dd>
        </div>
        <div>
          <dt>Network</dt>
          <dd>{@chain && @chain.name}</dd>
        </div>
      <% end %>
    </dl>
    """
  end

  @impl true
  def handle_event("onchain_active_wallet", params, socket) do
    active = OnchainSteps.active_wallet(params)

    socket =
      if active == socket.assigns.active,
        do: socket,
        else: assign(socket, active: active, press_note: nil)

    {:noreply, socket |> followed() |> offer()}
  end

  # An agent's press: the step the card's button would send now, or, after the
  # auction, the settlement the card offers, prepared and sent at once.
  def handle_event("agent_press", %{"tool" => "autolaunch_settle_bid"}, socket) do
    assigns = socket.assigns

    cond do
      !assigns.authenticated ->
        {:reply, AgentPress.refused(copy(:authentication_required)), socket}

      is_nil(assigns.signer) ->
        {:reply, AgentPress.refused(no_signer(assigns)), socket}

      !owner?(assigns) ->
        {:reply, AgentPress.refused(copy(:not_your_bid)), socket}

      step = assigns.review && reviewed_next(steps(assigns)) ->
        {:reply, AgentPress.sending(assigns.review, step.name, &label(&1, assigns.prepared)),
         socket}

      assigns.early ->
        {:reply, AgentPress.refused(early_refusal(assigns)), socket}

      action(assigns.position, assigns.position.auction) ->
        agent_settle(socket)

      true ->
        {:reply, AgentPress.refused(settled_refusal(assigns)), socket}
    end
  end

  def handle_event("step_sent", params, socket),
    do: {:noreply, OnchainSteps.sent(socket, params)}

  def handle_event("step_failed", params, socket) do
    case Presses.failed(params) do
      {:ok, _name, reason} ->
        AutolaunchWeb.Telemetry.wallet_failed(:bid_settlement, reason)
        {:noreply, assign(socket, press_note: failure_note(socket.assigns, reason))}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("check_again", %{"hash" => hash}, socket) when is_binary(hash),
    do: {:noreply, OnchainSteps.check_again(socket, hash)}

  def handle_event("clear_settlement", _params, socket),
    do:
      {:noreply,
       socket |> assign(settled: nil, notice: nil) |> withdrawn() |> refreshed() |> offer()}

  @impl true
  def handle_async(:prepare, {:ok, {key, result}}, socket) do
    socket = assign(socket, preparing: nil)

    if key == settle_key(socket.assigns),
      do: {:noreply, reviewed(socket, key, result)},
      else: {:noreply, prepare_when_ready(socket)}
  end

  def handle_async(:prepare, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, preparing: nil, notice: @generic)}

  def handle_async(:early, {:ok, {signer, {status, prepared}}}, socket) do
    socket = assign(socket, checking: false, checked_at: System.monotonic_time(:second))

    cond do
      # Another wallet became active while this was asked; the next check
      # starts from the wallet active now.
      signer != socket.assigns.signer ->
        {:noreply, socket |> assign(checked_at: nil) |> early_check()}

      status == :refused ->
        {:noreply, assign(socket, status: :refused, notice: copy(refusal(prepared)))}

      held?(socket.assigns) ->
        {:noreply, assign(socket, status: status)}

      true ->
        {:noreply,
         socket |> assign(status: status, notice: nil) |> offered({status, signer}, prepared)}
    end
  end

  def handle_async(:early, {:exit, _reason}, socket),
    do:
      {:noreply,
       assign(socket,
         status: :refused,
         checking: false,
         checked_at: System.monotonic_time(:second),
         notice: @generic
       )}

  def handle_async({:onchain_step, hash}, result, socket),
    do: {:noreply, OnchainSteps.checked(socket, hash, result, &confirmed/2)}

  def handle_async({:result, hash}, result, socket) do
    logs =
      case result do
        {:ok, {:ok, %{"logs" => logs}}} when is_list(logs) -> logs
        _unread -> nil
      end

    {:noreply, settled(socket, hash, logs)}
  end

  # Reviews

  # After the auction, the settlement is prepared in the background whenever
  # what it would send changes: the wallet or the position's standing. A
  # review with a press on it is kept until the card is done with it.
  defp prepare_when_ready(%{assigns: assigns} = socket) do
    key = settle_key(assigns)

    cond do
      is_nil(key) or assigns.preparing -> socket
      held?(assigns) -> socket
      assigns.prepared_for in [key, {:refused, key}] -> socket
      true -> start_prepare(socket, key)
    end
  end

  defp start_prepare(socket, {signer, position_id, _status} = key) do
    opts = opts(socket)

    socket
    |> assign(preparing: key)
    |> start_async(:prepare, fn ->
      {key, BidSettlementActions.prepare(position_id, signer, opts)}
    end)
  end

  defp settle_key(%{authenticated: true, signer: signer, position: position} = assigns)
       when is_binary(signer) do
    if owner?(assigns) and action(position, position.auction),
      do: {signer, position.id, position.status}
  end

  defp settle_key(_assigns), do: nil

  # An agent waits for this one: it is prepared at once.
  defp agent_settle(%{assigns: assigns} = socket) do
    key = settle_key(assigns)
    {signer, position_id, _status} = key
    result = BidSettlementActions.prepare(position_id, signer, opts(socket))
    socket = reviewed(socket, key, result)

    case {result, socket.assigns.review} do
      {{:ok, prepared}, %{steps: [%{step: first} | _rest]} = review} ->
        {:reply, AgentPress.sending(review, first, &label(&1, prepared)), socket}

      _refused ->
        {:reply, AgentPress.refused(socket.assigns.notice || @generic), socket}
    end
  end

  defp reviewed(socket, key, {:ok, prepared}) do
    review = Review.new(socket.assigns.id, elem(key, 0), prepared.chain, prepared.steps)

    socket
    |> assign(prepared_for: key, notice: nil, press_note: nil)
    |> put_review(review, prepared)
    |> refresh_later()
  end

  defp reviewed(socket, key, {:error, error}),
    do: assign(socket, prepared_for: {:refused, key}, notice: copy(refusal(error)))

  # The review on the page, and what each review still followed was prepared
  # with, so an outcome is read against the settlement it belongs to.
  defp put_review(socket, review, prepared) do
    socket = socket |> assign(prepared: prepared) |> OnchainSteps.put_review(review)
    followed = MapSet.new(Presses.shown(socket.assigns.presses), & &1.review.id)

    reviews =
      socket.assigns.reviews
      |> Map.filter(fn {id, _prepared} -> MapSet.member?(followed, id) end)
      |> then(&if review, do: Map.put(&1, review.id, prepared), else: &1)

    assign(socket, reviews: reviews)
  end

  defp refresh_later(%{assigns: %{review: %{id: review_id}}} = socket) do
    send_update_after(
      self(),
      __MODULE__,
      [id: socket.assigns.id, refresh_review: review_id],
      @refresh_ms
    )

    socket
  end

  defp refresh_later(socket), do: socket

  # A review the card keeps: one with a press on it and, while bidding is
  # open, a return offered now. An unpressed review that only records the
  # price is asked about again, so a price someone else records in the
  # meantime turns it into the return itself.
  defp held?(%{review: nil}), do: false

  defp held?(%{early: true, review: review, presses: presses}),
    do: started?(presses, review) or not recording?(review)

  defp held?(%{review: review, presses: presses}), do: started?(presses, review)

  defp started?(presses, review),
    do: Enum.any?(review.steps, &OnchainSteps.entry(presses, review, &1.step))

  defp recording?(%{steps: [%{step: "record"}]}), do: true
  defp recording?(_review), do: false

  # The auction is asked while nothing of this card is with the wallet: first
  # on arrival, then again, at most every half minute, while the money cannot
  # come back yet.
  defp early_check(%{assigns: assigns} = socket) do
    cond do
      !assigns.authenticated -> socket
      assigns.checking or held?(assigns) -> socket
      !early_due?(assigns) -> socket
      true -> start_early(socket)
    end
  end

  defp early_due?(%{checked_at: nil}), do: true

  defp early_due?(%{checked_at: checked_at}),
    do: System.monotonic_time(:second) - checked_at >= @early_recheck_seconds

  defp start_early(%{assigns: assigns} = socket) do
    %{position: position, signer: signer} = assigns
    owner = if owner?(assigns), do: signer
    offered = if assigns.review, do: :record
    opts = opts(socket)

    socket
    |> assign(checking: true)
    |> start_async(:early, fn -> {signer, early_offer(position, owner, offered, opts)} end)
  end

  # Read-only until the money can come back, now or after recording the
  # price, and the bid's own wallet is active: only then is a review
  # prepared, and a review already offered for the same answer is kept.
  defp early_offer(position, owner, offered, opts) do
    case BidSettlementActions.return_status(position) do
      {:ok, status} when status in [:now, :record] and is_binary(owner) and status != offered ->
        {status, BidSettlementActions.prepare(position.id, owner, opts)}

      {:ok, status} ->
        {status, nil}

      {:error, error} ->
        {:refused, error}
    end
  end

  defp offered(socket, _key, nil), do: socket

  defp offered(socket, {status, signer}, result),
    do: reviewed(socket, {signer, socket.assigns.position.id, status}, result)

  # Outcomes

  # A recorded price makes the return possible: the auction is asked again at
  # once, and the return prepared against the recorded price. A return or a
  # claim is read from its receipt.
  defp confirmed(socket, %{name: "record"}),
    do: socket |> assign(recorded: true, checked_at: nil) |> withdrawn() |> early_check()

  defp confirmed(socket, %{hash: hash, review: review}),
    do: start_async(socket, {:result, hash}, fn -> Client.receipt(review.chain, hash) end)

  # What the step did is recorded on the position, whichever of this page's
  # reviews it was sent from, and the page that owns the card reads it again.
  defp settled(socket, hash, logs) do
    with %{name: name, review: %{id: id}} <-
           Enum.find(Presses.shown(socket.assigns.presses), &(&1.hash == hash)),
         %{context: context} <- Map.get(socket.assigns.reviews, id) do
      result = logs && BidSettlementActions.result(context, name, logs)
      if result, do: LabProjection.project_settlement(context, name, result)

      socket
      |> assign(settled: result && Map.put(result, "step", name))
      |> refreshed()
    else
      _other -> socket
    end
  end

  defp refreshed(socket) do
    send(self(), {:bid_settlement_changed, socket.assigns.position.id})
    socket
  end

  # Steps

  defp steps(%{review: %{} = review, prepared: prepared, presses: presses}) do
    Enum.map(review.steps, fn %{step: name} ->
      entry = OnchainSteps.entry(presses, review, name)
      %{name: name, label: label(name, prepared), state: press_state(entry), entry: entry}
    end)
  end

  defp steps(_assigns), do: []

  defp reviewed_next(steps), do: Enum.find(steps, &(&1.state in [:ready, :reverted, :other]))

  # One button at a time: the first step the wallet has not sent from this
  # review yet, or one that did not go through. Before the review is on the
  # page the button names what the position offers. A sent step moves the
  # button on at once; nothing waits for the network before the next press
  # can reach the wallet.
  defp next_step(%{review: %{}}, steps, _action), do: reviewed_next(steps)
  defp next_step(_assigns, _steps, nil), do: nil
  defp next_step(_assigns, _steps, action), do: %{name: "settle", label: action}

  defp early_next(%{review: %{}}, steps), do: steps |> reviewed_next() |> early_label()
  defp early_next(_assigns, _steps), do: nil

  defp early_label(nil), do: nil
  defp early_label(step), do: %{step | label: "Get my unspent money back"}

  defp press_state(nil), do: :ready

  defp press_state(%{outcome: :pending} = entry),
    do: if(Presses.stalled?(entry), do: :stalled, else: :sent)

  defp press_state(%{outcome: :confirmed}), do: :done
  defp press_state(%{outcome: :reverted}), do: :reverted
  defp press_state(_not_this_step), do: :other

  defp finished?([]), do: false
  defp finished?(steps), do: Enum.all?(steps, &(&1.state == :done))

  defp chip(%{state: :ready, name: name}, %{name: name}), do: "Ready"
  defp chip(%{state: :ready}, _next), do: "Waiting"
  defp chip(%{state: state}, _next) when state in [:sent, :stalled], do: "Sent"
  defp chip(%{state: :done}, _next), do: "Confirmed"
  defp chip(%{state: :reverted}, _next), do: "Reverted"
  defp chip(%{state: :other}, _next), do: "Unresolved"

  defp record_state(steps, recorded) do
    case Enum.find(steps, &(&1.name == "record")) do
      nil -> if recorded, do: "Confirmed", else: "Waiting"
      step -> chip(step, reviewed_next(steps))
    end
  end

  defp return_state(steps) do
    case Enum.find(steps, &(&1.name == "exit")) do
      nil -> "Next"
      step -> chip(step, reviewed_next(steps))
    end
  end

  defp label("record", _prepared), do: "Record the new price"

  defp label("exit", %{facts: facts}),
    do: "Withdraw #{if facts.graduated, do: "unspent ", else: ""}#{facts.currency_symbol}"

  defp label("claim", %{facts: facts}), do: "Claim #{facts.token_symbol} to wallet"

  defp returning(%{facts: %{currency_refunded: refunded}} = prepared) when is_binary(refunded),
    do: prepared

  defp returning(_prepared), do: nil

  # What is happening to the settlement on the page, in a line.
  defp progress_copy(steps, settled, auction) do
    case Enum.filter(steps, &(&1.state in [:sent, :stalled, :other])) |> List.last() do
      %{state: :other} ->
        "That transaction is not the one this page prepared, so it can't be followed here. Check it in your wallet activity."

      %{state: :stalled} ->
        "Base has not confirmed this yet. Check again, or look in your wallet activity."

      %{name: "claim"} ->
        "Claiming your #{auction.token_symbol}…"

      %{name: _exit} ->
        "Sending your #{auction.quote_token_symbol} back…"

      nil ->
        settled_copy(settled, auction)
    end
  end

  defp early_progress(steps, settled) do
    case Enum.filter(steps, &(&1.state in [:sent, :stalled, :other])) |> List.last() do
      %{state: :other} ->
        "That transaction is not the one this page prepared, so it can't be followed here. Check it in your wallet activity."

      %{state: :stalled} ->
        "Base has not confirmed this yet. Check again, or look in your wallet activity."

      %{name: "record"} ->
        "Recording the new price…"

      %{name: _exit} ->
        "Sending your money back…"

      nil ->
        settled && "Your unspent money is back in your wallet."
    end
  end

  defp settled_copy(%{"tokens_claimed_units" => tokens}, auction),
    do: "#{tokens(tokens)} #{auction.token_symbol} tokens were delivered to your wallet."

  defp settled_copy(%{"currency_refunded_units" => refunded}, auction),
    do:
      "#{TokenDisplay.short(refunded, :down)} #{auction.quote_token_symbol} was returned to your wallet."

  defp settled_copy(_none, _auction), do: nil

  defp reverted(steps, auction) do
    case Enum.find(steps, &(&1.state == :reverted)) do
      %{name: "record"} ->
        "Recording the price did not go through. Only the network fee was spent. Press again."

      %{name: "claim"} ->
        "That claim did not go through, so no #{auction.token_symbol} moved. Only the network fee was spent. Press again."

      %{} ->
        "That did not go through, so nothing came back. Only the network fee was spent. Press again."

      nil ->
        nil
    end
  end

  # The bid's own wallet settles it; while another wallet on the account is
  # active, the card says which one to switch to.
  defp other_wallet(%{signer: signer, position: position} = assigns) when is_binary(signer) do
    if !owner?(assigns),
      do:
        "This bid was placed from #{RegentFormat.short_address(position.owner_address)}. Switch to that wallet in your wallet app to settle it."
  end

  defp other_wallet(_assigns), do: nil

  defp owner?(%{signer: signer, position: %{owner_address: owner}}) when is_binary(signer),
    do: Address.equal?(signer, owner)

  defp owner?(_assigns), do: false

  defp failure_note(%{review: review} = assigns, reason) do
    chain_name = if review, do: review.chain.name, else: "Base"
    OnchainSteps.failure_note(reason, assigns.linked, assigns.active, chain_name)
  end

  defp no_signer(%{linked: nil}), do: copy(:authentication_required)
  defp no_signer(%{active: nil}), do: "Connect your wallet, then press again."
  defp no_signer(_assigns), do: copy(:wrong_signer)

  # The line under the bid, from the auction's answer; the minimum still to
  # raise is the auction's own minimum less what it has raised.
  defp line({:minimum, raised}, auction) do
    missing = String.to_integer(auction.required_currency_raised) - raised
    {:minimum, Rpc.format_units(max(missing, 0), auction.quote_token_decimals)}
  end

  defp line(status, _auction) when status in [:now, :record, :buying], do: status
  defp line(_status, _auction), do: nil

  # Why an early card has nothing to send, in the words of its line.
  defp early_refusal(%{settled: %{}}), do: "This bid's unspent money has already come back."
  defp early_refusal(%{notice: message}) when is_binary(message), do: message

  defp early_refusal(%{status: :buying}),
    do: "This bid is still buying at the current price, so none of its money is unspent yet."

  defp early_refusal(%{status: {:minimum, _raised}}),
    do: "The unspent money can come back once the auction raises its minimum."

  defp early_refusal(_assigns),
    do: "The page is still asking the auction about this bid. Call again in a moment."

  # Why a card after the auction has nothing to offer.
  defp settled_refusal(%{position: position, market: market}) do
    case reasons(position, market, position.auction) do
      [reason | _rest] -> reason
      [] -> "Nothing is left to settle on this bid."
    end
  end

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

  # The tokens just claimed here, or those the position records as claimed.
  defp claimed(%{"tokens_claimed_units" => tokens}, _position), do: tokens

  defp claimed(_settled, %{tokens_claimed: tokens}) do
    if positive?(tokens), do: tokens
  end

  # The staking panel, with the claimed amount entered.
  defp stake_link(path, amount),
    do:
      String.replace_suffix(path, "#stake", "?" <> URI.encode_query(%{stake: amount}) <> "#stake")

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

  # The tickers a settlement's sentences name.
  defp tickers(auction), do: [auction.token_symbol, auction.quote_token_symbol]

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  defp copy(:chain_unavailable) do
    if Lab.test_chain?(),
      do: "The Base fork could not be read just now. Check that it is still running.",
      else: Map.fetch!(@copy, :chain_unavailable)
  end

  defp copy(reason), do: Map.get(@copy, reason, @generic)

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil

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
end
