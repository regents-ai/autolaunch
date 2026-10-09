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
  links it (`AutolaunchWeb.OnchainSteps`), and only the wallet that placed the
  bid can settle it; a note names both while the wallet app has another one
  open. Nothing is stored: the review lives on this page only, the browser
  reports a hash and stops, and every outcome on screen is the server's own
  read of that hash against the review it was sent from. A confirmed return or
  claim asks the bid panel to read the wallet's bids again.

  Both rows answer the page tool that settles a bid, named `auction:bid id`
  (`AutolaunchWeb.AgentPress`): the call presses what the row offers now.
  """

  use AutolaunchWeb, :live_component

  import AutolaunchWeb.Components.StepState

  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Client, Rpc}
  alias Autolaunch.Robinhood.{Lab, StockBidSettlementActions}
  alias Autolaunch.Stocks.Amounts
  alias AutolaunchWeb.{AgentPress, OnchainSteps, RobinhoodStockBidComponent, TokenDisplay}
  alias AutolaunchWeb.Components.{AuctionBook, SwapForm}
  alias AutolaunchWeb.UsdValue
  alias RegentChain.{Address, Presses, Review}

  @copy %{
    authentication_required: "Sign in to settle this bid.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer: "Switch to a wallet on your account in your wallet app, then press again.",
    invalid_address: "Connect your wallet, then press again.",
    not_your_bid:
      "This bid was placed from a different wallet. Switch to that wallet to settle it.",
    bid_not_found: "The auction has no record of this bid.",
    chain_unavailable: "Robinhood could not be read just now. Try again in a moment.",
    invalid_chain_response: "Robinhood gave an incomplete answer. Try again in a moment.",
    robinhood_unavailable: "Robinhood auctions are not open on this site.",
    invalid_auction: "This is not an auction address.",
    auction_not_found: "This auction was not made by a Memestake launchpad.",
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
     |> assign_new(:ended, fn -> false end)
     |> assign_new(:stake_path, fn -> nil end)
     |> OnchainSteps.adopt()
     |> followed()
     |> offer()}
  end

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
        other_wallet: other_wallet(assigns)
      )

    ~H"""
    <div
      id={@id}
      class="bid-early-return"
      phx-hook="OnchainSteps"
      data-agent-tools="autolaunch_settle_bid"
      data-agent-bid={agent_bid(assigns)}
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
        <p hidden={!returning(@prepared)}>
          <%= if returning(@prepared) do %>
            <TokenDisplay.price
              amount={@prepared.facts.stock_refunded}
              unit={@prepared.facts.stock_symbol}
              round={:down}
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
        <p role="status" aria-live="polite" hidden={!early_progress(@steps, @settled)}>
          {early_progress(@steps, @settled)}
        </p>
        <p role="status" hidden={!@other_wallet}>{@other_wallet}</p>
        <p class="bid-notice" role="status" hidden={!@press_note}>{@press_note}</p>
        <SwapForm.wallet_step
          next_step={@next_step}
          steps={@steps}
          reverted={reverted(@steps, @token_symbol)}
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
        other_wallet: other_wallet(assigns),
        claimed: claimed(assigns.settled),
        returned: returned?(assigns.bid, assigns.graduated?)
      )

    ~H"""
    <div
      id={@id}
      class="bid-settlement-row"
      phx-hook="OnchainSteps"
      data-agent-tools="autolaunch_settle_bid"
      data-agent-bid={agent_bid(assigns)}
    >
      <p class="launch-wallet-settled" role="status" hidden={!@returned}>
        {copy(:failed_bid_returned)}
      </p>
      <.link
        :if={@stake_path && (@claimed || claimed_bid?(@bid, @graduated?))}
        navigate={stake_link(@stake_path, @claimed)}
        class="rg-button rg-button--secondary"
      >
        Memestake {@token_symbol}
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
          prepared={@prepared}
          token_symbol={@token_symbol}
          rate={@usd_rate}
          owner={@bid["owner"]}
          chain={@review && @review.chain}
        />
        <ol class="bid-steps" role="list" aria-label="Settlement progress" hidden={@steps == []}>
          <li :for={step <- @steps} data-step={step.name}>
            <span>
              <TokenDisplay.marked text={step.label} tickers={tickers(@prepared, @token_symbol)} />
            </span>
            <.step_state state={chip(step, @next_step)} />
          </li>
        </ol>
        <p class="bid-notice" role="status" hidden={!@notice}>{@notice}</p>
        <p
          class="bid-progress__status"
          role="status"
          aria-live="polite"
          hidden={!progress_copy(@steps, @settled, @prepared, @token_symbol)}
        >
          <TokenDisplay.marked
            text={progress_copy(@steps, @settled, @prepared, @token_symbol) || ""}
            tickers={tickers(@prepared, @token_symbol)}
          />
        </p>
        <p role="status" hidden={!@other_wallet}>{@other_wallet}</p>
        <p class="bid-notice" role="status" hidden={!@press_note}>{@press_note}</p>
        <SwapForm.wallet_step
          next_step={@next_step}
          steps={@steps}
          reverted={reverted(@steps, @token_symbol)}
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
              round={:down}
            />
            <UsdValue.usd amount={@prepared.facts.stock_refunded} rate={@rate} />
          </dd>
        </div>
        <div :if={positive?(@prepared.facts.tokens_claimed || @prepared.facts.tokens_filled)}>
          <dt>You get</dt>
          <dd>
            <TokenDisplay.written
              value={tokens(@prepared.facts.tokens_claimed || @prepared.facts.tokens_filled)}
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
              round={:down}
            />
            <UsdValue.usd amount={@prepared.facts.final_price} rate={@rate} per="per token" />
          </dd>
        </div>
        <div>
          <dt>Receiving wallet</dt>
          <dd class="bid-settlement__address" title={@owner}>
            {RegentFormat.short_address(@owner)}
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

  # An agent's press: the step the row's button would send now, or, after the
  # auction, the settlement the row offers, prepared and sent at once.
  def handle_event("agent_press", %{"tool" => "autolaunch_settle_bid"}, socket) do
    assigns = socket.assigns

    cond do
      is_nil(assigns.linked) ->
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

      settle_key(assigns) ->
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
        AutolaunchWeb.Telemetry.wallet_failed(:robinhood_bid_settlement, reason)
        {:noreply, assign(socket, press_note: failure_note(socket.assigns, reason))}

      :error ->
        {:noreply, socket}
    end
  end

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

  defp start_prepare(socket, {signer, _bid_id, _exited, _filled} = key) do
    request = request(socket.assigns)
    opts = opts(socket)

    socket
    |> assign(preparing: key)
    |> start_async(:prepare, fn ->
      {key, StockBidSettlementActions.prepare(request, signer, opts)}
    end)
  end

  # Once bidding has ended, a bid of the wallet on screen that still has
  # something to return or claim.
  defp settle_key(%{early: false, ended: true, signer: signer, bid: bid} = assigns)
       when is_binary(signer) do
    if owner?(assigns) and !settled_bid?(bid),
      do: {signer, bid["bid_id"], bid["exited_block"], bid["tokens_filled_now"]}
  end

  defp settle_key(_assigns), do: nil

  defp request(%{auction: auction, bid: %{"bid_id" => bid_id}}),
    do: %{auction: auction, bid_id: bid_id}

  # An agent waits for this one: it is prepared at once.
  defp agent_settle(%{assigns: assigns} = socket) do
    {signer, _bid_id, _exited, _filled} = key = settle_key(assigns)
    result = StockBidSettlementActions.prepare(request(assigns), signer, opts(socket))
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
      is_nil(assigns.linked) -> socket
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
    acting = if owner?(assigns), do: signer
    offered = if assigns.review, do: :record
    opts = opts(socket)

    socket
    |> assign(checking: true)
    |> start_async(:early, fn ->
      {signer, early_offer(Map.put(request, :owner, owner), acting, offered, opts)}
    end)
  end

  # Read-only until the stock can come back, now or after recording the
  # price, and the bid's own wallet is active: only then is a review
  # prepared, and a review already offered for the same answer is kept.
  defp early_offer(request, acting, offered, opts) do
    case StockBidSettlementActions.return_status(request) do
      {:ok, status} when status in [:now, :record] and is_binary(acting) and status != offered ->
        {status, StockBidSettlementActions.prepare(request, acting, opts)}

      {:ok, status} ->
        {status, nil}

      {:error, error} ->
        {:refused, error}
    end
  end

  defp offered(socket, _key, nil), do: socket

  defp offered(socket, {status, signer}, result),
    do: reviewed(socket, {signer, socket.assigns.bid["bid_id"], status, nil}, result)

  # Outcomes

  # A recorded price makes the return possible: the auction is asked again at
  # once, and the return prepared against the recorded price. A return or a
  # claim is read from its receipt.
  defp confirmed(socket, %{name: "record"}),
    do: socket |> assign(recorded: true, checked_at: nil) |> withdrawn() |> early_check()

  defp confirmed(socket, %{hash: hash, review: review}),
    do: start_async(socket, {:result, hash}, fn -> Client.receipt(review.chain, hash) end)

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
      entry = OnchainSteps.entry(presses, review, name)
      %{name: name, label: label(name, prepared), state: press_state(entry), entry: entry}
    end)
  end

  defp steps(_assigns), do: []

  defp reviewed_next(steps), do: Enum.find(steps, &(&1.state in [:ready, :reverted, :other]))

  # One button at a time: the first step the wallet has not sent from this
  # review yet, or one that did not go through. While the settlement is being
  # prepared the button names what the bid offers; one the auction refused
  # has nothing to send. A sent step moves the button on at once; nothing
  # waits for the network before the next press can reach the wallet.
  defp next_step(%{review: %{}}, steps, _key), do: reviewed_next(steps)
  defp next_step(_assigns, _steps, nil), do: nil
  defp next_step(%{prepared_for: {:refused, key}}, _steps, key), do: nil
  defp next_step(assigns, _steps, _key), do: %{name: "settle", label: offer_label(assigns)}

  defp offer_label(%{graduated?: false} = assigns), do: "Withdraw #{stock_symbol(assigns)}"

  defp offer_label(%{bid: %{"exited_block" => "0"}} = assigns),
    do: "Withdraw unspent #{stock_symbol(assigns)}"

  defp offer_label(%{token_symbol: symbol}), do: "Claim #{symbol} to wallet"

  defp stock_symbol(%{prepared: %{facts: %{stock_symbol: symbol}}}), do: symbol
  defp stock_symbol(_assigns), do: "your stock"

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
    do: "Withdraw #{if facts.graduated, do: "unspent ", else: ""}#{facts.stock_symbol}"

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
    do: "#{tokens(tokens)} #{token_symbol} tokens were delivered to your wallet."

  defp settled_copy(%{"stock_refunded_units" => refunded}, prepared, _token_symbol),
    do:
      "#{TokenDisplay.short(refunded, :down)} #{stock_symbol(%{prepared: prepared})} was returned to your wallet."

  defp settled_copy(_none, _prepared, _token_symbol), do: nil

  defp reverted(steps, token_symbol) do
    case Enum.find(steps, &(&1.state == :reverted)) do
      %{name: "record"} ->
        "Recording the price did not go through. Only the network fee was spent. Press again."

      %{name: "claim"} ->
        "That claim did not go through, so no #{token_symbol} moved. Only the network fee was spent. Press again."

      %{} ->
        "That did not go through, so nothing came back. Only the network fee was spent. Press again."

      nil ->
        nil
    end
  end

  # The bid's own wallet settles it; while another wallet on the account is
  # active, the row says which one to switch to.
  defp other_wallet(%{signer: signer, bid: %{"owner" => owner}} = assigns)
       when is_binary(signer) do
    if !owner?(assigns),
      do:
        "This bid was placed from #{RegentFormat.short_address(owner)}. Switch to that wallet in your wallet app to settle it."
  end

  defp other_wallet(_assigns), do: nil

  defp owner?(%{signer: signer, bid: %{"owner" => owner}}) when is_binary(signer),
    do: Address.equal?(signer, owner)

  defp owner?(_assigns), do: false

  defp failure_note(%{review: review} = assigns, reason) do
    chain_name = if review, do: review.chain.name, else: Lab.network_name(Lab.chain_id())
    OnchainSteps.failure_note(reason, assigns.linked, assigns.active, chain_name)
  end

  defp no_signer(%{active: nil}), do: "Connect your wallet, then press again."
  defp no_signer(_assigns), do: copy(:wrong_signer)

  # The bid as the page tool names it: its auction and its id.
  defp agent_bid(%{auction: auction, bid: %{"bid_id" => bid_id}}),
    do: String.downcase("#{auction}:#{bid_id}")

  # The one line under the bid, from the auction's answer; the minimum still
  # to raise is the auction's own minimum less what it has raised.
  defp line({:minimum, raised}, launch) do
    missing = String.to_integer(launch.required_currency_raised) - raised
    {:minimum, Rpc.format_units(max(missing, 0), launch.quote_token_decimals)}
  end

  defp line(status, _launch) when status in [:now, :record, :buying], do: status
  defp line(_status, _launch), do: nil

  # Why an early row has nothing to send, in the words of its line.
  defp early_refusal(%{settled: %{}}), do: "This bid's unspent stock has already come back."
  defp early_refusal(%{notice: message}) when is_binary(message), do: message

  defp early_refusal(%{status: :buying}),
    do: "This bid is still buying at the current price, so none of its stock is unspent yet."

  defp early_refusal(%{status: {:minimum, _raised}}),
    do: "The unspent stock can come back once the auction raises its minimum."

  defp early_refusal(_assigns),
    do: "The page is still asking the auction about this bid. Call again in a moment."

  # Why a row after the auction has nothing to offer.
  defp settled_refusal(%{ended: false}), do: copy(:auction_not_ended)
  defp settled_refusal(%{notice: message}) when is_binary(message), do: message
  defp settled_refusal(_assigns), do: "Nothing is left to settle on this bid."

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

  # The staking panel, with the claimed amount entered when it is known here.
  defp stake_link(path, nil), do: path

  defp stake_link(path, amount),
    do:
      String.replace_suffix(path, "#stake", "?" <> URI.encode_query(%{stake: amount}) <> "#stake")

  defp positive?(value) when is_binary(value) and value != "",
    do: Decimal.gt?(Decimal.new(value), 0)

  defp positive?(_value), do: false

  # The tickers a settlement's sentences name.
  defp tickers(%{facts: %{stock_symbol: symbol}}, token_symbol), do: [symbol, token_symbol]
  defp tickers(_prepared, token_symbol), do: [token_symbol]

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  defp copy(reason), do: Map.get(@copy, reason, @generic)

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil

  # A token amount cut to four significant digits, never rounded up, its whole
  # part grouped in thousands: 68493.15 reads as 68,490.
  defp tokens(value), do: value |> TokenDisplay.short(:down) |> Amounts.grouped()
end
