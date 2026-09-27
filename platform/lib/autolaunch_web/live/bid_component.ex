defmodule AutolaunchWeb.BidComponent do
  @moduledoc """
  The whole bidder: one compact form, the bid it prepares as it changes, and
  the transactions it needs, followed until Base confirms them.

  The wallet that acts is Privy's active wallet when the signed-in account
  links it (`AutolaunchWeb.OnchainSteps`); the balance is that wallet's, or the
  signed-in wallet's until Privy reports one, and a note names both while the
  wallet app has another one open.

  With `agent_tools`, the panel also answers the page tool that bids
  (`AutolaunchWeb.AgentPress`): the call is pressed exactly as the button would be.

  Nothing is stored while a bid is on its way. The review lives on this page
  only, the browser reports a hash and stops, and every outcome on screen is
  the server's own read of that hash against the review it was sent from. A
  bid read from its receipt is recorded as its bidder's position.
  """

  use AutolaunchWeb, :live_component

  import AutolaunchWeb.Components.TokenLinks, only: [regent_market_links: 1]

  alias Autolaunch.Actors.Human
  alias Autolaunch.{AuctionBook, BidActions, Lab, LabProjection}
  alias Autolaunch.Chain.Client
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias AutolaunchWeb.{AgentPress, OnchainSteps, Paths, ShareCard, TokenDisplay, UsdValue}
  alias AutolaunchWeb.Components.{BidForm, BidPlaced, SwapForm}
  alias Phoenix.LiveView.AsyncResult
  alias RegentChain.{Presses, Review}

  @copy %{
    authentication_required: "Sign in to bid from your wallet.",
    bid_preparation_unavailable: "Bidding is not open on this auction yet.",
    chain_unavailable: "Base could not be read just now. Try again in a moment.",
    wrong_signer: "Switch to a wallet on your account in your wallet app, then press again.",
    invalid_address: "Connect your wallet, then press again.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    auction_currency_changed:
      "This auction's currency does not match its record. Bidding is paused here.",
    treasury_report_missing: "Bidding is not open on this auction yet.",
    treasury_security_changed: "Bidding is paused on this auction while its treasury is checked.",
    amount_above_balance: "That is more than this wallet holds.",
    amount_required: "Enter an amount above zero.",
    invalid_amount: "Enter an amount with no more decimal places than the currency allows.",
    invalid_price: "Enter a maximum price above zero.",
    stock_not_admitted: "This stock token is not admitted for USDC bids right now.",
    usdc_bids_unavailable: "USDC bids are not available on this auction.",
    usdc_route_unavailable:
      "The USDC route did not return a usable estimate. Try a different amount.",
    price_below_admissible_tick:
      "Your maximum does not reach an allowed tick above the auction clearing price.",
    invalid_decimal: "Enter a maximum price above zero."
  }

  @generic "That did not go through. Try again in a moment."

  # A balance read that fails for one of these says why, beside the form.
  @told [:bid_preparation_unavailable, :auction_currency_changed]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> OnchainSteps.init()
     |> assign(
       wallet: nil,
       signer: nil,
       mismatch: nil,
       balance: nil,
       prepared: nil,
       prepared_for: nil,
       preparing: nil,
       reviews: %{},
       notice: nil,
       placed: nil,
       x_connection: nil,
       x_enabled: false
     )}
  end

  # A review lives on the page until something it depends on changes. One that
  # has sent nothing is prepared again every few minutes, so its allowance
  # window and tick hint stay current.
  @impl true
  def update(%{refresh_review: review_id}, socket) do
    case socket.assigns.review do
      %{id: ^review_id} = review ->
        if started?(socket.assigns.presses, review),
          do: {:ok, socket},
          else: {:ok, socket |> assign(prepared_for: nil) |> prepare_when_ready()}

      _other ->
        {:ok, socket}
    end
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:heading, fn -> "Place a bid" end)
     |> assign_new(:agent_tools, fn -> false end)
     |> assign_new(:authenticated, fn -> false end)
     |> assign_new(:current_human_id, fn -> nil end)
     |> assign_new(:session_lease, fn -> nil end)
     |> assign(:usdc_bids?, usdc_bids?(assigns[:auction] || socket.assigns[:auction]))
     |> assign_new(:form, fn %{auction: auction} ->
       %{BidForm.blank() | pay_with: bid_currency(auction)}
     end)
     |> assign_book()
     |> assign_usd_rate()
     |> preset()
     |> OnchainSteps.adopt()
     |> followed()
     |> prepare_when_ready()}
  end

  # The panel follows the wallet that may act. A review is built for one
  # signer, so another one withdraws it; the balance is that signer's, or the
  # signed-in wallet's while no wallet on the account is active.
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
      else: socket |> assign(wallet: wallet, balance: nil) |> read_balance()
  end

  defp reviewed_for_signer(%{assigns: %{review: %{signer: signer}}} = socket, signer), do: socket
  defp reviewed_for_signer(%{assigns: %{review: nil}} = socket, _signer), do: socket
  defp reviewed_for_signer(socket, _signer), do: withdrawn(socket)

  defp withdrawn(socket),
    do: socket |> assign(prepared: nil, prepared_for: nil) |> put_review(nil, nil)

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        rate: assigns.usd_rate.result,
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
      <BidForm.title id={@id} title={@heading}>
        <:help>
          <p>
            Bid <span :if={@usdc_bids?}><span class="ticker">USDC</span> or</span>
            <span class="ticker">{@auction.quote_token_symbol}</span> for this launch.
            Your max budget is the most you'll spend. Your max FDV is the most the whole token
            supply may be worth while your bid keeps buying.
          </p>
          <p>Your wallet confirms every step.</p>
        </:help>
      </BidForm.title>
      <.regent_market_links :if={@auction.kind == :agent} />

      <p :if={!@authenticated} class="bid-empty">
        <Regent.Primitives.button type="button" data-account-target="sign-in">Sign in to bid</Regent.Primitives.button>
      </p>

      <div :if={@authenticated && @wallet} class="bid-body">
        <section :if={@placed} id={"#{@id}-placed"} class="bid-progress" aria-label="Bid placed">
          <BidPlaced.bid_placed
            id={"#{@id}-placed"}
            target={@myself}
            token_symbol={@auction.token_symbol}
            chain={:base}
            hash={@placed.hash}
            test_chain={Lab.test_chain?(@placed.chain_id)}
            auction_path={Paths.auction(@auction)}
            auction_url={Paths.auction_url(@auction)}
            share_image={ShareCard.auction_image_url(@auction, DateTime.utc_now())}
            x_connection={@x_connection}
            x_enabled={@x_enabled}
          />
          <Regent.Primitives.button
            type="button"
            phx-click="clear_bid"
            phx-target={@myself}
            variant="secondary"
          >
            Place another bid
          </Regent.Primitives.button>
        </section>

        <BidForm.bid_form
          :if={!@placed}
          id={@id}
          target={@myself}
          form={@form}
          amount_unit={@form.pay_with}
          pay_with={pay_with(@auction, @usdc_bids?)}
          price_unit={@auction.quote_token_symbol}
          token_symbol={@auction.token_symbol}
          book={@book}
          supply={@auction.token_supply}
          rate={@rate}
          balance={@form.pay_with == @auction.quote_token_symbol && balance(@balance, @auction)}
        >
          <:action>
            <p class="bid-form__note" role="status" hidden={@balance != :unread}>
              Your balance can't be read right now.
            </p>
            <p class="bid-notice" role="alert" hidden={!@notice}>{@notice}</p>
            <.summary prepared={@prepared} rate={@rate} chain_name={@review && @review.chain.name} />
            <p class="bid-form__note" hidden={signatures_left(@steps, @next_step) < 2}>
              Your wallet asks {times(signatures_left(@steps, @next_step))}: first to let the auction use your <span class="ticker">{approval_currency(@prepared)}</span>, last to place the bid.
            </p>
            <p
              class="bid-progress__status"
              role="status"
              aria-live="polite"
              hidden={!progress_copy(@steps, @prepared)}
            >
              <TokenDisplay.marked
                text={progress_copy(@steps, @prepared) || ""}
                tickers={tickers(@prepared)}
              />
            </p>
            <a
              href={pending_hash(@steps) && BidPlaced.transaction_url(:base, pending_hash(@steps))}
              target="_blank"
              rel="noopener noreferrer"
              hidden={!pending_hash(@steps) || Lab.test_chain?(@review && @review.chain.chain_id)}
            >
              View on Basescan ↗
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
          </:action>
        </BidForm.bid_form>
      </div>
    </section>
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

    with true <- socket.assigns.authenticated || {:error, :authentication_required},
         {:ok, pay_with} <- agent_pay_with(input["pay_with"], socket.assigns) do
      form = %{
        BidForm.at_price(socket.assigns.form, input["max_price"])
        | amount: input["amount"] || "",
          pay_with: pay_with
      }

      socket |> assign(form: form, notice: nil, placed: nil) |> agent_bid()
    else
      {:error, reason} -> {:reply, AgentPress.refused(copy(reason)), socket}
    end
  end

  def handle_event("fill_bid_amount", _params, socket) do
    case balance(socket.assigns.balance, socket.assigns.auction) do
      nil ->
        {:noreply, socket}

      amount ->
        {:noreply,
         socket
         |> assign(form: %{socket.assigns.form | amount: amount}, notice: nil)
         |> prepare_when_ready()}
    end
  end

  # The price to beat, entered from the auction's price panel as the limit.
  def handle_event("use_price", %{"price" => price}, socket) do
    form = BidForm.at_price(socket.assigns.form, price)
    {:noreply, socket |> assign(form: form, notice: nil) |> prepare_when_ready()}
  end

  def handle_event("clear_bid", _params, socket),
    do:
      {:noreply,
       socket
       |> assign(placed: nil, form: %{BidForm.blank() | pay_with: socket.assigns.form.pay_with})
       |> withdrawn()
       |> read_balance()}

  def handle_event("step_sent", params, socket),
    do: {:noreply, OnchainSteps.sent(socket, params)}

  def handle_event("step_failed", params, socket) do
    case Presses.failed(params) do
      {:ok, _name, reason} ->
        AutolaunchWeb.Telemetry.wallet_failed(:bid, reason)
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

  # A balance that could not be read says so; a later read that fails keeps
  # the last one read for the same wallet.
  def handle_async(:balance, {:ok, {wallet, read}}, %{assigns: %{wallet: wallet}} = socket) do
    case {read, socket.assigns.balance} do
      {{:ok, %{balance: balance}}, _shown} ->
        {:noreply, assign(socket, balance: balance)}

      {{:error, _error}, shown} when is_binary(shown) ->
        {:noreply, socket}

      {{:error, error}, _none} ->
        reason = refusal(error)
        notice = if reason in @told, do: copy(reason), else: socket.assigns.notice
        {:noreply, assign(socket, balance: :unread, notice: notice)}
    end
  end

  def handle_async(:balance, {:ok, _other_wallet}, socket), do: {:noreply, socket}

  def handle_async(:balance, {:exit, _reason}, socket) do
    if is_binary(socket.assigns.balance),
      do: {:noreply, socket},
      else: {:noreply, assign(socket, balance: :unread)}
  end

  def handle_async({:onchain_step, hash}, result, socket),
    do: {:noreply, OnchainSteps.checked(socket, hash, result, &confirmed/2)}

  def handle_async({:result, hash}, result, socket) do
    logs =
      case result do
        {:ok, {:ok, %{"logs" => logs}}} when is_list(logs) -> logs
        _unread -> nil
      end

    {:noreply, placed(socket, hash, logs)}
  end

  attr :prepared, :map, default: nil
  attr :rate, :any, required: true
  attr :chain_name, :string, default: nil

  # The bid in three lines: what it spends, what it buys and at most what
  # price, and where.
  defp summary(assigns) do
    ~H"""
    <dl class="bid-form__summary" aria-label="Your bid" hidden={!@prepared}>
      <%= if @prepared do %>
        <div>
          <dt>You pay</dt>
          <dd>
            <TokenDisplay.written value={@prepared.facts.pay} unit={@prepared.facts.pay_symbol} />
            <UsdValue.usd
              :if={@prepared.facts.pay_symbol == @prepared.facts.currency_symbol}
              amount={@prepared.facts.pay}
              rate={@rate}
            />
          </dd>
        </div>
        <div>
          <dt>You get</dt>
          <dd>
            <span class="ticker">{@prepared.facts.token_symbol}</span>
            at up to
            <TokenDisplay.price
              amount={@prepared.facts.max_price}
              unit={@prepared.facts.currency_symbol}
            /> each
          </dd>
        </div>
        <div>
          <dt>Network</dt><dd>{@chain_name}</dd>
        </div>
      <% end %>
    </dl>
    <p class="bid-form__note" hidden={!(@prepared && @prepared.facts.min_stock_out)}>
      <%= if @prepared && @prepared.facts.min_stock_out do %>
        Your <span class="ticker">USDC</span>
        buys at least
        <TokenDisplay.written
          value={@prepared.facts.min_stock_out}
          unit={@prepared.facts.currency_symbol}
        />, 1% below the estimate, or the bid is not placed.
      <% end %>
    </p>
    """
  end

  # Reviews

  # The bid is prepared in the background whenever what it would send changes:
  # the wallet, the currency, the total or the most per token (which moves with
  # the price to beat). One is prepared at a time; an answer for values the
  # form has since left starts the next.
  defp prepare_when_ready(%{assigns: assigns} = socket) do
    key = bid_key(assigns)

    cond do
      is_nil(key) or assigns.placed -> socket
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
    |> start_async(:prepare, fn -> {key, inputs, BidActions.prepare(request, signer, opts)} end)
  end

  # A press or an agent waits for this one: it is prepared at once.
  defp prepared_now(%{assigns: assigns} = socket) do
    case bid_key(assigns) do
      nil ->
        {:error, assign(socket, notice: incomplete(assigns))}

      key ->
        {signer, request} = request(assigns, key)
        result = BidActions.prepare(request, signer, opts(socket))
        socket = reviewed(socket, key, inputs(assigns), result)
        if match?({:ok, _prepared}, result), do: {:ok, socket}, else: {:error, socket}
    end
  end

  defp request(%{auction: auction}, {signer, pay_with, amount, max_price}),
    do:
      {signer,
       %{auction_id: auction.id, pay_with: pay_with, amount: amount, max_price: max_price}}

  defp reviewed(socket, key, inputs, {:ok, prepared}) do
    review =
      Review.new(socket.assigns.id, socket.assigns.signer, prepared.chain, prepared.steps, inputs)

    socket
    |> assign(prepared_for: key, notice: nil, press_note: nil)
    |> put_review(review, prepared)
    |> refresh_later()
  end

  defp reviewed(socket, key, _inputs, {:error, error}),
    do: assign(socket, prepared_for: {:refused, key}, notice: copy(refusal(error)))

  # The review on the page, and what each review still followed was prepared
  # with, so an outcome is read against the bid it belongs to.
  defp put_review(socket, review, prepared) do
    socket = socket |> assign(prepared: prepared) |> OnchainSteps.put_review(review)
    followed = MapSet.new(Presses.shown(socket.assigns.presses), & &1.review.id)

    reviews =
      socket.assigns.reviews
      |> Map.filter(fn {id, _prepared} -> MapSet.member?(followed, id) end)
      |> then(&if review, do: Map.put(&1, review.id, prepared), else: &1)

    assign(socket, reviews: reviews)
  end

  @refresh_ms 8 * 60_000

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

  defp agent_bid(%{assigns: %{signer: nil} = assigns} = socket),
    do: {:reply, AgentPress.refused(no_signer(assigns)), socket}

  defp agent_bid(%{assigns: assigns} = socket) do
    case current_step(assigns) do
      %{name: name} -> {:reply, sending(assigns, name), socket}
      nil -> agent_prepared(socket)
    end
  end

  defp agent_prepared(socket) do
    case prepared_now(socket) do
      {:ok, socket} ->
        [%{step: first} | _rest] = socket.assigns.review.steps
        {:reply, sending(socket.assigns, first), socket}

      {:error, socket} ->
        {:reply, AgentPress.refused(socket.assigns.notice || @generic), socket}
    end
  end

  # The next step of the review on the page, while it is for the form as it is now.
  defp current_step(assigns) do
    key = bid_key(assigns)
    if key && assigns.prepared_for == key && assigns.review, do: next_step(assigns)
  end

  defp sending(%{review: review, prepared: prepared}, step),
    do: AgentPress.sending(review, step, &step_label(&1, prepared))

  defp no_signer(%{linked: nil}), do: copy(:authentication_required)
  defp no_signer(%{active: nil}), do: "Connect your wallet, then press again."
  defp no_signer(_assigns), do: copy(:wrong_signer)

  defp agent_pay_with(nil, %{auction: auction}), do: {:ok, auction.quote_token_symbol}
  defp agent_pay_with("USDC", %{usdc_bids?: true}), do: {:ok, "USDC"}
  defp agent_pay_with("USDC", _assigns), do: {:error, :usdc_bids_unavailable}

  defp agent_pay_with(symbol, %{auction: %{quote_token_symbol: symbol}}), do: {:ok, symbol}
  defp agent_pay_with(_other, _assigns), do: {:error, :usdc_bids_unavailable}

  # The form as it was on screen when pressed: a max FDV that differs from the
  # one shown was typed, so the bid follows it.
  defp pressed_form(assigns, inputs) do
    shown = inputs(assigns)

    BidForm.values(
      %{
        "amount" => text(inputs["amount"]),
        "pay_with" => inputs["pay_with"] || assigns.form.pay_with,
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

  defp inputs(%{form: form, auction: auction} = assigns),
    do:
      BidForm.inputs(
        form,
        assigns.book,
        auction.token_supply,
        assigns.usd_rate.result,
        auction.quote_token_symbol,
        pay_with(auction, assigns.usdc_bids?)
      )

  # With no wallet to send from, the press's own note names the wallet to use.
  defp incomplete(%{signer: nil}), do: nil
  defp incomplete(%{form: %{amount: ""}}), do: copy(:amount_required)
  defp incomplete(_assigns), do: copy(:invalid_price)

  defp bid_key(%{signer: signer, form: form} = assigns) when is_binary(signer) do
    with amount when amount != "" <- form.amount,
         max_price when is_binary(max_price) <- max_price(assigns),
         do: {signer, form.pay_with, amount, max_price},
         else: (_incomplete -> nil)
  end

  defp bid_key(_assigns), do: nil

  defp max_price(%{form: form, auction: auction} = assigns) do
    {_unit, factor} =
      BidForm.fdv_currency(form.pay_with, auction.quote_token_symbol, assigns.usd_rate.result)

    BidForm.max_price(form, assigns.book, auction.token_supply, factor)
  end

  # Outcomes

  # A bid landed: what it placed is read from its receipt. An approval moves
  # the panel on to the next step and nothing more.
  defp confirmed(socket, %{name: name, hash: hash, review: review})
       when name in ["bid", "usdc_bid"],
       do: start_async(socket, {:result, hash}, fn -> Client.receipt(review.chain, hash) end)

  defp confirmed(socket, _approval), do: socket

  # The bid is recorded as its bidder's position and the panel shows it placed,
  # whichever of this page's reviews it was sent from.
  defp placed(socket, hash, logs) do
    with %{name: name, review: %{id: id, chain: chain}} <-
           Enum.find(Presses.shown(socket.assigns.presses), &(&1.hash == hash)),
         %{context: context} <- Map.get(socket.assigns.reviews, id) do
      project(context, logs && BidActions.result(context, name, logs))

      socket
      |> assign(placed: %{hash: hash, chain_id: chain.chain_id}, notice: nil)
      |> withdrawn()
      |> read_balance()
    else
      _other -> socket
    end
  end

  defp project(_context, nil), do: :ok
  defp project(context, result), do: LabProjection.project_bid(context, result)

  defp read_balance(%{assigns: %{wallet: wallet, auction: auction}} = socket)
       when is_binary(wallet) do
    opts = opts(socket)

    start_async(socket, :balance, fn ->
      {wallet, Autolaunch.bid_position(auction.id, wallet, opts)}
    end)
  end

  defp read_balance(socket), do: socket

  defp failure_note(%{review: review} = assigns, reason) do
    chain_name = if review, do: review.chain.name, else: "Base"
    OnchainSteps.failure_note(reason, assigns.linked, assigns.active, chain_name)
  end

  # Steps

  defp steps(%{review: %{} = review, prepared: prepared, presses: presses}) do
    Enum.map(review.steps, fn %{step: name} ->
      entry = OnchainSteps.entry(presses, review, name)
      %{name: name, label: step_label(name, prepared), state: step_state(entry), entry: entry}
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

  defp next_step(_assigns), do: %{name: "bid", label: "Place bid"}

  defp started?(presses, review),
    do: Enum.any?(review.steps, &OnchainSteps.entry(presses, review, &1.step))

  defp step_state(nil), do: :ready

  defp step_state(%{outcome: :pending} = entry),
    do: if(Presses.stalled?(entry), do: :stalled, else: :sent)

  defp step_state(%{outcome: :confirmed}), do: :done
  defp step_state(%{outcome: :reverted}), do: :reverted
  defp step_state(_not_this_step), do: :other

  defp step_label("usdc_approval", _prepared), do: "Approve USDC"
  defp step_label("token_approval", prepared), do: "Approve #{prepared.facts.currency_symbol}"

  defp step_label("permit2_approval", prepared),
    do: "Allow #{prepared.facts.currency_symbol} for this bid"

  defp step_label(_bid, _prepared), do: "Place bid"

  defp approval?(name), do: name in ["token_approval", "permit2_approval", "usdc_approval"]

  defp approval_currency(%{facts: %{pay_symbol: symbol}}), do: symbol
  defp approval_currency(_prepared), do: nil

  # How many times the wallet still asks, counting the step on the button.
  defp signatures_left(_steps, nil), do: 0

  defp signatures_left(steps, %{name: name}),
    do: steps |> Enum.drop_while(&(&1.name != name)) |> length()

  defp times(2), do: "twice"
  defp times(count), do: "#{count} times"

  # What is happening to the bid on the page, in a line.
  defp progress_copy(steps, prepared) do
    sent = Enum.filter(steps, &(&1.state in [:sent, :stalled, :other]))

    case {List.last(sent), steps} do
      {%{state: :other}, _steps} ->
        "That transaction is not the one this page prepared, so it can't be followed here. Check it in your wallet activity."

      {%{state: :stalled}, _steps} ->
        "Base has not confirmed this yet. Check again, or look in your wallet activity."

      {%{name: name}, _steps} ->
        if approval?(name),
          do: "Approving #{approval_currency(prepared)}…",
          else: "Confirming your bid…"

      {nil, [%{state: :done} | _rest] = steps} ->
        if Enum.any?(steps, &(&1.state == :ready)),
          do: "#{approval_currency(prepared)} approved. Now place your bid."

      {nil, _steps} ->
        nil
    end
  end

  defp pending_hash(steps) do
    Enum.find_value(steps, fn
      %{state: state, entry: %{hash: hash}, name: name} when state in [:sent, :stalled] ->
        if not approval?(name), do: hash

      _step ->
        nil
    end)
  end

  defp reverted(steps) do
    case Enum.find(steps, &(&1.state == :reverted)) do
      %{name: name} ->
        if approval?(name),
          do: "That approval did not go through. Press again.",
          else:
            "That bid did not go through on Base, so nothing was bought. Only the network fee was spent. You can send it again."

      nil ->
        nil
    end
  end

  # The tickers a bid's sentences name.
  defp tickers(%{facts: facts}), do: ["USDC", facts.currency_symbol]
  defp tickers(_prepared), do: ["USDC"]

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

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  # USDC bids exist only for Stocks auctions, and only where the Stocks lab that
  # names the adapter is running.
  @doc "The currency a bidder pays this auction in: USDC where the auction takes it, else its own."
  def bid_currency(auction),
    do: if(usdc_bids?(auction), do: "USDC", else: auction.quote_token_symbol)

  defp usdc_bids?(%{kind: :stocks}), do: StocksLab.configured?()
  defp usdc_bids?(_auction), do: false

  defp pay_with(auction, true), do: ["USDC", auction.quote_token_symbol]
  defp pay_with(_auction, false), do: []

  # The auction page hands over the book it already reads; anywhere else, such
  # as the gallery's bid popup, the panel reads the book itself, once.
  defp assign_book(%{assigns: %{book: %AsyncResult{}}} = socket), do: socket

  defp assign_book(%{assigns: %{auction: auction}} = socket),
    do:
      assign_async(socket, :book, fn ->
        with {:ok, book} <- AuctionBook.base(auction), do: {:ok, %{book: book}}
      end)

  # An amount, and a most per token, chosen before the panel opened are entered
  # once. A preset most per token replaces the slider.
  defp preset(%{assigns: %{form: form} = assigns} = socket)
       when not is_map_key(assigns, :preset_entered?) do
    form =
      form
      |> preset_amount(assigns[:preset_amount])
      |> preset_limit(assigns[:preset_limit])

    assign(socket, form: form, preset_entered?: true)
  end

  defp preset(socket), do: socket

  defp preset_amount(form, amount) when is_binary(amount), do: %{form | amount: amount}
  defp preset_amount(form, nil), do: form

  defp preset_limit(form, limit) when is_binary(limit), do: BidForm.at_price(form, limit)
  defp preset_limit(form, nil), do: form

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

  # The dollar price of the auction's currency, read once per auction and
  # apart from the form, so a slow price never holds a bid back.
  defp assign_usd_rate(%{assigns: %{auction: %{id: id}, usd_rate_for: id}} = socket), do: socket

  defp assign_usd_rate(%{assigns: %{auction: auction}} = socket) do
    socket
    |> assign(:usd_rate_for, auction.id)
    |> UsdValue.assign_rate(:usd_rate, :base, fn -> {:ok, %{usd_rate: UsdValue.rate(auction)}} end)
  end

  defp balance(balance, %{quote_token_decimals: decimals}) when is_binary(balance),
    do: balance |> String.to_integer() |> Autolaunch.bid_amount_units(decimals)

  defp balance(_unread, _auction), do: nil
end
