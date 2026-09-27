defmodule AutolaunchWeb.RobinhoodStockBidComponent do
  @moduledoc """
  A USDG bid on a Robinhood memestock auction: the bid is prepared as the form
  changes, and its button sends at most two transactions (the exact USDG
  allowance when one is needed, then the bid itself).

  The wallet that acts is Privy's active wallet when the signed-in account
  links it (`AutolaunchWeb.OnchainSteps`); the bids listed are that wallet's,
  or the signed-in wallet's until Privy reports one, and a note names both
  while the wallet app has another one open. Nothing is stored: the review
  lives on this page only, the browser reports a hash and stops, and every
  outcome on screen is the server's own read of that hash against the review
  it was sent from. A wallet's bids are the auction's own records. Once the
  auction has ended, the page passes what that means for bidders and the card
  keeps only the wallet's bids and their settlement.

  While bidding is open, each of the wallet's bids says where it stands. One
  still buying can be added to and an outbid one raised, both through this
  panel's own form (each places a new bid with new money). Under an outbid
  one, or one sharing at the price, a line says when its unspent stock can
  come back, and the early return is offered once it can (`launch`, the
  auction's listing, gives the minimum and the end time). With
  `outbid_banner`, the page is told whenever a bid is outbid, so it can say so
  at the top. With `agent_tools`, the panel also answers the page tool that
  bids (`AutolaunchWeb.AgentPress`): the call is pressed exactly as the button
  would be.
  """

  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.{AuctionBook, BidPrice}
  alias Autolaunch.Robinhood.{Lab, StockBidActions}
  alias Autolaunch.Stocks.MarketData
  alias AutolaunchWeb.{AgentPress, OnchainSteps, Paths, ShareCard, TokenDisplay, UsdValue}
  alias AutolaunchWeb.Components.AuctionBook, as: Book
  alias AutolaunchWeb.Components.{BidForm, BidPlaced, SwapForm}
  alias Phoenix.LiveView.{AsyncResult, JS}
  alias RegentChain.{Presses, Review}

  @copy %{
    authentication_required: "Sign in to bid from your wallet.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer: "Switch to a wallet on your account in your wallet app, then press again.",
    invalid_address: "Connect your wallet, then press again.",
    chain_unavailable: "Robinhood could not be read just now. Try again in a moment.",
    invalid_chain_response: "Robinhood gave an incomplete answer. Try again in a moment.",
    invalid_block_header: "Robinhood gave an incomplete answer. Try again in a moment.",
    robinhood_unavailable: "Robinhood auctions are not open on this site.",
    invalid_auction: "This is not an auction address.",
    unknown_auction: "No Robinhood auction was found at this address.",
    amount_required: "Enter a USDG amount above zero.",
    invalid_amount: "Enter a USDG amount above zero.",
    amount_not_representable: "USDG amounts have at most 6 decimal places.",
    amount_above_balance: "This wallet holds less USDG than that.",
    max_price_required: "Enter a maximum price above zero.",
    invalid_decimal: "Enter the amount and the maximum price as plain numbers above zero.",
    price_below_admissible_tick:
      "Your maximum price is too low. Set it above the auction's current price.",
    price_out_of_range: "This maximum price cannot be used. Try a different one.",
    bid_preparation_unavailable:
      "This maximum price cannot be used. Set it above the auction's current price.",
    usdg_route_unavailable: "USDG cannot be converted for this auction right now.",
    stock_route_unavailable: "USDG cannot be converted for this auction right now.",
    quote_out_of_range: "USDG cannot be converted for this auction right now.",
    stock_not_listed: "This auction's stock is not one this site lists."
  }

  @generic "That did not go through. Try again in a moment."

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> OnchainSteps.init()
     |> assign(
       wallet: nil,
       signer: nil,
       mismatch: nil,
       reading: nil,
       reading_for: nil,
       prepared: nil,
       prepared_for: nil,
       preparing: nil,
       notice: nil,
       carried_note: nil,
       placed: nil,
       new_bid: false,
       told_outbid: nil,
       x_connection: nil,
       x_enabled: false
     )}
  end

  @impl true
  def update(%{refresh_bids: true}, socket), do: {:ok, read_bids(socket)}

  # A review holds its quote for fifteen minutes, so it is built again once it
  # is ten minutes old (`OnchainSteps.refresh_later/1`).
  def update(%{refresh_review: review_id}, socket) do
    case socket.assigns.review do
      %{id: ^review_id} -> {:ok, rebuilt(socket, nil)}
      _other -> {:ok, socket}
    end
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:ended, fn -> nil end)
     |> assign_new(:stake_path, fn -> nil end)
     |> assign_new(:outbid_banner, fn -> false end)
     |> assign_new(:agent_tools, fn -> false end)
     |> assign_new(:authenticated, fn -> false end)
     |> assign_new(:current_human_id, fn -> nil end)
     |> assign_new(:session_lease, fn -> nil end)
     |> assign_new(:form, fn -> %{blank() | amount: Map.get(assigns, :preset_amount) || ""} end)
     |> assign_book_and_supply()
     |> assign_usd_prices()
     |> OnchainSteps.adopt()
     |> followed()
     |> prepare_when_ready()
     |> told_outbid()}
  end

  @doc """
  What an auction's end means for its bidders, from its listing, passed as
  `ended`; nil while bidding is open.
  """
  def ended_copy(%{state: :graduated, quote_token_symbol: symbol}),
    do:
      "The auction raised its minimum. Bids at or above the final price can claim tokens, and every bidder can withdraw the #{symbol} their bid did not spend."

  def ended_copy(%{state: :failed, quote_token_symbol: symbol}),
    do:
      "The auction did not raise its minimum. Every bidder can withdraw their whole bid in #{symbol}."

  def ended_copy(%{state: :ended, minimum_reached: true, quote_token_symbol: symbol}),
    do:
      "Bidding has ended and the auction raised its minimum. Its trading pool opens once the auction is finished. Bids at or above the final price can claim tokens, and every bidder can withdraw the #{symbol} their bid did not spend."

  def ended_copy(%{state: :ended, quote_token_symbol: symbol}),
    do:
      "Bidding has ended. If the final count stays below the minimum, every bidder can withdraw their whole bid in #{symbol}; if it reached the minimum, the trading pool opens once the auction is finished."

  def ended_copy(_launch), do: nil

  # The panel follows the wallet that may act. A review is built for one
  # signer, so another one withdraws it; the bids listed are that signer's, or
  # the signed-in wallet's while no wallet on the account is active.
  defp followed(socket) do
    %{linked: linked, active: active, signed_in: signed_in} = socket.assigns
    signer = OnchainSteps.signer(linked, active)
    wallet = signer || signed_in

    socket =
      socket
      |> assign(signer: signer, mismatch: OnchainSteps.mismatch_note(linked, active))
      |> reviewed_for_signer(signer)

    if wallet == socket.assigns.wallet,
      do: socket,
      else: socket |> assign(wallet: wallet, reading: nil) |> read_bids()
  end

  defp reviewed_for_signer(%{assigns: %{review: %{signer: signer}}} = socket, signer), do: socket
  defp reviewed_for_signer(%{assigns: %{review: nil}} = socket, _signer), do: socket
  defp reviewed_for_signer(socket, _signer), do: withdrawn(socket)

  defp withdrawn(socket),
    do:
      socket
      |> assign(prepared: nil, prepared_for: nil)
      |> OnchainSteps.put_review(nil)

  @impl true
  def render(assigns) do
    usd_rate = UsdValue.stock_rate(assigns.usd_prices.result, reading_symbol(assigns.reading))

    assigns =
      assign(assigns,
        usd_rate: usd_rate,
        rows: rows(assigns),
        steps: steps(assigns),
        next_step: next_step(assigns)
      )

    ~H"""
    <section
      id={@id}
      class="bid-panel"
      phx-hook="OnchainSteps"
      data-agent-tools={@agent_tools && "autolaunch_bid"}
    >
      <BidForm.title id={@id} title={if @ended, do: "Bidding has ended", else: "Place a bid"}>
        <:help :if={!@ended}>
          <p>
            Bid with <span class="ticker">USDG</span>. It is converted into the auction's stock inside the bid, and any
            unspent part comes straight back.
          </p>
          <p>
            Your max budget is the most you'll spend. Your max FDV is the most the whole token
            supply may be worth while your bid keeps buying.
          </p>
          <p>Your wallet confirms every step.</p>
        </:help>
      </BidForm.title>
      <p :if={@ended} class="bid-ended">
        <TokenDisplay.marked text={@ended} tickers={[@token_symbol, stock_symbol(@reading)]} />
      </p>
      <p class="launch-wallet-notice" role="status" hidden={!(@notice && (@ended || @placed))}>
        {@notice}
      </p>

      <p :if={!@authenticated} class="bid-empty">
        <Regent.Primitives.button type="button" data-account-target="sign-in">
          {if @ended, do: "Sign in to see your bids", else: "Sign in to bid"}
        </Regent.Primitives.button>
      </p>

      <%!-- Panels stay in the page and are only hidden, so one appearing never
           replaces the wallet button a person has just pressed. --%>
      <div class="bid-body" hidden={!(@authenticated && @wallet)}>
        <p :if={@ended && @reading && @reading.bids == []} class="bid-empty">
          This wallet placed no bids on this auction.
        </p>

        <section id={"#{@id}-placed"} class="bid-progress" aria-label="Bid placed" hidden={!@placed}>
          <%= if @placed do %>
            <BidPlaced.bid_placed
              id={"#{@id}-placed"}
              target={@myself}
              token_symbol={@token_symbol}
              chain={:robinhood}
              hash={@placed.hash}
              test_chain={Lab.test_chain?(@placed.chain_id)}
              auction_path={Paths.auction(@launch)}
              auction_url={Paths.auction_url(@launch)}
              share_image={ShareCard.auction_image_url(@launch, DateTime.utc_now())}
              x_connection={@x_connection}
              x_enabled={@x_enabled}
            />
          <% end %>
          <Regent.Primitives.button
            type="button"
            phx-click="clear_bid"
            phx-target={@myself}
            variant="secondary"
          >
            Place another bid
          </Regent.Primitives.button>
        </section>

        <p class="bid-form__note" hidden={!(@new_bid && !@ended && !@placed)}>
          This places a new bid with new money. Your first bid stays as it is.
        </p>
        <div class="bid-entry" hidden={!!(@ended || @placed)}>
          <BidForm.bid_form
            id={@id}
            target={@myself}
            form={@form}
            amount_unit="USDG"
            price_unit={stock_symbol(@reading)}
            token_symbol={@token_symbol}
            book={@book}
            supply={supply(@supply)}
            rate={@usd_rate}
          />
          <%!-- Outside the form: a wallet button is never inside one. --%>
          <div class="bid-actions">
            <p class="bid-notice" role="alert" hidden={!@notice}>{@notice}</p>
            <.summary
              prepared={@prepared}
              token_symbol={@token_symbol}
              chain_name={@review && @review.chain.name}
            />
            <p class="bid-form__note" hidden={signatures_left(@steps, @next_step) < 2}>
              Your wallet asks twice: first to let the auction use your <span class="ticker">USDG</span>,
              last to place the bid.
            </p>
            <p
              class="bid-progress__status"
              role="status"
              aria-live="polite"
              hidden={!progress_copy(@steps)}
            >
              <TokenDisplay.marked text={progress_copy(@steps) || ""} tickers={["USDG"]} />
            </p>
            <a
              href={
                pending_hash(@steps) && BidPlaced.transaction_url(:robinhood, pending_hash(@steps))
              }
              target="_blank"
              rel="noopener noreferrer"
              hidden={!pending_hash(@steps) || Lab.test_chain?(@review && @review.chain.chain_id)}
            >
              View on Blockscout ↗
            </a>
            <p class="bid-notice" role="status" hidden={!@press_note}>{@press_note}</p>
            <SwapForm.wallet_step
              next_step={@next_step}
              steps={@steps}
              reverted={reverted(@steps)}
              signer={@review && @review.signer}
              chain_name={@review && @review.chain.name}
              mismatch={@mismatch}
              check_event="check_again"
              target={@myself}
            />
          </div>
        </div>

        <section
          :if={@reading && @reading.bids != []}
          class="launch-wallet-settled"
          aria-label="Your bids"
        >
          <h3>Your bids on this auction</h3>
          <ul role="list">
            <li :for={{bid, standing} <- @rows} id={"#{@id}-bid-#{bid["bid_id"]}"}>
              <p>
                Bid <span class="figure__value">#{bid["bid_id"]}</span>
                ·
                <TokenDisplay.written
                  value={bid["stock_committed_units"]}
                  unit={@reading.stock["symbol"]}
                />
                <UsdValue.usd amount={bid["stock_committed_units"]} rate={@usd_rate} />
                <Regent.Primitives.status
                  :if={standing in [:in, :sharing]}
                  tone={if standing == :in, do: "success", else: "warning"}
                >
                  {Book.standing_label(standing)}
                </Regent.Primitives.status>
                <span :if={is_nil(standing)}>
                  · {bid_state(bid, (@book.ok? && @book.result) || nil, @reading)}
                </span>
              </p>
              <Book.outbid_status
                :if={standing == :outbid}
                price={@book.result.clearing}
                unit={@reading.stock["symbol"]}
              />
              <.live_component
                :if={standing in [:outbid, :sharing]}
                module={AutolaunchWeb.RobinhoodStockBidSettlementComponent}
                id={"#{@id}-early-#{bid["bid_id"]}"}
                parent_id={@id}
                early
                recheck={@book.result.block}
                auction={@auction}
                launch={@launch}
                bid={bid}
                graduated?={@reading.graduated?}
                token_symbol={@token_symbol}
                usd_rate={@usd_rate}
                current_human_id={@current_human_id}
                session_lease={@session_lease}
              />
              <Regent.Primitives.button
                :if={standing == :outbid}
                type="button"
                phx-click={JS.push("raise_bid", value: %{bid_id: bid["bid_id"]}, target: @myself)}
                variant="secondary"
              >
                Raise my bid to keep buying
              </Regent.Primitives.button>
              <Regent.Primitives.button
                :if={standing in [:in, :sharing]}
                type="button"
                phx-click={JS.push("add_to_bid", value: %{bid_id: bid["bid_id"]}, target: @myself)}
                variant="secondary"
              >
                Add to this bid
              </Regent.Primitives.button>
              <.live_component
                :if={is_nil(standing)}
                module={AutolaunchWeb.RobinhoodStockBidSettlementComponent}
                id={"#{@id}-settle-#{bid["bid_id"]}"}
                parent_id={@id}
                ended={bidding_over?(@reading)}
                auction={@auction}
                bid={bid}
                graduated?={@reading.graduated?}
                stake_path={@stake_path}
                token_symbol={@token_symbol}
                usd_rate={@usd_rate}
                current_human_id={@current_human_id}
                session_lease={@session_lease}
              />
            </li>
          </ul>
        </section>
      </div>
    </section>
    """
  end

  attr :prepared, :map, default: nil
  attr :token_symbol, :string, required: true
  attr :chain_name, :string, default: nil

  # The bid in three lines: what it spends, what it buys and at most what
  # price, and where.
  defp summary(assigns) do
    ~H"""
    <dl class="bid-form__summary" aria-label="Your bid" hidden={!@prepared}>
      <%= if @prepared do %>
        <div>
          <dt>You pay</dt>
          <dd><TokenDisplay.written value={@prepared.facts.usdg_amount} unit="USDG" /></dd>
        </div>
        <div>
          <dt>You get</dt>
          <dd>
            <span class="ticker">{@token_symbol}</span>
            at up to
            <TokenDisplay.price
              amount={@prepared.facts.max_price}
              unit={@prepared.facts.stock_symbol}
            /> each
          </dd>
        </div>
        <div>
          <dt>Network</dt><dd>{@chain_name}</dd>
        </div>
      <% end %>
    </dl>
    <p class="bid-form__note" hidden={!@prepared}>
      <%= if @prepared do %>
        Your <span class="ticker">USDG</span>
        buys at least
        <TokenDisplay.written
          value={@prepared.facts.min_stock_out}
          unit={@prepared.facts.stock_symbol}
        />, 1% below today's quote, or the bid is not placed.
      <% end %>
    </p>
    <p class="bid-form__note" hidden={!(@prepared && @prepared.facts.max_price_adjusted)}>
      <%= if @prepared && @prepared.facts.max_price_adjusted do %>
        The most per token was brought down to the auction's price step below the {@prepared.facts.max_price_entered} you entered.
      <% end %>
    </p>
    """
  end

  @impl true
  def handle_event("onchain_active_wallet", params, socket) do
    active = OnchainSteps.active_wallet(params)

    socket =
      if active == socket.assigns.active,
        do: socket,
        else: assign(socket, active: active, press_note: nil)

    {:noreply, socket |> followed() |> prepare_when_ready()}
  end

  def handle_event("bid_form_changed", params, socket) do
    form = BidForm.values(params, socket.assigns.form, max_price(socket.assigns))
    {:noreply, socket |> assign(form: form, notice: nil) |> prepare_when_ready()}
  end

  # The price to beat, entered from the auction's price panel as the limit.
  def handle_event("use_price", %{"price" => price}, socket) do
    form = BidForm.at_price(socket.assigns.form, price)
    {:noreply, socket |> assign(form: form, notice: nil) |> prepare_when_ready()}
  end

  # A press made while the form on screen differs from the review the page
  # holds, or before there is one: the bid is prepared for exactly the values
  # pressed and its first step handed back to send.
  def handle_event("prepare_and_send", %{"form" => inputs}, socket) when is_map(inputs) do
    socket = assign(socket, form: pressed_form(socket.assigns, inputs), notice: nil)

    case prepared_now(socket) do
      {:ok, %{assigns: %{review: %{steps: [%{step: first} | _rest]} = review}} = socket} ->
        {:reply, %{review: review, send: first}, socket}

      {:error, socket} ->
        {:reply, %{}, socket}
    end
  end

  # An agent's press, for exactly the values it names: the step on screen when
  # the panel already holds that bid, otherwise the first step of the bid
  # prepared for them. The form shows the values, as if typed.
  def handle_event("agent_press", %{"tool" => "autolaunch_bid"} = params, socket) do
    input = if is_map(params["input"]), do: params["input"], else: %{}

    cond do
      socket.assigns.ended ->
        {:reply, AgentPress.refused("Bidding has ended on this auction."), socket}

      Map.has_key?(input, "pay_with") ->
        {:reply, AgentPress.refused("Robinhood bids are paid in USDG; leave pay_with out."),
         socket}

      !socket.assigns.authenticated ->
        {:reply, AgentPress.refused(copy(:authentication_required)), socket}

      true ->
        form = %{
          BidForm.at_price(socket.assigns.form, input["max_price"])
          | amount: input["amount"] || ""
        }

        socket |> assign(form: form, notice: nil, placed: nil) |> agent_bid()
    end
  end

  # A new bid for an outbid one: about the same money, at the current price.
  def handle_event("raise_bid", %{"bid_id" => bid_id}, socket) do
    %{usd_prices: prices, reading: reading} = socket.assigns
    rate = UsdValue.stock_rate(prices.result, reading_symbol(reading))
    amount = socket.assigns |> own_bid(bid_id) |> usdg_worth(rate)
    {:noreply, new_bid_entered(socket, %{blank() | amount: amount})}
  end

  # A new bid beside one still buying, up to the same most per token.
  def handle_event("add_to_bid", %{"bid_id" => bid_id}, socket) do
    limit = socket.assigns |> own_bid(bid_id) |> bid_max_price(socket.assigns.book)
    {:noreply, new_bid_entered(socket, BidForm.at_price(blank(), limit))}
  end

  def handle_event("clear_bid", _params, socket),
    do:
      {:noreply,
       socket
       |> assign(placed: nil, new_bid: false, form: blank())
       |> withdrawn()}

  def handle_event("step_sent", params, socket),
    do: {:noreply, OnchainSteps.sent(socket, params)}

  def handle_event("step_failed", params, socket) do
    case Presses.failed(params) do
      {:ok, _name, reason} ->
        AutolaunchWeb.Telemetry.wallet_failed(:robinhood_bid, reason)
        {:noreply, assign(socket, press_note: failure_note(socket.assigns, reason))}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("check_again", %{"hash" => hash}, socket) when is_binary(hash),
    do: {:noreply, OnchainSteps.check_again(socket, hash)}

  def handle_event("share_opened", _params, socket), do: {:noreply, load_x(socket)}

  def handle_event("refresh_x_connections", _params, socket), do: {:noreply, load_x(socket)}

  @impl true
  def handle_async(:prepare, {:ok, {key, inputs, result}}, socket) do
    socket = assign(socket, preparing: nil)

    if key == bid_key(socket.assigns),
      do: {:noreply, reviewed(socket, key, inputs, result)},
      else: {:noreply, prepare_when_ready(socket)}
  end

  def handle_async(:prepare, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, preparing: nil, notice: @generic)}

  # The wallet's bids, from the auction's own records. A read that fails
  # keeps the last one read for the same wallet and says why.
  def handle_async(:bids, {:ok, {wallet, read}}, %{assigns: %{wallet: wallet}} = socket) do
    case read do
      {:ok, reading} ->
        {:noreply,
         socket
         |> assign(reading: reading, reading_for: wallet, notice: nil)
         |> prepare_when_ready()
         |> told_outbid()}

      {:error, error} ->
        {:noreply, assign(socket, notice: copy(refusal(error)))}
    end
  end

  def handle_async(:bids, {:ok, _other_wallet}, socket), do: {:noreply, socket}

  def handle_async(:bids, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, notice: copy(:chain_unavailable))}

  def handle_async({:onchain_step, hash}, result, socket),
    do: {:noreply, OnchainSteps.checked(socket, hash, result, &confirmed/2, &step_reverted/2)}

  # Reviews

  # The bid is prepared in the background whenever what it would send changes:
  # the wallet, the total or the most per token (which moves with the price to
  # beat). One is prepared at a time; an answer for values the form has since
  # left starts the next.
  defp prepare_when_ready(%{assigns: assigns} = socket) do
    key = bid_key(assigns)

    cond do
      is_nil(key) or assigns.ended or assigns.placed -> socket
      assigns.preparing -> socket
      assigns.prepared_for in [key, {:refused, key}] -> socket
      true -> start_prepare(socket, key)
    end
  end

  defp start_prepare(socket, key) do
    {signer, request} = request(socket.assigns, key)
    inputs = inputs(socket.assigns)
    opts = opts(socket)

    socket
    |> assign(preparing: key)
    |> start_async(:prepare, fn ->
      {key, inputs, StockBidActions.prepare(request, signer, opts)}
    end)
  end

  # A press or an agent waits for this one: it is prepared at once.
  defp prepared_now(%{assigns: assigns} = socket) do
    case bid_key(assigns) do
      nil ->
        {:error, assign(socket, notice: incomplete(assigns))}

      key ->
        {signer, request} = request(assigns, key)
        result = StockBidActions.prepare(request, signer, opts(socket))
        socket = reviewed(socket, key, inputs(assigns), result)
        if match?({:ok, _prepared}, result), do: {:ok, socket}, else: {:error, socket}
    end
  end

  defp request(%{auction: auction}, {signer, amount, max_price}),
    do: {signer, %{auction: auction, usdg_amount: amount, max_price: max_price}}

  defp reviewed(socket, key, inputs, {:ok, prepared}) do
    review =
      Review.new(socket.assigns.id, elem(key, 0), prepared.chain, prepared.steps, inputs)

    socket
    |> assign(prepared: prepared, prepared_for: key, notice: nil)
    |> assign(press_note: socket.assigns.carried_note, carried_note: nil)
    |> OnchainSteps.put_review(review)
    |> OnchainSteps.refresh_later()
  end

  defp reviewed(socket, key, _inputs, {:error, error}),
    do: assign(socket, prepared_for: {:refused, key}, notice: copy(refusal(error)))

  # The review built again from Robinhood Chain with the form as it is, so its
  # quote and deadline are current: once it is ten minutes old, once an approval
  # lands, and once a step reverts, when `note` says so beside the new button.
  # While a step sent from it is on its way it stays, and a timer asks again
  # later.
  defp rebuilt(%{assigns: %{review: review, presses: presses}} = socket, note) do
    if OnchainSteps.pending?(presses, review),
      do: OnchainSteps.refresh_later(socket),
      else: socket |> assign(prepared_for: nil, carried_note: note) |> prepare_when_ready()
  end

  defp agent_bid(%{assigns: %{signer: nil} = assigns} = socket),
    do: {:reply, AgentPress.refused(no_signer(assigns)), socket}

  defp agent_bid(%{assigns: assigns} = socket) do
    case current_step(assigns) do
      %{name: name} -> {:reply, sending(assigns.review, name), socket}
      nil -> agent_prepared(socket)
    end
  end

  defp agent_prepared(socket) do
    case prepared_now(socket) do
      {:ok, socket} ->
        [%{step: first} | _rest] = socket.assigns.review.steps
        {:reply, sending(socket.assigns.review, first), socket}

      {:error, socket} ->
        {:reply, AgentPress.refused(socket.assigns.notice || @generic), socket}
    end
  end

  # The step the button sends, while the review on the page is for the form as it is now.
  defp current_step(assigns) do
    key = bid_key(assigns)

    if key && assigns.prepared_for == key && assigns.review,
      do: SwapForm.pressable(next_step(assigns), steps(assigns))
  end

  defp sending(review, step), do: AgentPress.sending(review, step, &step_label/1)

  defp no_signer(%{linked: nil}), do: copy(:authentication_required)
  defp no_signer(%{active: nil}), do: "Connect your wallet, then press again."
  defp no_signer(_assigns), do: copy(:wrong_signer)

  # The form as it was on screen when pressed: a max FDV that differs from the
  # one shown was typed, so the bid follows it.
  defp pressed_form(assigns, inputs) do
    shown = inputs(assigns)

    BidForm.values(
      %{
        "amount" => text(inputs["amount"]),
        "basis" => assigns.form.basis,
        "price" => assigns.form.price,
        "fdv" => text(inputs["fdv"]),
        "fdv_shown" => shown["fdv"],
        "stop" => Integer.to_string(assigns.form.stop),
        "stop_shown" => Integer.to_string(assigns.form.stop)
      },
      assigns.form,
      max_price(assigns)
    )
  end

  defp text(value) when is_binary(value), do: String.slice(value, 0, 256)
  defp text(_value), do: ""

  defp inputs(%{form: form, reading: reading} = assigns),
    do:
      BidForm.inputs(
        form,
        assigns.book,
        supply(assigns.supply),
        UsdValue.stock_rate(assigns.usd_prices.result, reading_symbol(reading)),
        stock_symbol(reading),
        []
      )

  # With no wallet to send from, the press's own note names the wallet to use.
  defp incomplete(%{signer: nil}), do: nil
  defp incomplete(%{form: %{amount: ""}}), do: copy(:amount_required)
  defp incomplete(_assigns), do: copy(:max_price_required)

  defp bid_key(%{signer: signer, form: form} = assigns) when is_binary(signer) do
    with amount when amount != "" <- form.amount,
         max_price when is_binary(max_price) <- max_price(assigns),
         do: {signer, amount, max_price},
         else: (_incomplete -> nil)
  end

  defp bid_key(_assigns), do: nil

  defp max_price(%{usd_prices: prices, reading: reading} = assigns) do
    rate = UsdValue.stock_rate(prices.result, reading_symbol(reading))
    {_unit, factor} = BidForm.fdv_currency("USDG", stock_symbol(reading), rate)
    BidForm.max_price(assigns.form, assigns.book, supply(assigns.supply), factor)
  end

  defp blank, do: %{BidForm.blank() | pay_with: "USDG"}

  defp supply(%AsyncResult{ok?: true, result: supply}), do: supply
  defp supply(_loading), do: nil

  # Outcomes

  # A bid landed: the panel shows it placed and reads the wallet's bids again.
  # A landed approval builds the review again, so the bid it leads to carries a
  # fresh deadline.
  defp confirmed(socket, %{name: "usdg_bid", hash: hash, review: review}) do
    socket
    |> assign(placed: %{hash: hash, chain_id: review.chain.chain_id}, new_bid: false)
    |> withdrawn()
    |> read_bids()
  end

  defp confirmed(%{assigns: %{review: %{id: id}}} = socket, %{review: %{id: id}}),
    do: rebuilt(socket, nil)

  defp confirmed(socket, _earlier_review), do: socket

  defp step_reverted(%{assigns: %{review: %{id: id}}} = socket, %{name: name, review: %{id: id}}),
    do: rebuilt(socket, reverted_copy(name))

  defp step_reverted(socket, _earlier_review), do: socket

  defp read_bids(%{assigns: %{wallet: wallet, auction: auction}} = socket)
       when is_binary(wallet) do
    opts = opts(socket)
    start_async(socket, :bids, fn -> {wallet, StockBidActions.bids(auction, wallet, opts)} end)
  end

  defp read_bids(socket), do: socket

  defp failure_note(%{review: review} = assigns, reason) do
    chain_name = if review, do: review.chain.name, else: Lab.network_name(Lab.chain_id())
    OnchainSteps.failure_note(reason, assigns.linked, assigns.active, chain_name)
  end

  # Steps

  defp steps(%{review: %{} = review, presses: presses}) do
    Enum.map(review.steps, fn %{step: name} ->
      entry = OnchainSteps.entry(presses, review, name)
      %{name: name, label: step_label(name), state: step_state(entry), entry: entry}
    end)
  end

  defp steps(_assigns), do: []

  # One button at a time: the first step the wallet has not sent from this
  # review yet, or one that did not go through. Before there is a review the
  # button places the bid, and pressing it prepares one. A sent step moves the
  # button on at once; nothing waits for the network before the next press can
  # reach the wallet.
  defp next_step(%{review: %{}} = assigns),
    do: Enum.find(steps(assigns), &(&1.state in [:ready, :reverted, :other]))

  defp next_step(_assigns), do: %{name: "usdg_bid", label: "Place bid"}

  defp step_state(nil), do: :ready

  defp step_state(%{outcome: :pending} = entry),
    do: if(Presses.stalled?(entry), do: :stalled, else: :sent)

  defp step_state(%{outcome: :confirmed}), do: :done
  defp step_state(%{outcome: :reverted}), do: :reverted
  defp step_state(_not_this_step), do: :other

  defp step_label("usdg_approval"), do: "Approve USDG"
  defp step_label(_bid), do: "Place bid"

  # How many times the wallet still asks, counting the step on the button.
  defp signatures_left(_steps, nil), do: 0

  defp signatures_left(steps, %{name: name}),
    do: steps |> Enum.drop_while(&(&1.name != name)) |> length()

  # What is happening to the bid on the page, in a line.
  defp progress_copy(steps) do
    sent = Enum.filter(steps, &(&1.state in [:sent, :stalled, :other]))

    case {List.last(sent), steps} do
      {%{state: :other}, _steps} ->
        "That transaction is not the one this page prepared, so it can't be followed here. Check it in your wallet activity."

      {%{state: :stalled}, _steps} ->
        "Robinhood Chain has not confirmed this yet. Check again, or look in your wallet activity."

      {%{name: "usdg_approval"}, _steps} ->
        "Approving USDG…"

      {%{name: _bid}, _steps} ->
        "Confirming your bid…"

      {nil, [%{state: :done} | _rest] = steps} ->
        if Enum.any?(steps, &(&1.state == :ready)), do: "USDG approved. Now place your bid."

      {nil, _steps} ->
        nil
    end
  end

  defp pending_hash(steps) do
    Enum.find_value(steps, fn
      %{state: state, entry: %{hash: hash}, name: "usdg_bid"} when state in [:sent, :stalled] ->
        hash

      _step ->
        nil
    end)
  end

  defp reverted(steps) do
    case Enum.find(steps, &(&1.state == :reverted)) do
      %{name: name} -> reverted_copy(name)
      nil -> nil
    end
  end

  defp reverted_copy("usdg_approval"), do: "That approval did not go through. Press again."

  defp reverted_copy(_bid),
    do:
      "That bid did not go through on Robinhood Chain, so nothing was bought. Only the network fee was spent. You can send it again."

  # The bidder's own X account, read when they choose to share.
  defp load_x(socket) do
    connections =
      case Autolaunch.Accounts.list_my_x_connections(actor: actor(socket)) do
        {:ok, connections} -> connections
        {:error, _unavailable} -> []
      end

    assign(socket,
      x_connection: BidPlaced.profile_x(connections),
      x_enabled: Autolaunch.Accounts.XOAuth.enabled?()
    )
  end

  # The auction page hands over the book and the token supply it already
  # reads; anywhere else, such as the gallery's bid popup, the panel reads them
  # itself, once.
  defp assign_book_and_supply(
         %{assigns: %{book: %AsyncResult{}, supply: %AsyncResult{}}} = socket
       ),
       do: socket

  defp assign_book_and_supply(%{assigns: %{auction: auction}} = socket) do
    socket
    |> assign_async(:book, fn ->
      with {:ok, book} <- AuctionBook.robinhood(auction), do: {:ok, %{book: book}}
    end)
    |> assign_async(:supply, fn ->
      with {:ok, launch} <- Autolaunch.get_robinhood_auction(auction, actor: nil),
           do: {:ok, %{supply: launch && launch.token_supply}}
    end)
  end

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  # Robinhood's stock prices, read once and apart from the form, so a slow
  # price never holds a bid back.
  defp assign_usd_prices(%{assigns: %{usd_prices: _prices}} = socket), do: socket

  defp assign_usd_prices(socket),
    do:
      UsdValue.assign_rate(socket, :usd_prices, :robinhood, fn ->
        {:ok, %{usd_prices: MarketData.prices(:robinhood)}}
      end)

  defp reading_symbol(%{stock: %{"symbol" => symbol}}), do: symbol
  defp reading_symbol(nil), do: nil

  defp stock_symbol(%{stock: %{"symbol" => symbol}}), do: symbol
  defp stock_symbol(nil), do: "the auction's stock"

  defp bid_state(%{"exited_block" => block, "tokens_filled_now" => filled}, _book, _reading)
       when block != "0" do
    if filled != "0", do: "Bid settled · tokens allocated", else: "Bid settled"
  end

  # Reaching the minimum mid-auction does not make a bid a winner yet.
  defp bid_state(%{"exited_block" => "0", "max_price_q96" => price}, book, %{
         graduated?: true,
         clock: clock,
         window: %{"end_block" => end_block}
       })
       when clock >= end_block and not is_nil(book),
       do:
         price |> String.to_integer() |> AuctionBook.standing(book) |> Book.graduated_bid_status()

  defp bid_state(_bid, _book, %{clock: clock, window: %{"end_block" => end_block}})
       when clock >= end_block, do: "Bidding ended · review your return and token allocation"

  defp bid_state(%{"exited_block" => "0"}, _book, _reading), do: "In the auction"
  defp bid_state(%{"exited_block" => block}, _book, _reading), do: "Exited at block #{block}"

  # Whether the auction's last bidding block has passed, by the chain's own clock.
  defp bidding_over?(%{clock: clock, window: %{"end_block" => end_block}}),
    do: clock >= end_block

  # Each of the wallet's bids with where it stands while bidding is open.
  defp rows(%{reading: %{bids: bids} = reading, book: book, ended: ended}),
    do: Enum.map(bids, &{&1, open_standing(&1, book, reading, ended)})

  defp rows(_assigns), do: []

  # Where a bid still in an open auction stands against the price now, or nil
  # once it has left the auction, bidding has ended or the price is not read.
  defp open_standing(_bid, _book, _reading, ended) when not is_nil(ended), do: nil
  defp open_standing(_bid, %AsyncResult{ok?: false}, _reading, _ended), do: nil

  defp open_standing(
         %{"exited_block" => "0", "max_price_q96" => price},
         %AsyncResult{result: book},
         %{clock: clock, window: %{"end_block" => end_block}},
         _ended
       )
       when clock < end_block,
       do: price |> String.to_integer() |> AuctionBook.standing(book)

  defp open_standing(_bid, _book, _reading, _ended), do: nil

  # The amount box is focused once it shows the new figures: a box already
  # focused keeps what it holds when the page changes around it.
  defp new_bid_entered(socket, form),
    do:
      socket
      |> assign(form: form, new_bid: true, placed: nil, notice: nil)
      |> prepare_when_ready()
      |> push_event("autolaunch:focus", %{to: "#{socket.assigns.id}-amount"})

  defp own_bid(%{reading: %{bids: bids}}, bid_id), do: Enum.find(bids, &(&1["bid_id"] == bid_id))
  defp own_bid(_assigns, _bid_id), do: nil

  # The chain keeps a bid in the auction's stock, not the USDG paid for it, so
  # the same money is the stock's worth in dollars today, USDG being a dollar.
  defp usdg_worth(%{"stock_committed_units" => units}, %Decimal{} = rate),
    do:
      units
      |> Decimal.new(max_digits: :infinity)
      |> Decimal.mult(rate)
      |> Decimal.round(2)
      |> Decimal.to_string(:normal)

  defp usdg_worth(_bid, _rate), do: ""

  # The bid's own most per token, rounded up in its eighteenth decimal place:
  # a review brings a price down to the tick below it, which is the bid's own.
  defp bid_max_price(%{"max_price_q96" => price}, %AsyncResult{
         ok?: true,
         result: %{decimals: decimals}
       }),
       do:
         price
         |> String.to_integer()
         |> BidPrice.decimal(decimals)
         |> Decimal.new(max_digits: :infinity)
         |> Decimal.round(18, :ceiling)
         |> Decimal.to_string(:normal)
         |> String.trim_trailing("0")
         |> String.trim_trailing(".")

  defp bid_max_price(_bid, _book), do: ""

  # The page hears when one of the wallet's bids is outbid, and which, so it
  # can say so at the top. Only a page that asked is told, and only of changes.
  defp told_outbid(%{assigns: %{outbid_banner: true} = assigns} = socket) do
    outbid =
      with %{bids: bids} = reading <- assigns.reading,
           %{"bid_id" => bid_id} <-
             Enum.find(
               bids,
               &(open_standing(&1, assigns.book, reading, assigns.ended) == :outbid)
             ) do
        %{bid: "#{assigns.id}-bid-#{bid_id}", graduated?: reading.graduated?}
      else
        _none -> nil
      end

    if outbid != assigns.told_outbid, do: send(self(), {:robinhood_outbid, outbid})
    assign(socket, :told_outbid, outbid)
  end

  defp told_outbid(socket), do: socket

  defp copy(reason), do: Map.get(@copy, reason, @generic)

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil
end
