defmodule AutolaunchWeb.RobinhoodStockBidComponent do
  @moduledoc """
  The wallet step of a USDG bid on a Robinhood memestock auction: the bid is
  reviewed as the form changes, and one press opens the wallet for at most two
  transactions (the exact USDG allowance when one is needed, then the bid
  itself).

  The wallet Privy has selected drives everything here and its address is proved
  against the mounted lease before anything is read. Nothing is stored: the
  review lives on this page only, the browser reports a hash and stops, and
  every outcome on screen is the server's own read of that hash. A wallet's
  bids are the auction's own records. Once the auction has ended, the page
  passes what that means for bidders and the card keeps only the wallet's
  bids and their settlement.

  While bidding is open, each of the wallet's bids says where it stands. One
  still buying can be added to and an outbid one raised, both through this
  panel's own form (each places a new bid with new money), and an outbid one
  can have its unspent stock back early once the auction has reached its
  minimum. With `outbid_banner`, the page is told whenever a bid is outbid, so
  it can say so at the top.
  """

  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.{AuctionBook, BidPrice}
  alias Autolaunch.Robinhood.{Lab, StockBidActions}
  alias Autolaunch.Stocks.MarketData
  alias AutolaunchWeb.Components.AuctionBook, as: Book
  alias AutolaunchWeb.Components.{BidForm, BidPlaced}
  alias AutolaunchWeb.{TokenDisplay, UsdValue}
  alias Phoenix.LiveView.{AsyncResult, JS}

  @copy %{
    authentication_required: "Sign in to bid from your wallet.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer:
      "Switch back to the wallet you signed in with, or sign out and sign in with this one.",
    invalid_address:
      "Switch back to the wallet you signed in with, or sign out and sign in with this one.",
    chain_unavailable: "Robinhood could not be read just now. Try again in a moment.",
    invalid_chain_response: "Robinhood gave an incomplete answer. Try again in a moment.",
    invalid_block_header: "Robinhood gave an incomplete answer. Try again in a moment.",
    lab_config_changed: "Robinhood changed while this was prepared. Try again.",
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
    stock_not_listed: "This auction's stock is not one this site lists.",
    envelope_invalid: "This review is out of date. Review the bid again.",
    invalid_hash: "That transaction could not be read. Check your wallet activity."
  }

  @generic "That did not go through. Try again in a moment."
  @unheld [:wrong_signer, :session_unavailable, :session_lease_required, :invalid_address]
  @steps %{"usdg_approval" => :usdg_approval, "usdg_bid" => :usdg_bid}
  # An unsent review is reviewed again well inside its fifteen-minute deadline.
  @refresh_ms 8 * 60_000

  @impl true
  def update(%{refresh_bids: true}, socket), do: {:ok, socket |> with_reading() |> told_outbid()}

  # A bid's early return says whether the auction would pay it back now.
  def update(%{early_return: {bid_id, state}}, socket),
    do:
      {:ok, assign(socket, :early_returns, Map.put(socket.assigns.early_returns, bid_id, state))}

  # A review holds its quote for fifteen minutes; an unsent one is reviewed again first.
  def update(
        %{refresh_review: key},
        %{assigns: %{prepared_for: key, sent: sent, with_wallet: nil}} = socket
      )
      when sent == %{},
      do: {:ok, socket |> assign(prepared_for: nil) |> prepare_when_ready()}

  def update(%{refresh_review: _key}, socket), do: {:ok, socket}

  # A sent step is read again every few seconds until the chain answers.
  # Reading never sends anything and never opens the wallet.
  def update(%{follow: {name, hash}}, socket) do
    socket = assign(socket, following: nil)

    case socket.assigns.sent[name] do
      %{hash: ^hash, outcome: :pending} ->
        %{review: %{envelope: envelope}} = socket.assigns
        opts = opts(socket)

        {:ok,
         start_async(socket, :follow, fn ->
           {name, hash, StockBidActions.verify(envelope, Map.fetch!(@steps, name), hash, opts)}
         end)}

      _other ->
        {:ok, socket}
    end
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:ended, fn -> nil end)
     |> assign_new(:stake_path, fn -> nil end)
     |> assign_book_and_supply()
     |> assign_new(:wallet, fn -> nil end)
     |> assign_new(:notice, fn -> nil end)
     |> assign_new(:review, fn -> nil end)
     |> assign_new(:prepared_for, fn -> nil end)
     |> assign_new(:preparing, fn -> nil end)
     |> assign_new(:owed, fn -> %{} end)
     |> assign_new(:with_wallet, fn -> nil end)
     |> assign_new(:following, fn -> nil end)
     |> assign_new(:sharing, fn -> false end)
     |> assign_new(:share_message, fn -> "" end)
     |> assign_new(:x_connection, fn -> nil end)
     |> assign_new(:x_enabled, fn -> false end)
     |> assign_new(:sent, fn -> %{} end)
     |> assign_new(:reading, fn -> nil end)
     |> assign_new(:early_returns, fn -> %{} end)
     |> assign_new(:new_bid, fn -> false end)
     |> assign_new(:outbid_banner, fn -> false end)
     |> assign_new(:told_outbid, fn -> nil end)
     |> assign_new(:form, fn ->
       %{BidForm.blank() | amount: Map.get(assigns, :preset_amount) || ""}
     end)
     |> assign_usd_prices()
     |> prepare_when_ready()
     |> told_outbid()}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        usd_rate: UsdValue.stock_rate(assigns.usd_prices.result, reading_symbol(assigns.reading)),
        rows: rows(assigns)
      )

    ~H"""
    <section
      id={@id}
      class="bid-panel rg-panel rg-panel--surface"
      phx-hook="AutolaunchReviewedSteps"
      data-reports-opening
      data-press-form={"#{@id}-form"}
      phx-target={@myself}
    >
      <header class="bid-heading">
        <Regent.Structure.section_bar>
          <h2 class="rg-section-bar__label">
            {if @ended, do: "Bidding has ended", else: "Place a bid"}
          </h2>
        </Regent.Structure.section_bar>
        <p :if={@ended}>{@ended}</p>
        <p :if={!@ended}>
          Bid with USDG. It is converted into the auction's stock inside the bid, and any unspent part comes straight back. Your wallet confirms every step.
        </p>
      </header>

      <p
        :if={@notice}
        class="launch-wallet-notice"
        role={if @notice.tone == :error, do: "alert", else: "status"}
      >
        {@notice.message}
      </p>

      <p :if={!@authenticated} class="bid-empty">
        <Regent.Primitives.button type="button" data-account-target="sign-in">
          {if @ended, do: "Sign in to see your bids", else: "Sign in to bid"}
        </Regent.Primitives.button>
      </p>

      <div :if={@authenticated && !@wallet} class="bid-empty">
        <p>
          {if @ended,
            do: "Choose the wallet you bid from.",
            else: "Choose the wallet you want to bid from."}
        </p>
        <Regent.Primitives.button type="button" data-wallet-connect>
          Connect or switch wallet
        </Regent.Primitives.button>
      </div>

      <div :if={@authenticated && @wallet} class="bid-body">
        <dl class="bid-wallet">
          <div>
            <dt>Wallet</dt>
            <dd class="bid-mono">{short(@wallet)}</dd>
          </div>
          <div :if={@reading}>
            <dt>Auction currency</dt>
            <dd>{@reading.stock["symbol"]}</dd>
          </div>
          <div :if={@reading}>
            <dt>Bidding</dt>
            <dd>{window_copy(@reading)}</dd>
          </div>
        </dl>

        <p :if={@ended && @reading && @reading.bids == []} class="bid-empty">
          This wallet placed no bids on this auction.
        </p>

        <p :if={@new_bid && !@ended && @sent == %{}} class="bid-form__note">
          This places a new bid with new money. Your first bid stays as it is.
        </p>
        <BidForm.bid_form
          :if={!@ended && @sent == %{}}
          id={@id}
          target={@myself}
          form={@form}
          amount_unit="USDG"
          price_unit={stock_symbol(@reading)}
          book={@book}
          supply={supply(@supply)}
          rate={@usd_rate}
        >
          <:action>
            <.ready :if={ready?(assigns)} review={@review} rate={@usd_rate} />
            <div :if={!ready?(assigns)} class="bid-form__pending">
              <p :if={@preparing} class="bid-form__note" role="status">Getting your bid ready…</p>
              <Regent.Primitives.button class="bid-primary" type="button" disabled>
                Place bid
              </Regent.Primitives.button>
            </div>
          </:action>
        </BidForm.bid_form>

        <section
          :if={@review && placed?(@sent)}
          id={"#{@id}-placed"}
          class="bid-progress"
          aria-label="Bid placed"
        >
          <BidPlaced.bid_placed
            id={"#{@id}-placed"}
            target={@myself}
            token_symbol={@token_symbol}
            chain={:robinhood}
            hash={@sent["usdg_bid"].hash}
            test_chain={Lab.test_chain?(@review.envelope["chain_id"])}
            auction_path={~p"/robinhood/auctions/#{@auction}"}
            sharing={@sharing}
            message={@share_message}
            x_connection={@x_connection}
            x_enabled={@x_enabled}
          />
          <Regent.Primitives.button
            type="button"
            phx-click="clear_review"
            phx-target={@myself}
            variant="secondary"
          >
            Place another bid
          </Regent.Primitives.button>
        </section>

        <section
          :if={@review && @sent != %{} && !placed?(@sent)}
          id={"#{@id}-progress"}
          class="bid-progress"
          aria-label="Your bid"
        >
          <.summary review={@review} />
          <p class="bid-progress__status" role="status" aria-live="polite">
            {progress_copy(current_step(assigns), @sent, @with_wallet)}
          </p>
          <a
            :if={pending_hash(@sent) && !Lab.test_chain?(@review.envelope["chain_id"])}
            href={BidPlaced.transaction_url(:robinhood, pending_hash(@sent))}
            target="_blank"
            rel="noopener noreferrer"
          >
            View on Blockscout ↗
          </a>
          <p :if={slow?(@sent)} class="bid-form__note">
            This is taking longer than usual. It can still go through, and there is nothing you need to do.
          </p>
          <Regent.Primitives.button
            class="bid-primary"
            type="button"
            data-reviewed-step={current_step(assigns)}
            variant={if pending_hash(@sent), do: "secondary", else: "primary"}
          >
            {press_label(current_step(assigns))}
          </Regent.Primitives.button>
          <Regent.Primitives.button
            :if={!pending_hash(@sent)}
            type="button"
            phx-click="clear_review"
            phx-target={@myself}
            variant="secondary"
          >
            Change bid
          </Regent.Primitives.button>
        </section>

        <section
          :if={@reading && @reading.bids != []}
          class="launch-wallet-settled"
          aria-label="Your bids"
        >
          <h3>Your bids on this auction</h3>
          <ul role="list">
            <li :for={{bid, standing} <- @rows} id={"#{@id}-bid-#{bid["bid_id"]}"}>
              <p>
                Bid #{bid["bid_id"]} · {bid["stock_committed_units"]} {@reading.stock["symbol"]}
                <UsdValue.usd amount={bid["stock_committed_units"]} rate={@usd_rate} />
                <span :if={standing in [:in, :sharing]}>· {Book.standing_label(standing)}</span>
                <span :if={is_nil(standing)}>
                  · {bid_state(bid, (@book.ok? && @book.result) || nil, @reading)}
                </span>
              </p>
              <Book.outbid_status
                :if={standing == :outbid}
                price={@book.result.clearing}
                unit={@reading.stock["symbol"]}
                back={back(@reading, @early_returns[bid["bid_id"]])}
              />
              <.live_component
                :if={standing == :outbid && @reading.graduated?}
                module={AutolaunchWeb.RobinhoodStockBidSettlementComponent}
                id={"#{@id}-early-#{bid["bid_id"]}"}
                parent_id={@id}
                early
                recheck={@book.result.block}
                auction={@auction}
                bid={bid}
                graduated?={@reading.graduated?}
                token_symbol={@token_symbol}
                usd_rate={@usd_rate}
                wallet={@wallet}
                current_human_id={@current_human_id}
                session_lease={@session_lease}
              />
              <Regent.Primitives.button
                :if={standing == :outbid && @sent == %{}}
                type="button"
                phx-click={
                  JS.push("raise_bid", value: %{bid_id: bid["bid_id"]}, target: @myself)
                  |> JS.focus(to: "##{@id}-amount")
                }
                variant="secondary"
              >
                Raise my bid to keep buying
              </Regent.Primitives.button>
              <Regent.Primitives.button
                :if={standing in [:in, :sharing] && @sent == %{}}
                type="button"
                phx-click={
                  JS.push("add_to_bid", value: %{bid_id: bid["bid_id"]}, target: @myself)
                  |> JS.focus(to: "##{@id}-amount")
                }
                variant="secondary"
              >
                Add to this bid
              </Regent.Primitives.button>
              <.live_component
                :if={is_nil(standing)}
                module={AutolaunchWeb.RobinhoodStockBidSettlementComponent}
                id={"#{@id}-settle-#{bid["bid_id"]}"}
                parent_id={@id}
                auction={@auction}
                bid={bid}
                graduated?={@reading.graduated?}
                stake_path={@stake_path}
                token_symbol={@token_symbol}
                usd_rate={@usd_rate}
                wallet={@wallet}
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

  @impl true
  def handle_event("active_wallet", %{"address" => address}, socket),
    do: {:noreply, socket |> adopt(address) |> prepare_when_ready()}

  def handle_event("bid_form_changed", params, socket) do
    {:noreply,
     socket
     |> assign(form: BidForm.values(params, socket.assigns.form), notice: nil)
     |> prepare_when_ready()}
  end

  # The price to beat, entered from the auction's price panel as the limit.
  def handle_event("use_price", %{"price" => price}, socket) do
    form = %{socket.assigns.form | at_price: false, limit_mode: "price", limit: price}
    {:noreply, socket |> assign(form: form, notice: nil) |> prepare_when_ready()}
  end

  # A step is with the wallet: its review stays as it is until the wallet
  # answers, so the hash is read against the review that was sent.
  def handle_event("step_opening", %{"step" => name}, socket) when is_map_key(@steps, name),
    do: {:noreply, assign(socket, with_wallet: name)}

  def handle_event("step_sent", %{"step" => name, "transaction_hash" => hash}, socket)
      when is_map_key(@steps, name) and is_binary(hash),
      do: {:noreply, socket |> assign(with_wallet: nil) |> checked(name, hash)}

  def handle_event("step_failed", %{"reason" => reason}, socket) do
    {:noreply,
     socket
     |> assign(with_wallet: nil, notice: %{tone: :error, message: wallet_failure_copy(reason)})
     |> prepare_when_ready()}
  end

  # A press made while the form on screen differs from the review the browser
  # holds. The bid is built for exactly the values pressed and goes straight to
  # the wallet; a review already built or being built for them is used as it is.
  def handle_event("prepare_and_send", %{"form" => params}, socket) do
    socket = assign(socket, form: BidForm.values(params, socket.assigns.form), notice: nil)
    {:noreply, pressed(socket, bid_key(socket.assigns))}
  end

  # A new bid for an outbid one: about the same money, at the current price.
  def handle_event("raise_bid", %{"bid_id" => bid_id}, socket) do
    %{usd_prices: prices, reading: reading} = socket.assigns
    rate = UsdValue.stock_rate(prices.result, reading_symbol(reading))
    amount = socket.assigns |> own_bid(bid_id) |> usdg_worth(rate)
    form = %{BidForm.blank() | amount: amount}
    {:noreply, socket |> assign(form: form, new_bid: true, notice: nil) |> prepare_when_ready()}
  end

  # A new bid beside one still buying, up to the same most per token.
  def handle_event("add_to_bid", %{"bid_id" => bid_id}, socket) do
    limit = socket.assigns |> own_bid(bid_id) |> max_price(socket.assigns.book)
    form = %{BidForm.blank() | at_price: false, limit_mode: "price", limit: limit}
    {:noreply, socket |> assign(form: form, new_bid: true, notice: nil) |> prepare_when_ready()}
  end

  # "Change bid" keeps the entered amounts to adjust; a placed bid starts a fresh form.
  def handle_event("clear_review", _params, socket) do
    {:noreply,
     socket
     |> assign(
       if placed?(socket.assigns.sent), do: [form: BidForm.blank(), new_bid: false], else: []
     )
     |> assign(review: nil, prepared_for: nil, sent: %{}, notice: nil, sharing: false)
     |> push_event("reviewed-steps:cleared", %{component_id: socket.assigns.id})
     |> prepare_when_ready()}
  end

  def handle_event("share_bid", _params, socket) do
    url = url(~p"/robinhood/auctions/#{socket.assigns.auction}")
    message = BidPlaced.message(socket.assigns.token_symbol, url)
    {:noreply, socket |> assign(sharing: true, share_message: message) |> load_x()}
  end

  def handle_event("share_message_changed", %{"message" => message}, socket),
    do: {:noreply, assign(socket, share_message: message)}

  def handle_event("refresh_x_connections", _params, socket), do: {:noreply, load_x(socket)}

  def handle_event(_other, _params, socket), do: {:noreply, socket}

  # Each set of values is prepared as its own task, so a review owed to a press
  # is never dropped for a later one.
  @impl true
  def handle_async({:prepare, key}, {:ok, {inputs, result}}, socket) do
    {presses, owed} = Map.pop(socket.assigns.owed, key, 0)
    socket = socket |> assign(owed: owed) |> prepared(key)

    cond do
      presses > 0 -> {:noreply, reviewed(socket, key, inputs, result, presses)}
      socket.assigns.with_wallet || socket.assigns.sent != %{} -> {:noreply, socket}
      key != bid_key(socket.assigns) -> {:noreply, prepare_when_ready(socket)}
      true -> {:noreply, reviewed(socket, key, inputs, result, 0)}
    end
  end

  def handle_async({:prepare, key}, {:exit, _reason}, socket) do
    {_presses, owed} = Map.pop(socket.assigns.owed, key, 0)

    {:noreply,
     socket |> assign(owed: owed, notice: notice(:error, :unavailable)) |> prepared(key)}
  end

  def handle_async(:follow, {:ok, {name, hash, result}}, socket),
    do: {:noreply, recorded(socket, name, hash, result)}

  def handle_async(:follow, {:exit, _reason}, socket), do: {:noreply, follow(socket)}

  # A review answering presses goes to the wallet once for each of them, and is
  # held as the one with the wallet so no background review replaces it.
  defp reviewed(socket, key, inputs, {:ok, review}, presses) do
    send_update_after(
      self(),
      __MODULE__,
      [id: socket.assigns.id, refresh_review: key],
      @refresh_ms
    )

    socket
    |> assign(review: review, prepared_for: key, inputs: inputs, notice: nil)
    |> assign(if presses > 0, do: [with_wallet: first_step(review)], else: [])
    |> published(presses)
  end

  defp reviewed(socket, key, _inputs, {:error, error}, _presses),
    do:
      assign(socket,
        review: nil,
        prepared_for: {:refused, key},
        notice: notice(:error, refusal(error))
      )

  # The bid is reviewed in the background whenever what it would send changes:
  # the wallet, the total or the most per token (which moves with the price to
  # beat). Nothing is reviewed again while a step is with the wallet or once
  # one has been sent.
  defp prepare_when_ready(%{assigns: assigns} = socket) do
    key = bid_key(assigns)

    cond do
      assigns.ended || assigns.with_wallet || assigns.sent != %{} -> socket
      is_nil(key) -> socket
      assigns.preparing == key -> socket
      assigns.prepared_for in [key, {:refused, key}] -> socket
      true -> start_prepare(socket, key)
    end
  end

  defp start_prepare(socket, {wallet, amount, max_price} = key) do
    request = %{auction: socket.assigns.auction, usdg_amount: amount, max_price: max_price}
    %{form: inputs} = socket.assigns
    opts = opts(socket)

    socket
    |> assign(preparing: key)
    |> start_async({:prepare, key}, fn ->
      {inputs, StockBidActions.prepare(request, wallet, opts)}
    end)
  end

  defp prepared(%{assigns: %{preparing: key}} = socket, key), do: assign(socket, preparing: nil)
  defp prepared(socket, _key), do: socket

  # A press is answered by the review for its values: the one already built,
  # the one being built, or a new one.
  defp pressed(socket, nil), do: assign(socket, notice: notice(:error, incomplete(socket)))

  defp pressed(%{assigns: %{review: review, prepared_for: key}} = socket, key)
       when is_map(review),
       do: socket |> assign(with_wallet: first_step(review)) |> published(1)

  defp pressed(%{assigns: %{preparing: key}} = socket, key), do: owe(socket, key)
  defp pressed(socket, key), do: socket |> start_prepare(key) |> owe(key)

  defp owe(socket, key),
    do: assign(socket, owed: Map.update(socket.assigns.owed, key, 1, &(&1 + 1)))

  defp incomplete(%{assigns: %{form: %{amount: ""}}}), do: :amount_required
  defp incomplete(_socket), do: :max_price_required

  defp first_step(%{steps: [%{"step" => step} | _rest]}), do: step

  defp bid_key(%{wallet: wallet, form: form} = assigns) when is_binary(wallet) do
    with amount when amount != "" <- form.amount,
         max_price when is_binary(max_price) <-
           BidForm.max_price(form, assigns.book, supply(assigns.supply)),
         do: {wallet, amount, max_price},
         else: (_incomplete -> nil)
  end

  defp bid_key(_assigns), do: nil

  defp ready?(%{review: review} = assigns) when is_map(review),
    do: assigns.prepared_for == bid_key(assigns)

  defp ready?(_assigns), do: false

  defp supply(%AsyncResult{ok?: true, result: supply}), do: supply
  defp supply(_loading), do: nil

  attr :review, :map, required: true
  attr :rate, :any, required: true

  # The reviewed bid in three lines, over the one button that opens the wallet.
  defp ready(assigns) do
    assigns = assign(assigns, :first, assigns.review.steps |> hd() |> Map.fetch!("step"))

    ~H"""
    <.summary review={@review} />
    <p :if={@first == "usdg_approval"} class="bid-form__note">
      Your wallet asks twice: first to let the auction use your USDG, last to place the bid.
    </p>
    <Regent.Primitives.button class="bid-primary" type="button" data-reviewed-step={@first}>
      {press_label(@first)}
    </Regent.Primitives.button>
    """
  end

  attr :review, :map, required: true

  # The bid in three lines: what it spends, the most it pays, and where.
  defp summary(assigns) do
    ~H"""
    <dl class="bid-form__summary" aria-label="Your bid">
      <div>
        <dt>Total bid</dt>
        <dd>{argument(@review, "usdg_amount")} USDG</dd>
      </div>
      <div>
        <dt>Most per token</dt>
        <dd>
          <TokenDisplay.price
            amount={argument(@review, "max_price_executable")}
            unit={argument(@review, "stock_symbol")}
          />
        </dd>
      </div>
      <div>
        <dt>Network</dt>
        <dd>{Lab.network_name(@review.envelope["chain_id"])}</dd>
      </div>
    </dl>
    <p class="bid-form__note">
      Your USDG buys at least {argument(@review, "min_stock_out_units")} {argument(
        @review,
        "stock_symbol"
      )}, 1% below today's quote, or the bid is not placed.
    </p>
    """
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

  # The server reads the reported hash itself; the browser's word is only the hash.
  defp checked(%{assigns: %{review: %{envelope: envelope}}} = socket, name, hash) do
    result = StockBidActions.verify(envelope, Map.fetch!(@steps, name), hash, opts(socket))
    recorded(socket, name, hash, result)
  end

  defp checked(socket, _name, _hash), do: socket

  # The first time a hash is seen is kept, so a slow confirmation can say so.
  defp recorded(socket, name, hash, {:ok, %{outcome: outcome}}) do
    since =
      case socket.assigns.sent[name] do
        %{hash: ^hash, since: since} -> since
        _other -> DateTime.utc_now()
      end

    socket
    |> assign(
      sent: Map.put(socket.assigns.sent, name, %{hash: hash, outcome: outcome, since: since}),
      notice: nil
    )
    |> listed(outcome)
    |> follow()
  end

  defp recorded(socket, _name, _hash, {:error, error}),
    do: socket |> assign(notice: notice(:error, refusal(error))) |> follow()

  @follow_ms 3_000
  @slow_seconds 60

  defp follow(%{assigns: %{following: nil, sent: sent}} = socket) do
    case Enum.find(sent, &match?({_name, %{outcome: :pending}}, &1)) do
      {name, %{hash: hash}} ->
        send_update_after(
          self(),
          __MODULE__,
          [id: socket.assigns.id, follow: {name, hash}],
          @follow_ms
        )

        assign(socket, following: hash)

      nil ->
        socket
    end
  end

  defp follow(socket), do: socket

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

  defp current_step(%{review: %{steps: steps}, sent: sent}), do: next_step(steps, sent)

  defp press_label("usdg_approval"), do: "Approve USDG"
  defp press_label("usdg_bid"), do: "Place bid"

  # What is happening to the step the bid is on, in a line.
  defp progress_copy(step, _sent, step), do: in_wallet_copy(step)

  defp progress_copy(step, sent, _with_wallet) do
    case sent[step] do
      %{outcome: :pending} when step == "usdg_approval" ->
        "Approving USDG…"

      %{outcome: :pending} ->
        "Confirming your bid…"

      %{outcome: :reverted} ->
        "That transaction was reverted on Robinhood Chain, so nothing was bought. Only the network fee was spent. You can send it again."

      %{outcome: :unverified} ->
        "That transaction did not match this bid, so it was not counted. Check your wallet's activity."

      nil ->
        "USDG approved. Now place your bid."
    end
  end

  defp in_wallet_copy("usdg_approval"), do: "Approve USDG in your wallet."
  defp in_wallet_copy("usdg_bid"), do: "Confirm your bid in your wallet."

  defp pending_hash(sent),
    do: Enum.find_value(sent, fn {_name, entry} -> entry.outcome == :pending && entry.hash end)

  defp slow?(sent) do
    Enum.any?(sent, fn {_name, entry} ->
      entry.outcome == :pending and
        DateTime.diff(DateTime.utc_now(), entry.since) > @slow_seconds
    end)
  end

  defp listed(socket, :confirmed), do: with_reading(socket)
  defp listed(socket, _outcome), do: socket

  # The review as the browser holds it, with the form values it was built for.
  # Answering presses, it is handed over once per press, each naming the step
  # that press sends.
  defp published(
         %{assigns: %{review: %{envelope: envelope, steps: steps} = review}} = socket,
         presses
       ) do
    payload = %{
      component_id: socket.assigns.id,
      signer: envelope["expected_signer"],
      chain_id: envelope["chain_id"],
      lab: envelope["metadata"]["lab"],
      lab_anchor: %{
        block_number: envelope["arguments"]["block_number"],
        block_hash: envelope["arguments"]["block_hash"]
      },
      steps: Enum.map(steps, &Map.take(&1, ["step", "to", "data"])),
      inputs: socket.assigns.inputs
    }

    if presses == 0,
      do: push_event(socket, "reviewed-steps:review", payload),
      else:
        Enum.reduce(1..presses, socket, fn _press, socket ->
          push_event(socket, "reviewed-steps:review", Map.put(payload, :send, first_step(review)))
        end)
  end

  # A visitor who is not signed in is asked to sign in, not read for.
  defp adopt(%{assigns: %{authenticated: false}} = socket, _address), do: socket

  defp adopt(socket, nil), do: assign(socket, wallet: nil, notice: nil)

  defp adopt(%{assigns: %{wallet: wallet}} = socket, wallet), do: socket

  defp adopt(socket, address) do
    case StockBidActions.bids(socket.assigns.auction, address, opts(socket)) do
      {:ok, reading} ->
        socket
        |> assign(wallet: String.downcase(address), reading: reading, notice: nil)
        |> reviewed_for_wallet()

      {:error, error} ->
        refused(socket, address, refusal(error))
    end
  end

  # A review belongs to the wallet it was prepared for; another wallet starts clean.
  defp reviewed_for_wallet(%{assigns: %{review: %{envelope: envelope}, wallet: wallet}} = socket) do
    if String.downcase(envelope["expected_signer"]) == wallet,
      do: socket,
      else:
        socket
        |> assign(review: nil, prepared_for: nil, sent: %{})
        |> push_event("reviewed-steps:cleared", %{component_id: socket.assigns.id})
  end

  defp reviewed_for_wallet(socket), do: socket

  defp with_reading(socket) do
    case StockBidActions.bids(socket.assigns.auction, socket.assigns.wallet, opts(socket)) do
      {:ok, reading} -> assign(socket, reading: reading)
      {:error, _unavailable} -> socket
    end
  end

  # Any wallet but the signed-in one is not adopted at all; the signed-in one
  # stays on screen with the reason.
  defp refused(socket, _address, reason) when reason in @unheld do
    assign(socket,
      wallet: nil,
      review: nil,
      sent: %{},
      reading: nil,
      notice: notice(:error, reason)
    )
  end

  defp refused(socket, address, reason) do
    assign(socket,
      wallet: String.downcase(address),
      reading: nil,
      notice: notice(:info, reason)
    )
  end

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  defp placed?(sent), do: match?(%{outcome: :confirmed}, sent["usdg_bid"])

  defp next_step(steps, sent) do
    Enum.find_value(steps, fn %{"step" => name} ->
      if match?(%{outcome: :confirmed}, sent[name]), do: nil, else: name
    end)
  end

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

  defp window_copy(%{clock: now, window: %{"start_block" => start_block}})
       when now < start_block,
       do: "Opens at block #{start_block}. Robinhood is at block #{now}."

  defp window_copy(%{clock: now, window: %{"end_block" => end_block}})
       when now < end_block,
       do: "Open until block #{end_block}. Robinhood is at block #{now}."

  defp window_copy(_reading), do: "Ended."

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

  # The rest comes back early only once the auction has reached its minimum,
  # and only once it has recorded a price above the bid.
  defp back(%{graduated?: true}, :waiting), do: :price_recorded
  defp back(%{graduated?: true}, _offered_or_unknown), do: :now
  defp back(_reading, _early_return), do: :after_end

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
  defp max_price(%{"max_price_q96" => price}, %AsyncResult{
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

  defp max_price(_bid, _book), do: ""

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

  defp wallet_failure_copy("wallet_unavailable"),
    do: "Open the wallet you signed in with, then try again. Nothing was sent."

  defp wallet_failure_copy("network_mismatch"),
    do:
      "Your wallet is connected to a different network under the reviewed chain number. Check the network settings in your wallet, then try again. Nothing was sent."

  defp wallet_failure_copy("wallet_declined"), do: "Your wallet declined this. Nothing was sent."

  defp wallet_failure_copy("send_unconfirmed"),
    do: "Your wallet may have sent this transaction. Check your wallet activity."

  defp wallet_failure_copy(_unknown), do: @generic

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
end
