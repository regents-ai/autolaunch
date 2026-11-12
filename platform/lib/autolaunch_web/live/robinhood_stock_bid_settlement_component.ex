defmodule AutolaunchWeb.RobinhoodStockBidSettlementComponent do
  @moduledoc """
  One bid on a Robinhood memestock auction and what can come back from it: the
  unspent stock the bid did not use, and the launch tokens it won.

  Once bidding has ended (`ended`), the auction's own answer decides what is
  on screen: a button that sends the return and then the claim, or the
  auction's reason nothing can be done yet. The settlement is prepared as soon
  as the card knows the wallet that may act, so the button sends at once.

  With `early`, the bid is an outbid one, or one sharing at the price, while
  bidding is still open. The auction is asked in the background when the
  unspent stock can come back, and again at most every half minute while it
  cannot yet; the answer is the row's one line (`AuctionBook.return_line/1`,
  with the minimum and end time from `launch`). Once it can, the return is
  prepared and the button shown. When the price has passed the bid but the
  auction has not recorded it yet, the same button first records the price
  (its own review, one wallet confirmation); once that is confirmed, the
  auction is asked again at once and the return is prepared against the
  recorded price.

  The wallet that acts is Privy's active wallet when the signed-in account
  links it (`AutolaunchWeb.OnchainSteps`). It settles any bid one of the
  account's wallets placed: the auction takes a return or a claim from any
  sender and pays the wallet that placed the bid, which a note names while
  another wallet is open. Nothing is stored: the review lives on this page
  only, the browser reports a hash and stops, and every outcome on screen is
  the server's own read of that hash against the review it was sent from. A
  confirmed return or claim asks the bid panel to read the wallet's bids
  again; one that did not go through is prepared again from the auction.
  """

  use AutolaunchWeb, :live_component

  import AutolaunchWeb.Components.StepState

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.Robinhood.{Lab, StockBidSettlementActions}
  alias AutolaunchWeb.Components.{AuctionBook, SwapForm}
  alias AutolaunchWeb.Live.Session

  alias AutolaunchWeb.{
    BidSettlementComponent,
    OnchainSteps,
    RobinhoodStockBidComponent,
    TokenDisplay
  }

  alias AutolaunchWeb.UsdValue
  alias RegentChain.{Address, Presses, Review}

  @copy %{
    authentication_required: "Sign in to settle this bid.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer: "Your wallet changed during the press, so nothing was sent. Press again.",
    invalid_address: "Open one of your account's wallets in your wallet app, then press again.",
    not_your_bid: "This bid is not held by a wallet on your account.",
    bid_not_found: "The auction has no record of this bid.",
    chain_unavailable: "Robinhood could not be read just now. Try again in a moment.",
    invalid_chain_response: "Robinhood gave an incomplete answer. Try again in a moment.",
    robinhood_unavailable: "Robinhood auctions are not open on this site.",
    invalid_auction: "This is not an auction address.",
    auction_not_found: "This auction was not made by a Memestock launchpad.",
    stock_not_listed: "This auction's stock is not one this site lists.",
    auction_not_started: "Bidding has not started on this auction.",
    auction_not_ended: "This bid stays in the auction until bidding ends.",
    already_exited: "This bid has already been returned.",
    claim_not_open: "Tokens cannot be claimed yet.",
    nothing_to_claim: "This bid has no tokens to claim.",
    bid_not_exited: "Return this bid before claiming its tokens.",
    failed_bid_returned:
      "Your bid was returned in full. This launch did not raise enough, and there are no tokens to claim.",
    bid_needs_partial_exit_hints_unavailable:
      "This bid was only partly filled and the auction's records for it could not be traced. Try again in a moment.",
    price_history_long:
      "This auction's price history is long, and only part of it could be read just now. Press again to read on.",
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
     |> Session.check_component_lease(&take_account/2)
     |> OnchainSteps.init()
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
       recorded: false,
       carried_note: nil
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
     |> assign_new(:ended, fn -> false end)
     |> assign_new(:stake_path, fn -> nil end)
     |> OnchainSteps.adopt()
     |> followed()
     |> offer()}
  end

  # The account as it reads now, before each event and background result
  # (`Session.check_component_lease/2`): a change to its wallets moves the
  # row onto them.
  defp take_account(socket, account),
    do: OnchainSteps.take_account(socket, account, &(&1 |> followed() |> offer()))

  # The row follows the wallet that may act. A review is built for one
  # signer, so another one withdraws it, and an early row asks again.
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
    steps = steps(assigns)

    assigns =
      assign(assigns,
        line: line(assigns.status, assigns.launch),
        steps: steps,
        next_step: early_next(assigns, steps),
        returning: returning(assigns.prepared),
        progress: early_progress(steps, assigns.settled),
        paid_to: payee(assigns)
      )

    ~H"""
    <div
      id={@id}
      class="bid-early-return"
      phx-hook="OnchainSteps"
    >
      <div hidden={!@line}>
        <AuctionBook.return_line
          :if={@line}
          id={"#{@id}-when"}
          status={@line}
          unit={@launch.quote_token_symbol}
          usd_rate={@usd_rate}
          ends_at={@launch.estimated_end_at}
        />
      </div>
      <p class="bid-notice" role="status" hidden={!@notice}>{@notice}</p>

      <div class="bid-early-return__offer">
        <p hidden={!@returning}>
          <%= if @returning do %>
            <TokenDisplay.price
              amount={@prepared.facts.stock_refunded}
              unit={@prepared.facts.stock_symbol}
            />
            <UsdValue.usd amount={@prepared.facts.stock_refunded} rate={@usd_rate} />
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
        <p role="status" aria-live="polite" hidden={!@progress}>
          {@progress}
        </p>
        <BidSettlementComponent.paid_to id={@id <> "-paid-to"} owner={@paid_to} chain="robinhood" />
        <p class="bid-notice" role="status" hidden={!@press_note}>{@press_note}</p>
        <SwapForm.wallet_step
          id={@id <> "-sender"}
          next_step={@next_step}
          steps={@steps}
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
    steps = steps(assigns)
    key = settle_key(assigns)

    assigns =
      assign(assigns,
        steps: steps,
        next_step: next_step(assigns, steps, key),
        open: !!(key || assigns.review),
        paid_to: payee(assigns),
        progress: progress_copy(steps, assigns.settled, assigns.prepared, assigns.token_symbol),
        tickers: tickers(assigns.prepared, assigns.token_symbol),
        claimed: claimed(assigns.settled),
        returned: returned?(assigns.bid, assigns.graduated?)
      )

    ~H"""
    <div
      id={@id}
      class="bid-settlement-row"
      phx-hook="OnchainSteps"
      data-onchain-prepare
    >
      <p class="launch-wallet-settled" role="status" hidden={!@returned}>
        {copy(:failed_bid_returned)}
      </p>
      <.link
        :if={@stake_path && (@claimed || claimed_bid?(@bid, @graduated?))}
        navigate={@stake_path}
        class="rg-button rg-button--secondary"
      >
        Memestock {@token_symbol}
      </.link>

      <%!-- The panel stays in the page and is only hidden, so its wallet button
           is never replaced while a person presses it. --%>
      <section
        id={"#{@id}-review"}
        class="bid-review"
        aria-label={"Settle bid ##{@bid["bid_id"]}"}
        hidden={!@open}
      >
        <.summary
          id={@id <> "-summary"}
          prepared={@prepared}
          token_symbol={@token_symbol}
          rate={@usd_rate}
          owner={@bid["owner"]}
          chain={@review && @review.chain}
        />
        <ol class="bid-steps" role="list" aria-label="Settlement progress" hidden={@steps == []}>
          <li :for={step <- @steps} data-step={step.name}>
            <span>
              <TokenDisplay.marked text={step.label} tickers={@tickers} />
            </span>
            <.step_state state={chip(step, @next_step)} />
          </li>
        </ol>
        <p class="bid-notice" role="status" hidden={!@notice}>{@notice}</p>
        <p
          class="bid-progress__status"
          role="status"
          aria-live="polite"
          hidden={!@progress}
        >
          <TokenDisplay.marked text={@progress || ""} tickers={@tickers} />
        </p>
        <BidSettlementComponent.paid_to id={@id <> "-paid-to"} owner={@paid_to} chain="robinhood" />
        <p class="bid-notice" role="status" hidden={!@press_note}>{@press_note}</p>
        <SwapForm.wallet_step
          id={@id <> "-sender"}
          next_step={@next_step}
          steps={@steps}
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
    </div>
    """
  end

  attr :id, :string, required: true
  attr :prepared, :map, default: nil
  attr :token_symbol, :string, required: true
  attr :rate, :any, required: true
  attr :owner, :string, required: true
  attr :chain, :map, default: nil

  # What the settlement returns, where to and on which network.
  defp summary(assigns) do
    ~H"""
    <p class="bid-settlement__note" hidden={!(@prepared && !@prepared.facts.graduated)}>
      <%= if @prepared && !@prepared.facts.graduated do %>
        The auction for <span class="ticker">{@token_symbol}</span>
        did not meet its minimum raise, so your whole bid comes back in <span class="ticker">{@prepared.facts.stock_symbol}</span>.
      <% end %>
    </p>
    <dl class="bid-settlement__facts" aria-label="What you get" hidden={!@prepared}>
      <%= if @prepared do %>
        <div :if={@prepared.facts.stock_refunded}>
          <dt>You get back</dt>
          <dd>
            <TokenDisplay.price
              amount={@prepared.facts.stock_refunded}
              unit={@prepared.facts.stock_symbol}
            />
            <UsdValue.usd amount={@prepared.facts.stock_refunded} rate={@rate} />
          </dd>
        </div>
        <div :if={positive?(@prepared.facts.tokens_claimed || @prepared.facts.tokens_filled)}>
          <dt>You get</dt>
          <dd>
            <TokenDisplay.tokens
              amount={@prepared.facts.tokens_claimed || @prepared.facts.tokens_filled}
              unit={@token_symbol}
            />
          </dd>
        </div>
        <div>
          <dt>Final price</dt>
          <dd>
            <TokenDisplay.price
              amount={@prepared.facts.final_price}
              unit={@prepared.facts.stock_symbol}
            />
            <UsdValue.usd amount={@prepared.facts.final_price} rate={@rate} per="per token" />
          </dd>
        </div>
        <div>
          <dt>Receiving wallet</dt>
          <dd>
            <Regent.Primitives.address id={"#{@id}-owner"} address={@owner} variant="compact" />
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
  def handle_event("onchain_active_wallet", params, socket),
    do: {:noreply, socket |> OnchainSteps.take_active(params) |> followed() |> offer()}

  # A press made before the row has read its review: the settlement is
  # prepared now for the wallet that pressed, and its first step handed back to
  # send, as the Base card does.
  def handle_event("prepare_and_send", %{"form" => _no_inputs}, socket) do
    case prepared_now(socket) do
      {:ok, %{assigns: %{review: %{steps: [%{step: first} | _rest]} = review}} = socket} ->
        {:reply, %{review: review, send: first}, socket}

      {:error, socket} ->
        {:reply, %{}, socket}
    end
  end

  def handle_event("step_sent", params, socket),
    do: {:noreply, OnchainSteps.sent(socket, params)}

  def handle_event("step_failed", params, socket),
    do:
      {:noreply,
       OnchainSteps.failed(
         socket,
         params,
         :robinhood_bid_settlement,
         Lab.network_name(Lab.chain_id())
       )}

  def handle_event("check_again", %{"hash" => hash}, socket) when is_binary(hash),
    do: {:noreply, OnchainSteps.check_again(socket, hash)}

  def handle_event("clear_settlement", _params, socket),
    do: {:noreply, socket |> assign(settled: nil, notice: nil) |> withdrawn() |> offer()}

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
        {:noreply,
         assign(socket,
           status: :refused,
           notice: copy(OnchainSteps.refusal(prepared)),
           carried_note: nil
         )}

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
    do: {:noreply, OnchainSteps.checked(socket, hash, result, &confirmed/2, &step_reverted/2)}

  def handle_async({:result, hash}, result, socket),
    do: {:noreply, settled(socket, hash, OnchainSteps.receipt_logs(result))}

  # Reviews

  # After the auction, the settlement is prepared in the background whenever
  # what it would send changes: the wallet or the bid's own record. A review
  # with a press on it is kept until the row is done with it.
  defp prepare_when_ready(%{assigns: assigns} = socket) do
    key = settle_key(assigns)

    cond do
      is_nil(key) or assigns.preparing -> socket
      held?(assigns) -> socket
      assigns.prepared_for in [key, {:refused, key}] -> socket
      true -> start_prepare(socket, key)
    end
  end

  defp prepared_now(%{assigns: %{review: %{}}} = socket), do: {:ok, socket}

  defp prepared_now(socket) do
    case settle_key(socket.assigns) do
      nil ->
        {:error, socket}

      {signer, _bid_id, _exited, _filled} = key ->
        request = request(socket.assigns)
        result = StockBidSettlementActions.prepare(request, signer, OnchainSteps.opts(socket))
        socket = reviewed(socket, key, result)
        if match?({:ok, _prepared}, result), do: {:ok, socket}, else: {:error, socket}
    end
  end

  defp start_prepare(socket, {signer, _bid_id, _exited, _filled} = key) do
    request = request(socket.assigns)
    opts = OnchainSteps.opts(socket)

    socket
    |> assign(preparing: key)
    |> start_async(:prepare, fn ->
      {key, StockBidSettlementActions.prepare(request, signer, opts)}
    end)
  end

  # Once bidding has ended, a bid that still has something to return or
  # claim, settled from the wallet that may act.
  defp settle_key(%{early: false, ended: true, signer: signer, bid: bid})
       when is_binary(signer) do
    if !settled_bid?(bid),
      do: {signer, bid["bid_id"], bid["exited_block"], bid["tokens_filled_now"]}
  end

  defp settle_key(_assigns), do: nil

  defp request(%{auction: auction, bid: %{"bid_id" => bid_id}}),
    do: %{auction: auction, bid_id: bid_id}

  # A review prepared again after a step did not go through carries the words
  # about that step beside its button.
  defp reviewed(socket, key, {:ok, prepared}) do
    review = Review.new(socket.assigns.id, elem(key, 0), prepared.chain, prepared.steps)

    socket
    |> assign(prepared_for: key, notice: nil, press_note: socket.assigns.carried_note)
    |> assign(carried_note: nil)
    |> put_review(review, prepared)
    |> refresh_later()
  end

  defp reviewed(socket, key, {:error, error}),
    do:
      assign(socket,
        prepared_for: {:refused, key},
        notice: copy(OnchainSteps.refusal(error)),
        carried_note: nil
      )

  # The review on the page, and what each review still followed was prepared
  # with, so an outcome is read against the settlement it belongs to.
  defp put_review(socket, review, prepared) do
    socket = socket |> assign(prepared: prepared) |> OnchainSteps.put_review(review)
    # A sent step this server holds no review for follows none.
    followed =
      for %{review: %{id: id}} <- Presses.shown(socket.assigns.presses),
          into: MapSet.new(),
          do: id

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

  # A review the row keeps: one with a press on it and, while bidding is
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

  # The auction is asked while nothing of this row is with the wallet: first
  # on arrival, then again, at most every half minute, while the stock cannot
  # come back yet.
  defp early_check(%{assigns: assigns} = socket) do
    cond do
      assigns.linked in [nil, :unread] -> socket
      assigns.checking or held?(assigns) -> socket
      !early_due?(assigns) -> socket
      true -> start_early(socket)
    end
  end

  defp early_due?(%{checked_at: nil}), do: true

  defp early_due?(%{checked_at: checked_at}),
    do: System.monotonic_time(:second) - checked_at >= @early_recheck_seconds

  defp start_early(%{assigns: assigns} = socket) do
    %{bid: %{"owner" => owner}, signer: signer} = assigns
    request = request(assigns)
    offered = if assigns.review, do: :record
    opts = OnchainSteps.opts(socket)

    socket
    |> assign(checking: true)
    |> start_async(:early, fn ->
      {signer, early_offer(Map.put(request, :owner, owner), signer, offered, opts)}
    end)
  end

  # Read-only until the stock can come back, now or after recording the
  # price, and a wallet that may act is open: only then is a review
  # prepared, and a review already offered for the same answer is kept.
  defp early_offer(request, signer, offered, opts) do
    case StockBidSettlementActions.return_status(request) do
      {:ok, status} when status in [:now, :record] and is_binary(signer) and status != offered ->
        {status, StockBidSettlementActions.prepare(request, signer, opts)}

      {:ok, status} ->
        {status, nil}

      {:error, error} ->
        {:refused, error}
    end
  end

  defp offered(socket, _key, nil), do: assign(socket, carried_note: nil)

  defp offered(socket, {status, signer}, result),
    do: reviewed(socket, {signer, socket.assigns.bid["bid_id"], status, nil}, result)

  # Outcomes

  # A recorded price makes the return possible: the auction is asked again at
  # once, and the return prepared against the recorded price. A return or a
  # claim is read from its receipt.
  defp confirmed(socket, %{name: "record"}),
    do: socket |> assign(recorded: true, checked_at: nil) |> withdrawn() |> early_check()

  defp confirmed(socket, entry), do: OnchainSteps.read_receipt(socket, entry)

  # A step of the open review that did not go through: the settlement is read
  # again from the auction and prepared afresh (`OnchainSteps.rebuild_reverted/4`),
  # and the new review, or the auction's reason nothing can be done now,
  # replaces the one that failed.
  defp step_reverted(socket, %{name: name} = entry) do
    note = reverted_copy(name, socket.assigns.token_symbol)

    OnchainSteps.rebuild_reverted(socket, entry, note, fn socket ->
      socket
      |> assign(carried_note: OnchainSteps.rebuilt_words(note), checked_at: nil)
      |> withdrawn()
      |> offer()
    end)
  end

  # What the step did, from its receipt, whichever of this page's reviews it
  # was sent from; the bid panel reads the wallet's bids again.
  defp settled(socket, hash, logs) do
    with %{name: name, review: %{id: id}} <-
           Enum.find(Presses.shown(socket.assigns.presses), &(&1.hash == hash)),
         %{context: context} <- Map.get(socket.assigns.reviews, id) do
      result = logs && StockBidSettlementActions.result(context, name, logs)

      send_update(RobinhoodStockBidComponent,
        id: socket.assigns.parent_id,
        refresh_bids: true
      )

      assign(socket, settled: result && Map.put(result, "step", name))
    else
      _other -> socket
    end
  end

  # Steps

  defp steps(%{review: %{} = review, prepared: prepared, presses: presses}) do
    Enum.map(review.steps, fn %{step: name} ->
      OnchainSteps.step(presses, review, name, label(name, prepared))
    end)
  end

  defp steps(_assigns), do: []

  defp reviewed_next(steps), do: Enum.find(steps, &(&1.state in [:ready, :reverted, :other]))

  # One button at a time: the first step the wallet has not sent from this
  # review yet, or one that did not go through. With no review on the row the
  # button names what the bid offers, and a press prepares the settlement
  # then (`prepare_and_send`). A sent step moves the button on at once;
  # nothing waits for the network before the next press can reach the wallet.
  defp next_step(%{review: %{}}, steps, _key), do: reviewed_next(steps)
  defp next_step(_assigns, _steps, nil), do: nil
  defp next_step(assigns, _steps, _key), do: %{name: "settle", label: offer_label(assigns)}

  defp offer_label(%{
         graduated?: false,
         prepared: %{facts: %{stock_refunded: refunded, stock_symbol: symbol}}
       })
       when is_binary(refunded),
       do: BidSettlementComponent.refund_label(refunded, symbol)

  defp offer_label(%{graduated?: false}), do: "Refund your stock"

  defp offer_label(%{bid: %{"exited_block" => "0"}} = assigns),
    do: "Withdraw unspent #{stock_symbol(assigns)}"

  defp offer_label(%{token_symbol: symbol}), do: "Claim #{symbol} to wallet"

  defp stock_symbol(%{prepared: %{facts: %{stock_symbol: symbol}}}), do: symbol
  defp stock_symbol(_assigns), do: "your stock"

  defp early_next(%{review: %{}}, steps) do
    with %{} = step <- reviewed_next(steps), do: %{step | label: "Get my unspent money back"}
  end

  defp early_next(_assigns, _steps), do: nil

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

  defp label("exit", %{facts: %{graduated: false} = facts}),
    do: BidSettlementComponent.refund_label(facts.stock_refunded, facts.stock_symbol)

  defp label("exit", %{facts: facts}), do: "Withdraw unspent #{facts.stock_symbol}"

  defp label("claim", _prepared), do: "Claim tokens to wallet"

  defp returning(%{facts: %{stock_refunded: refunded}} = prepared) when is_binary(refunded),
    do: prepared

  defp returning(_prepared), do: nil

  # What is happening to the settlement on the page, in a line.
  defp progress_copy(steps, settled, prepared, token_symbol) do
    case Enum.filter(steps, &(&1.state in [:sent, :stalled, :other])) |> List.last() do
      %{state: :other} ->
        "That transaction is not the one this page prepared, so it can't be followed here. Check it in your wallet activity."

      %{state: :stalled} ->
        "Robinhood Chain has not confirmed this yet. Check again, or look in your wallet activity."

      %{name: "claim"} ->
        "Claiming your #{token_symbol}…"

      %{name: _exit} ->
        "Sending your #{stock_symbol(%{prepared: prepared})} back…"

      nil ->
        settled_copy(settled, prepared, token_symbol)
    end
  end

  defp early_progress(steps, settled) do
    case Enum.filter(steps, &(&1.state in [:sent, :stalled, :other])) |> List.last() do
      %{state: :other} ->
        "That transaction is not the one this page prepared, so it can't be followed here. Check it in your wallet activity."

      %{state: :stalled} ->
        "Robinhood Chain has not confirmed this yet. Check again, or look in your wallet activity."

      %{name: "record"} ->
        "Recording the new price…"

      %{name: _exit} ->
        "Sending your stock back…"

      nil ->
        settled && "Your unspent stock is back in your wallet."
    end
  end

  defp settled_copy(%{"tokens_claimed_units" => tokens}, _prepared, token_symbol),
    do: "#{TokenDisplay.short(tokens)} #{token_symbol} tokens were delivered to your wallet."

  defp settled_copy(%{"stock_refunded_units" => refunded}, prepared, _token_symbol),
    do:
      "#{TokenDisplay.short(refunded)} #{stock_symbol(%{prepared: prepared})} was returned to your wallet."

  defp settled_copy(_none, _prepared, _token_symbol), do: nil

  defp reverted_copy("record", _token_symbol),
    do: "Recording the price did not go through. Only the network fee was spent."

  defp reverted_copy("claim", token_symbol),
    do:
      "That claim did not go through, so no #{token_symbol} moved. Only the network fee was spent."

  defp reverted_copy(_exit, _token_symbol),
    do: "That did not go through, so nothing came back. Only the network fee was spent."

  # Any wallet on the account settles the bid, and the auction pays the wallet
  # that placed it; while another one is open, the row names that wallet.
  defp payee(%{signer: signer, bid: %{"owner" => owner}}) when is_binary(signer),
    do: if(Address.equal?(signer, owner), do: nil, else: owner)

  defp payee(_assigns), do: nil

  # The one line under the bid, from the auction's answer; the minimum still
  # to raise is the auction's own minimum less what it has raised.
  defp line({:minimum, raised}, launch) do
    missing = String.to_integer(launch.required_currency_raised) - raised
    {:minimum, Rpc.format_units(max(missing, 0), launch.quote_token_decimals)}
  end

  defp line(status, _launch) when status in [:now, :record, :buying], do: status
  defp line(_status, _launch), do: nil

  # A bid with nothing left: returned in full, or returned and its tokens
  # claimed (claiming zeroes the fill the auction records).
  defp settled_bid?(%{"exited_block" => exited, "tokens_filled_now" => "0"}), do: exited != "0"
  defp settled_bid?(_bid), do: false

  # An exited bid with nothing filled on an auction that did not graduate has
  # had its whole stake returned; on a graduated one the same record means the
  # tokens were claimed.
  defp returned?(bid, false), do: settled_bid?(bid)
  defp returned?(_bid, _graduated?), do: false

  defp claimed_bid?(bid, true), do: settled_bid?(bid)
  defp claimed_bid?(_bid, _graduated?), do: false

  defp claimed(%{"tokens_claimed_units" => tokens}), do: tokens
  defp claimed(_settled), do: nil

  defp positive?(value) when is_binary(value) and value != "",
    do: Decimal.gt?(Decimal.new(value), 0)

  defp positive?(_value), do: false

  # The tickers a settlement's sentences name.
  defp tickers(%{facts: %{stock_symbol: symbol}}, token_symbol), do: [symbol, token_symbol]
  defp tickers(_prepared, token_symbol), do: [token_symbol]

  defp copy(reason), do: Map.get(@copy, reason, @generic)
end
