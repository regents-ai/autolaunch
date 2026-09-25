defmodule AutolaunchWeb.BidComponent do
  @moduledoc """
  The whole bidder: one compact form, the bid it prepares as it changes, and
  the transactions it needs, followed until Base confirms them.

  The wallet the customer signed in with drives everything here, read from the
  mounted lease, so the balance and the form show as soon as the panel mounts.
  The browser's wallet matters only when a button is pressed: the press opens the
  signed-in wallet, or Privy's connect step when this tab has not connected it,
  and a note names both wallets while the browser is on another one.

  The browser reports a hash and stops. Every outcome on screen comes from the
  server's own read of that exact hash, read again every few seconds until the
  chain answers; reading never sends anything or opens the wallet.
  """

  use AutolaunchWeb, :live_component

  import AutolaunchWeb.Components.TokenLinks, only: [regent_market_links: 1]

  alias Autolaunch
  alias Autolaunch.Actors.Human
  alias Autolaunch.AuctionBook
  alias Autolaunch.{BidActions, Lab}
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias AutolaunchWeb.Components.{BidForm, BidPlaced}
  alias AutolaunchWeb.{Paths, ShareCard, SignedInWallet, TokenDisplay, UsdValue}
  alias Phoenix.LiveView.AsyncResult

  @copy %{
    bid_preparation_unavailable: "Bidding is not open on this auction yet.",
    chain_unavailable: "Base could not be read just now. Try again in a moment.",
    wrong_signer: "You are now signed in with a different wallet. Reload the page to continue.",
    session_unavailable: "Sign in again to continue.",
    auction_currency_changed:
      "This auction's currency does not match its record. Bidding is paused here.",
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
    invalid_decimal: "Enter a maximum price above zero.",
    submitted_hash_conflict: "This step already has a transaction.",
    submitted_step_mismatch: "That transaction is not the step this bid is waiting for."
  }

  @generic "That did not go through. Try again in a moment."

  # The refusals that mean the session no longer vouches for the signed-in
  # wallet, so no private fact and no control belongs on screen.
  @unheld [:wrong_signer, :session_unavailable, :session_lease_required, :invalid_address]

  @impl true
  def update(%{wallet_press_result: result, wallet_press_lease: lease}, socket) do
    {:ok, socket |> AutolaunchWeb.WalletPressComponent.consume(lease, result) |> follow()}
  end

  # A sent transaction is read again every few seconds until the chain answers.
  # Reading never sends anything and never opens the wallet.
  def update(%{follow: {action_id, press_id}}, socket) do
    socket = assign(socket, following: nil)

    case socket.assigns.operation do
      %{action_id: ^action_id, state: :submitted} = operation ->
        if submitted_press(operation) == press_id,
          do: {:ok, verify(socket, action_id, press_id)},
          else: {:ok, follow(socket)}

      _other ->
        {:ok, follow(socket)}
    end
  end

  # A prepared review lives ten minutes; an unsent one is prepared again first.
  def update(%{refresh_review: action_id}, socket) do
    case socket.assigns.operation do
      %{action_id: ^action_id} = operation ->
        if editable?(operation),
          do: {:ok, socket |> assign(prepared_for: nil) |> prepare_when_ready()},
          else: {:ok, socket}

      _other ->
        {:ok, socket}
    end
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> AutolaunchWeb.WalletPressComponent.update_scope(assigns)
     |> assign(assigns)
     |> assign_new(:heading, fn -> "Place a bid" end)
     |> assign_new(:wallet, fn -> nil end)
     |> assign_new(:browser_wallets, fn -> [] end)
     |> assign_new(:balance, fn -> nil end)
     |> assign(:usdc_bids?, usdc_bids?(assigns[:auction] || socket.assigns[:auction]))
     |> assign_new(:form, fn %{auction: auction} ->
       %{BidForm.blank() | pay_with: bid_currency(auction)}
     end)
     |> assign_book()
     |> assign_new(:notice, fn -> nil end)
     |> assign_new(:wallet_press_history, fn -> %{} end)
     |> assign_new(:operation, fn -> nil end)
     |> assign_new(:following, fn -> nil end)
     |> assign_new(:x_connection, fn -> nil end)
     |> assign_new(:x_enabled, fn -> false end)
     |> assign_new(:prepared_for, fn -> nil end)
     |> assign_new(:preparing, fn -> nil end)
     |> assign_new(:owed, fn -> [] end)
     |> assign_new(:inputs, fn -> nil end)
     |> assign_usd_rate()
     |> preset()
     |> SignedInWallet.adopt(&adopt/2)
     |> prepare_when_ready()}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :rate, assigns.usd_rate.result)

    ~H"""
    <section
      id={@id}
      class="bid-panel"
      data-wallet-scope={AutolaunchWeb.WalletPressComponent.scope(assigns)}
      phx-hook="AutolaunchBidWallet"
      data-press-form={"#{@id}-form"}
      phx-target={@myself}
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

      <.notice :if={@notice} notice={@notice} />

      <p :if={!@authenticated} class="bid-empty">
        <Regent.Primitives.button type="button" data-account-target="sign-in">Sign in to bid</Regent.Primitives.button>
      </p>

      <div :if={@authenticated && @wallet} class="bid-body">
        <BidForm.bid_form
          :if={editable?(@operation) && @balance}
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
            <.ready
              :if={ready?(assigns)}
              operation={@operation}
              rate={@rate}
              wallet={@wallet}
              browser_wallets={@browser_wallets}
            />
            <div :if={!ready?(assigns)} class="bid-form__pending">
              <p :if={@preparing} class="bid-form__note" role="status">Getting your bid ready…</p>
              <SignedInWallet.note signed_in={@wallet} browser={@browser_wallets} />
              <Regent.Primitives.button class="bid-primary" type="button" disabled>
                Place bid
              </Regent.Primitives.button>
            </div>
          </:action>
        </BidForm.bid_form>

        <section
          :if={!editable?(@operation) && @operation.state == :confirmed}
          id={"#{@id}-placed"}
          class="bid-progress"
          aria-label="Bid placed"
        >
          <BidPlaced.bid_placed
            id={"#{@id}-placed"}
            target={@myself}
            token_symbol={@auction.token_symbol}
            chain={:base}
            hash={placed_hash(@operation)}
            test_chain={Lab.test_chain?(@operation.envelope["chain_id"])}
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

        <section
          :if={!editable?(@operation) && @operation.state != :confirmed}
          id={"#{@id}-progress"}
          class="bid-progress"
          aria-label="Your bid"
        >
          <.summary operation={@operation} rate={@rate} />
          <p class="bid-progress__status" role="status" aria-live="polite">
            <TokenDisplay.marked text={progress_copy(@operation)} tickers={tickers(@operation)} />
          </p>
          <a
            :if={pending_hash(@operation) && !Lab.test_chain?(@operation.envelope["chain_id"])}
            href={BidPlaced.transaction_url(:base, pending_hash(@operation))}
            target="_blank"
            rel="noopener noreferrer"
          >
            View on Basescan ↗
          </a>
          <p :if={slow?(@operation)} class="bid-form__note">
            This is taking longer than usual. It can still go through, and there is nothing you need to do.
          </p>
          <SignedInWallet.note
            :if={sendable?(@operation, @wallet)}
            signed_in={@wallet}
            browser={@browser_wallets}
          />
          <Regent.Primitives.button
            :if={sendable?(@operation, @wallet)}
            class="bid-primary"
            type="button"
            data-bid-send={@operation.action_id}
            data-wallet-step={@operation.step}
            data-bid-signer={@operation.signer}
            variant={if @operation.state == :submitted, do: "secondary", else: "primary"}
          >
            {press_label(@operation)}
          </Regent.Primitives.button>
          <p :if={@operation.signer != @wallet} role="status">
            This bid belongs to another wallet. Sign in with that wallet to finish.
          </p>
          <Regent.Primitives.button
            :if={@operation.state == :prepared}
            type="button"
            phx-click="clear_bid"
            phx-target={@myself}
            variant="secondary"
          >
            Change bid
          </Regent.Primitives.button>
        </section>
      </div>
    </section>
    """
  end

  @impl true
  def handle_event("wallet_press_dispatch", params, socket),
    do:
      {:noreply,
       AutolaunchWeb.WalletPressComponent.dispatch(socket, :bid, params, opts(socket), __MODULE__)}

  def handle_event("wallet_press_report", params, socket),
    do:
      {:noreply,
       AutolaunchWeb.WalletPressComponent.report(socket, :bid, params, opts(socket), __MODULE__)}

  # The wallets this tab has connected, whenever they change: only for the note.
  def handle_event("browser_wallets", params, socket),
    do: {:noreply, assign(socket, browser_wallets: SignedInWallet.reported(params))}

  def handle_event("bid_form_changed", params, socket) do
    form = BidForm.values(params, socket.assigns.form, max_price(socket.assigns))
    {:noreply, socket |> assign(form: form, notice: nil) |> prepare_when_ready()}
  end

  # A press made while the form on screen differs from the review the browser
  # holds. The bid is prepared for exactly the values pressed and handed back to
  # press; a review already prepared for them is handed back as it is.
  def handle_event("prepare_and_send", %{"form" => params}, socket) do
    form = BidForm.values(params, socket.assigns.form, max_price(socket.assigns))
    socket = assign(socket, form: form, notice: nil)
    {:noreply, pressed(socket, bid_key(socket.assigns))}
  end

  def handle_event("fill_bid_amount", _params, socket) do
    amount = balance(socket.assigns.balance, socket.assigns.auction)

    {:noreply,
     socket
     |> assign(form: %{socket.assigns.form | amount: amount}, notice: nil)
     |> prepare_when_ready()}
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
       |> assign(
         operation: nil,
         prepared_for: nil,
         form: %{BidForm.blank() | pay_with: socket.assigns.form.pay_with}
       )
       |> cleared()}

  def handle_event("share_opened", _params, socket), do: {:noreply, load_x(socket)}

  def handle_event("refresh_x_connections", _params, socket), do: {:noreply, load_x(socket)}

  @impl true
  def handle_async(:prepare, {:ok, {key, inputs, result}}, socket) do
    {presses, owed} = Enum.split_with(socket.assigns.owed, &match?({^key, _inputs}, &1))
    socket = assign(socket, preparing: nil, owed: owed)

    cond do
      # Presses wait for this review: it goes back to be pressed once for each.
      presses != [] ->
        {:noreply, socket |> reviewed(key, inputs, result, length(presses)) |> prepare_owed()}

      # A press reached the wallet while this was prepared: the panel keeps
      # that bid, and the unused review lapses on its own.
      !editable?(socket.assigns.operation) ->
        {:noreply, prepare_owed(socket)}

      owed != [] ->
        {:noreply, prepare_owed(socket)}

      key != bid_key(socket.assigns) ->
        {:noreply, prepare_when_ready(socket)}

      true ->
        {:noreply, reviewed(socket, key, inputs, result, 0)}
    end
  end

  def handle_async(:prepare, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, preparing: nil, owed: [], notice: notice(:error, :unavailable))}

  attr :operation, :map, required: true
  attr :rate, :any, required: true
  attr :wallet, :string, required: true
  attr :browser_wallets, :list, required: true

  # The prepared bid in three lines, over the one button that opens the wallet.
  defp ready(assigns) do
    ~H"""
    <.summary operation={@operation} rate={@rate} />
    <p :if={attempt_copy(@operation)} class="bid-notice" role="status">
      <TokenDisplay.marked text={attempt_copy(@operation)} tickers={tickers(@operation)} />
    </p>
    <p :if={approval?(@operation.step)} class="bid-form__note">
      Your wallet asks {times(signatures_left(@operation))}: first to let the auction use your <span class="ticker">{approval_currency(@operation)}</span>, last to place the bid.
    </p>
    <SignedInWallet.note signed_in={@wallet} browser={@browser_wallets} />
    <Regent.Primitives.button
      class="bid-primary"
      type="button"
      data-bid-send={@operation.action_id}
      data-wallet-step={@operation.step}
      data-bid-signer={@operation.signer}
    >
      {press_label(@operation)}
    </Regent.Primitives.button>
    """
  end

  attr :operation, :map, required: true
  attr :rate, :any, required: true

  # The bid in three lines: what it spends, the most it pays, and where.
  defp summary(assigns) do
    ~H"""
    <dl class="bid-form__summary" aria-label="Your bid">
      <div>
        <dt>Total bid</dt>
        <dd :if={argument(@operation, "usdc_amount")}>
          <TokenDisplay.written value={argument(@operation, "usdc_amount")} unit="USDC" />
        </dd>
        <dd :if={!argument(@operation, "usdc_amount")}>
          <TokenDisplay.written
            value={argument(@operation, "amount")}
            unit={argument(@operation, "currency_symbol")}
          />
          <UsdValue.usd amount={argument(@operation, "amount")} rate={@rate} />
        </dd>
      </div>
      <div>
        <dt>Most per token</dt>
        <dd>
          <TokenDisplay.price
            amount={argument(@operation, "max_price")}
            unit={argument(@operation, "currency_symbol")}
          />
        </dd>
      </div>
      <div>
        <dt>Network</dt><dd>{Lab.network_name(@operation.envelope["chain_id"])}</dd>
      </div>
    </dl>
    <p :if={argument(@operation, "min_stock_out")} class="bid-form__note">
      Your <span class="ticker">USDC</span>
      buys at least
      <TokenDisplay.written
        value={argument(@operation, "min_stock_out")}
        unit={argument(@operation, "currency_symbol")}
      />, 1% below the estimate, or the bid is not placed.
    </p>
    """
  end

  attr :notice, :map, required: true

  defp notice(assigns) do
    ~H"""
    <p class="bid-notice" role={if @notice.tone == :error, do: "alert", else: "status"}>
      {@notice.message}
    </p>
    """
  end

  defp reviewed(socket, key, inputs, {:ok, _prepared} = result, presses),
    do:
      result
      |> settled(assign(socket, prepared_for: key, inputs: inputs), presses)
      |> refresh_later()

  defp reviewed(socket, key, _inputs, result, _presses),
    do: settled(result, assign(socket, prepared_for: {:refused, key}))

  defp settled(result, socket, presses \\ 0)

  defp settled({:ok, %{operation: operation}}, socket, presses),
    do: socket |> assign(operation: operation, notice: nil) |> published(presses)

  defp settled({:error, error}, socket, _presses),
    do: assign(socket, notice: notice(:error, refusal(error)))

  # The one acknowledgement the browser waits for before it drops its own copy
  # of a reported hash: this exact hash is durable on this exact step.
  # The whole reviewed sequence, so the browser can check that what it is asked
  # to send really belongs to the operation it is holding.
  # It carries the form values it was prepared for. Answering presses, it is
  # handed over once per press, each naming the step that press sends.
  defp published(%{assigns: %{operation: nil}} = socket, _presses), do: cleared(socket)

  defp published(%{assigns: %{operation: operation}} = socket, presses) do
    payload = %{
      component_id: socket.assigns.id,
      action_id: operation.action_id,
      signer: operation.signer,
      chain_id: operation.envelope["chain_id"],
      lab: operation.envelope["metadata"]["lab"],
      lab_anchor: lab_anchor(operation.envelope),
      terminal: not is_nil(operation.terminal_at),
      steps: BidActions.steps(operation),
      inputs: socket.assigns.inputs
    }

    if presses == 0,
      do: push_event(socket, "autolaunch-bid:operation", payload),
      else:
        Enum.reduce(1..presses, socket, fn _press, socket ->
          push_event(
            socket,
            "autolaunch-bid:operation",
            Map.put(payload, :send, Atom.to_string(operation.step))
          )
        end)
  end

  defp lab_anchor(envelope),
    do: %{
      block_number: envelope["arguments"]["block_number"],
      block_hash: envelope["arguments"]["block_hash"]
    }

  defp cleared(socket), do: push_event(socket, "autolaunch-bid:cleared", %{})

  # Signed out: the panel reads nothing and says nothing.
  defp adopt(socket, nil), do: assign(socket, wallet: nil, balance: nil, notice: nil)

  defp adopt(socket, address) do
    case Autolaunch.bid_position(socket.assigns.auction.id, address, opts(socket)) do
      {:ok, %{signer: signer, balance: balance}} -> switched(socket, signer, balance)
      {:error, error} -> refused(socket, address, refusal(error))
    end
  end

  # A review is prepared for one signer, so after signing in with another
  # wallet it cannot be spent and it is withdrawn. Anything already claimed stays exactly where it is, bound
  # to the wallet it was reviewed for.
  defp switched(%{assigns: %{wallet: wallet}} = socket, signer, balance) when wallet != signer,
    do: socket |> assign(wallet: signer, balance: balance, notice: nil) |> withdraw()

  defp switched(socket, signer, balance),
    do: assign(socket, wallet: signer, balance: balance, notice: nil)

  defp withdraw(%{assigns: %{operation: %{state: :prepared} = operation}} = socket) do
    if started?(operation), do: socket, else: cancel(socket, operation)
  end

  defp withdraw(socket), do: socket

  defp cancel(socket, operation) do
    case Autolaunch.cancel_bid_review(operation.action_id, opts(socket)) do
      {:ok, _cancelled} -> socket |> assign(operation: nil) |> cleared()
      denied -> settled(denied, socket)
    end
  end

  # Membership is a session fact and a balance is a chain fact. A wallet the
  # session no longer vouches for is not adopted at all; the signed-in one stays
  # on screen with the reason its position could not be read.
  defp refused(socket, _address, reason) when reason in @unheld,
    do: assign(socket, wallet: nil, balance: nil, notice: notice(:error, reason))

  defp refused(socket, address, reason),
    do:
      assign(socket,
        wallet: address,
        balance: nil,
        notice: notice(:info, reason),
        signed_in_for: nil
      )

  defp opts(socket),
    do: [
      actor: actor(socket),
      context: %{session_lease: socket.assigns.session_lease}
    ]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  defp sendable?(%{state: state, signer: signer, terminal_at: nil}, wallet)
       when state in [:prepared, :dispatched, :submitted],
       do: signer == wallet

  defp sendable?(_operation, _wallet), do: false

  # The bid is prepared in the background whenever what it would send changes:
  # the wallet, the currency, the total or the most per token (which moves with
  # the price to beat). Nothing is prepared in the background while a bid of
  # this panel is with the wallet or on its way, so the panel keeps showing
  # that bid. Reviews are prepared one at a time, in the order asked for, and
  # presses waiting for theirs come first; no review cancels another.
  defp prepare_when_ready(%{assigns: assigns} = socket) do
    key = bid_key(assigns)

    cond do
      !editable?(assigns.operation) -> socket
      is_nil(key) -> socket
      assigns.preparing || assigns.owed != [] -> socket
      assigns.prepared_for in [key, {:refused, key}] -> socket
      true -> start_prepare(socket, key, assigns.form)
    end
  end

  defp start_prepare(socket, {wallet, _pay_with, _amount, max_price} = key, form) do
    %{auction: %{id: auction_id}} = socket.assigns
    opts = opts(socket)

    socket
    |> assign(preparing: key)
    |> start_async(:prepare, fn ->
      {key, form, prepare(auction_id, form, wallet, max_price, opts)}
    end)
  end

  # A press is answered by the review for its values: the one already
  # prepared, or the next one prepared.
  defp pressed(socket, nil), do: assign(socket, notice: notice(:error, incomplete(socket)))

  defp pressed(%{assigns: %{prepared_for: key} = assigns} = socket, key)
       when is_map(assigns.operation) do
    if ready?(assigns),
      do: published(socket, 1),
      else: socket |> owe(key) |> prepare_owed()
  end

  defp pressed(socket, key), do: socket |> owe(key) |> prepare_owed()

  defp owe(socket, key),
    do: assign(socket, owed: socket.assigns.owed ++ [{key, socket.assigns.form}])

  defp prepare_owed(%{assigns: %{preparing: nil, owed: [{key, form} | _rest]}} = socket),
    do: start_prepare(socket, key, form)

  defp prepare_owed(socket), do: socket

  defp incomplete(%{assigns: %{form: %{amount: ""}}}), do: :amount_required
  defp incomplete(_socket), do: :invalid_price

  defp bid_key(%{wallet: wallet, balance: balance, form: form} = assigns)
       when is_binary(wallet) and is_binary(balance) do
    with amount when amount != "" <- form.amount,
         max_price when is_binary(max_price) <- max_price(assigns),
         do: {wallet, form.pay_with, amount, max_price},
         else: (_incomplete -> nil)
  end

  defp bid_key(_assigns), do: nil

  defp max_price(%{form: form, auction: auction} = assigns) do
    {_unit, factor} =
      BidForm.fdv_currency(form.pay_with, auction.quote_token_symbol, assigns.usd_rate.result)

    BidForm.max_price(form, assigns.book, auction.token_supply, factor)
  end

  # The form is open while this panel has no bid with the wallet or on its way.
  defp editable?(nil), do: true

  defp editable?(%{terminal_at: terminal, state: state}) when not is_nil(terminal),
    do: state != :confirmed

  defp editable?(%{state: :prepared} = operation), do: !started?(operation)
  defp editable?(_operation), do: false

  defp ready?(%{operation: %{state: :prepared, terminal_at: nil} = operation} = assigns),
    do: assigns.prepared_for == bid_key(assigns) and sendable?(operation, assigns.wallet)

  defp ready?(_assigns), do: false

  @refresh_ms 8 * 60_000

  defp refresh_later(%{assigns: %{operation: %{action_id: action_id}}} = socket) do
    send_update_after(
      self(),
      __MODULE__,
      [id: socket.assigns.id, refresh_review: action_id],
      @refresh_ms
    )

    socket
  end

  defp refresh_later(socket), do: socket

  defp approval?(step), do: step in [:token_approval, :permit2_approval, :usdc_approval]

  defp approval_currency(%{step: :usdc_approval}), do: "USDC"
  defp approval_currency(operation), do: argument(operation, "currency_symbol")

  defp signatures_left(%{step: step} = operation) do
    operation
    |> BidActions.steps()
    |> Enum.drop_while(&(&1["step"] != Atom.to_string(step)))
    |> length()
  end

  # The tickers a bid's sentences name.
  defp tickers(operation), do: ["USDC", argument(operation, "currency_symbol")]

  defp times(2), do: "twice"
  defp times(count), do: "#{count} times"

  defp press_label(%{step: step} = operation) do
    if approval?(step), do: "Approve #{approval_currency(operation)}", else: "Place bid"
  end

  @follow_ms 3_000
  @slow_seconds 60

  defp follow(%{assigns: %{following: nil, operation: %{state: :submitted} = operation}} = socket) do
    press_id = submitted_press(operation)

    send_update_after(
      self(),
      __MODULE__,
      [id: socket.assigns.id, follow: {operation.action_id, press_id}],
      @follow_ms
    )

    assign(socket, following: press_id)
  end

  defp follow(socket), do: socket

  defp verify(socket, action_id, press_id) do
    params = %{"action_id" => action_id, "press_id" => press_id}
    AutolaunchWeb.WalletPressComponent.verify(socket, :bid, params, opts(socket), __MODULE__)
  end

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

  # What is happening to a bid that has left the form, in a line.
  defp progress_copy(%{state: :dispatched} = operation) do
    cond do
      match?(%{state: :submission_unknown}, latest_attempt(operation)) ->
        "Your wallet may have sent this. Check your wallet's activity before sending it again."

      approval?(operation.step) ->
        "Approve #{approval_currency(operation)} in your wallet."

      true ->
        "Confirm your bid in your wallet."
    end
  end

  defp progress_copy(%{state: :submitted} = operation) do
    if approval?(operation.step),
      do: "Approving #{approval_currency(operation)}…",
      else: "Confirming your bid…"
  end

  defp progress_copy(%{state: :prepared} = operation) do
    cond do
      attempt_copy(operation) -> attempt_copy(operation)
      approval?(operation.step) -> "Approved. One more approval, then your bid."
      true -> "#{approval_currency(operation)} approved. Now place your bid."
    end
  end

  # How the last press of this step ended, when it ended without a transaction
  # that counts.
  defp attempt_copy(operation) do
    case latest_attempt(operation) do
      %{state: :reverted} ->
        "That transaction was reverted on Base, so nothing was bought. Only the network fee was spent. You can send it again."

      %{state: :unverified} ->
        "That transaction did not match this bid, so it was not counted. Check your wallet's activity."

      %{state: :not_sent} ->
        "Your wallet declined, so nothing was sent."

      %{state: :not_started} ->
        "Your wallet did not open, so nothing was sent. Try again."

      _other ->
        nil
    end
  end

  defp latest_attempt(%{attempts: attempts, step: step}),
    do: attempts |> Enum.filter(&(&1.step == step)) |> List.last()

  defp pending_hash(operation),
    do:
      Enum.find_value(
        operation.attempts,
        &(&1.state == :submitted and &1.step == operation.step and &1.transaction_hash)
      )

  defp placed_hash(operation), do: BidActions.step_hash(operation, Atom.to_string(operation.step))

  defp slow?(%{state: :submitted} = operation) do
    Enum.any?(
      operation.attempts,
      &(&1.state == :submitted and &1.step == operation.step and
          DateTime.diff(DateTime.utc_now(), &1.updated_at) > @slow_seconds)
    )
  end

  defp slow?(_operation), do: false

  defp started?(operation),
    do: Enum.any?(BidActions.steps(operation), &BidActions.step_hash(operation, &1["step"]))

  # USDC bids exist only for Stocks auctions, and only where the Stocks lab that
  # names the adapter is running.
  @doc "The currency a bidder pays this auction in: USDC where the auction takes it, else its own."
  def bid_currency(auction),
    do: if(usdc_bids?(auction), do: "USDC", else: auction.quote_token_symbol)

  defp usdc_bids?(%{kind: :stocks}), do: StocksLab.configured?()
  defp usdc_bids?(_auction), do: false

  defp pay_with(auction, true), do: ["USDC", auction.quote_token_symbol]
  defp pay_with(_auction, false), do: []

  defp prepare(auction_id, %{pay_with: "USDC", amount: amount}, wallet, max_price, opts),
    do: Autolaunch.prepare_usdc_bid(auction_id, wallet, amount, max_price, opts)

  defp prepare(auction_id, %{amount: amount}, wallet, max_price, opts),
    do: Autolaunch.prepare_bid(auction_id, wallet, amount, max_price, opts)

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

  # The press whose transaction the card is waiting on: the submitted attempt of
  # the current step, whose hash the chain has not answered about yet.
  defp submitted_press(operation),
    do:
      Enum.find_value(
        operation.attempts,
        &(&1.state == :submitted and &1.step == operation.step and &1.id)
      )

  defp notice(tone, reason), do: %{tone: tone, message: copy(reason)}

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

  # The dollar price of the auction's currency, read once per auction and
  # apart from the form, so a slow price never holds a bid back.
  defp assign_usd_rate(%{assigns: %{auction: %{id: id}, usd_rate_for: id}} = socket), do: socket

  defp assign_usd_rate(%{assigns: %{auction: auction}} = socket) do
    socket
    |> assign(:usd_rate_for, auction.id)
    |> UsdValue.assign_rate(:usd_rate, :base, fn -> {:ok, %{usd_rate: UsdValue.rate(auction)}} end)
  end

  defp balance(nil, _auction), do: "—"

  defp balance(atomic, %{quote_token_decimals: decimals}),
    do: atomic |> String.to_integer() |> Autolaunch.bid_amount_units(decimals)
end
