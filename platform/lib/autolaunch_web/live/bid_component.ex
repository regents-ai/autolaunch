defmodule AutolaunchWeb.BidComponent do
  @moduledoc """
  The whole bidder: one compact form, one review, and the transactions it needs.

  The wallet Privy has selected drives everything here. Its address arrives as
  untrusted browser input and is proved against the mounted lease before any
  private fact is read or any durable write happens, so any wallet other than
  the signed-in one shows a balance of nothing and can neither review nor send.

  The browser reports a hash and stops. Every outcome on screen comes from the
  server's own read of that exact hash, and a claimed step is never offered a
  second send.
  """

  use AutolaunchWeb, :live_component

  import AutolaunchWeb.Components.TokenLinks, only: [regent_market_links: 1]

  alias Autolaunch
  alias Autolaunch.Actors.Human
  alias Autolaunch.{BidActions, Lab}
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias AutolaunchWeb.UsdValue

  @chain_id 8453

  @copy %{
    bid_preparation_unavailable: "Bidding is not open on this auction yet.",
    chain_unavailable: "Base could not be read just now. Try again in a moment.",
    wrong_signer:
      "Switch back to the wallet you signed in with, or sign out and sign in with this one.",
    session_unavailable: "Sign in again to continue.",
    auction_not_biddable: "This auction is not taking bids.",
    auction_currency_changed:
      "This auction's currency does not match its record. Bidding is paused here.",
    amount_above_balance: "That is more than this wallet holds.",
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

  # The refusals that mean this browser is not offering the signed-in
  # wallet, so no private fact and no control belongs on screen.
  @unheld [:wrong_signer, :session_unavailable, :session_lease_required, :invalid_address]

  @impl true
  def update(%{wallet_press_result: result, wallet_press_lease: lease}, socket) do
    {:ok, AutolaunchWeb.WalletPressComponent.consume(socket, lease, result)}
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> AutolaunchWeb.WalletPressComponent.update_scope(assigns)
     |> assign(assigns)
     |> assign_new(:wallet, fn -> nil end)
     |> assign_new(:balance, fn -> nil end)
     |> assign_new(:amount, fn -> "" end)
     |> assign_new(:max_price, fn -> "" end)
     |> assign_new(:usdc_amount, fn -> "" end)
     |> assign_new(:usdc_max_price, fn -> "" end)
     |> assign_new(:estimate, fn -> nil end)
     |> assign(:usdc_bids?, usdc_bids?(assigns[:auction] || socket.assigns[:auction]))
     |> assign_new(:notice, fn -> nil end)
     |> assign_new(:wallet_press_history, fn -> %{} end)
     |> assign_new(:operation, fn -> nil end)
     |> assign_usd_rate()
     |> preset()}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :rate, assigns.usd_rate.result)

    ~H"""
    <section
      id={@id}
      class="bid-panel rg-panel rg-panel--surface"
      data-wallet-scope={AutolaunchWeb.WalletPressComponent.scope(assigns)}
      phx-hook="AutolaunchBidWallet"
      phx-target={@myself}
    >
      <header class="bid-heading">
        <Regent.Structure.section_bar>
          <h2 class="rg-section-bar__label">Place a bid</h2>
        </Regent.Structure.section_bar>
        <p>
          Bid {if @usdc_bids?, do: "USDC or "}{@auction.quote_token_symbol} for this launch. Your wallet confirms every step.
        </p>
        <.regent_market_links :if={@auction.kind == :agent} />
      </header>

      <.notice :if={@notice} notice={@notice} />

      <p :if={!@authenticated} class="bid-empty">
        <Regent.Primitives.button type="button" data-account-target="sign-in">Sign in to bid</Regent.Primitives.button>
      </p>

      <div :if={@authenticated && !@wallet} class="bid-empty">
        <p>Choose the wallet you want to bid from.</p>
        <Regent.Primitives.button type="button" data-bid-connect>Connect or switch wallet</Regent.Primitives.button>
      </div>

      <div :if={@authenticated && @wallet} class="bid-body">
        <dl class="bid-wallet">
          <div>
            <dt>Wallet</dt><dd class="bid-mono">{short(@wallet)}</dd>
          </div>
          <div>
            <dt>{@auction.quote_token_symbol}</dt>
            <dd>
              {balance(@balance, @auction)}
              <UsdValue.usd amount={balance(@balance, @auction)} rate={@rate} />
            </dd>
          </div>
        </dl>

        <form
          :if={!@operation && @balance}
          id={"#{@id}-form"}
          class="rg-field"
          phx-change="bid_form_changed"
          phx-submit="review_bid"
          phx-target={@myself}
          aria-label={"Bid with #{@auction.quote_token_symbol}"}
        >
          <h3>Bid with {@auction.quote_token_symbol}</h3>
          <label for={"#{@id}-amount"}>Amount in {@auction.quote_token_symbol}</label>
          <div class="bid-amount">
            <input
              id={"#{@id}-amount"}
              name="amount"
              value={@amount}
              inputmode="decimal"
              autocomplete="off"
              placeholder="0.0"
            />
            <Regent.Primitives.button
              type="button"
              phx-click="fill_bid_amount"
              phx-target={@myself}
              variant="secondary"
            >Max</Regent.Primitives.button>
          </div>
          <p :if={@amount != ""} class="bid-usd"><UsdValue.usd amount={@amount} rate={@rate} /></p>

          <label for={"#{@id}-max-price"}>Maximum price in {@auction.quote_token_symbol} per token</label>
          <input
            id={"#{@id}-max-price"}
            name="max_price"
            value={@max_price}
            inputmode="decimal"
            autocomplete="off"
            placeholder="0.0"
          />
          <p :if={@max_price != ""} class="bid-usd">
            <UsdValue.usd amount={@max_price} rate={@rate} per="per token" />
          </p>

          <p :if={@estimate} class="bid-estimate">
            You would receive about {@estimate} tokens if the auction ended now.
          </p>

          <Regent.Primitives.button
            class="bid-primary"
            type="submit"
            disabled={@amount == "" or @max_price == ""}
          >
            Review bid
          </Regent.Primitives.button>
        </form>

        <form
          :if={!@operation && @balance && @usdc_bids?}
          id={"#{@id}-usdc-form"}
          class="rg-field"
          phx-change="usdc_bid_form_changed"
          phx-submit="review_usdc_bid"
          phx-target={@myself}
          aria-label="Bid with USDC"
        >
          <h3>Bid with USDC</h3>
          <p class="autolaunch-draft-hint">
            One transaction buys {@auction.quote_token_symbol} with your USDC and places the bid.
            The review shows the estimated {@auction.quote_token_symbol} and the least the bid will accept, 1% below the estimate.
          </p>
          <label for={"#{@id}-usdc-amount"}>Amount in USDC</label>
          <input
            id={"#{@id}-usdc-amount"}
            name="usdc_amount"
            value={@usdc_amount}
            inputmode="decimal"
            autocomplete="off"
            placeholder="0.0"
          />
          <label for={"#{@id}-usdc-max-price"}>Maximum price in {@auction.quote_token_symbol} per token</label>
          <input
            id={"#{@id}-usdc-max-price"}
            name="max_price"
            value={@usdc_max_price}
            inputmode="decimal"
            autocomplete="off"
            placeholder="0.0"
          />
          <p :if={@usdc_max_price != ""} class="bid-usd">
            <UsdValue.usd amount={@usdc_max_price} rate={@rate} per="per token" />
          </p>
          <Regent.Primitives.button
            class="bid-primary"
            type="submit"
            disabled={@usdc_amount == "" or @usdc_max_price == ""}
          >
            Review USDC bid
          </Regent.Primitives.button>
        </form>

        <section :if={@operation} id={"#{@id}-review"} class="bid-review" aria-label="Bid review">
          <dl>
            <div :if={argument(@operation, "amount")}>
              <dt>Amount</dt><dd>
                {argument(@operation, "amount")} {argument(@operation, "currency_symbol")}
                <UsdValue.usd amount={argument(@operation, "amount")} rate={@rate} />
              </dd>
            </div>
            <div :if={argument(@operation, "usdc_amount")}>
              <dt>USDC spent</dt><dd>{argument(@operation, "usdc_amount")} USDC</dd>
            </div>
            <div :if={argument(@operation, "stock_quote")}>
              <dt>Estimated {argument(@operation, "currency_symbol")}</dt>
              <dd>
                {argument(@operation, "stock_quote")}
                <UsdValue.usd amount={argument(@operation, "stock_quote")} rate={@rate} />
                (estimate, not binding)
              </dd>
            </div>
            <div :if={argument(@operation, "min_stock_out")}>
              <dt>Least accepted</dt>
              <dd>
                {argument(@operation, "min_stock_out")} {argument(@operation, "currency_symbol")}
                <UsdValue.usd amount={argument(@operation, "min_stock_out")} rate={@rate} />
                · 1% below the estimate
              </dd>
            </div>
            <div :if={argument(@operation, "deadline")}>
              <dt>Valid until</dt><dd>{deadline(argument(@operation, "deadline"))}</dd>
            </div>
            <div>
              <dt>Effective tick price</dt>
              <dd>
                <AutolaunchWeb.TokenDisplay.price
                  amount={argument(@operation, "max_price")}
                  unit={"#{argument(@operation, "currency_symbol")} per token"}
                />
                <UsdValue.usd amount={argument(@operation, "max_price")} rate={@rate} per="per token" />
              </dd>
            </div>
            <div>
              <dt>Requested maximum</dt><dd>
                {requested_max_price(@operation)} {argument(@operation, "currency_symbol")} per token
                <UsdValue.usd amount={requested_max_price(@operation)} rate={@rate} per="per token" />
              </dd>
            </div>
            <div>
              <dt>Network</dt><dd>{Lab.network_name(@operation.envelope["chain_id"])}</dd>
            </div>
          </dl>

          <%!-- The list styling drops list semantics, so the role is stated. --%>
          <ol class="bid-steps" role="list" aria-label="Bid progress">
            <li :for={step <- BidActions.steps(@operation)} data-step={step["step"]}>
              <span>{step_label(step["step"], argument(@operation, "currency_symbol"))}</span>
              <span class="bid-step-state">{step_state(@operation, step["step"])}</span>
              <.transaction
                hash={BidActions.step_hash(@operation, step["step"])}
                chain_id={@operation.envelope["chain_id"]}
              />
            </li>
          </ol>

          <p :if={@operation.state == :confirmed} class="bid-settled" role="status">
            {confirmed_copy(@operation)}
          </p>
          <Regent.Primitives.button
            :if={sendable?(@operation, @wallet)}
            type="button"
            data-bid-send={@operation.action_id}
            data-wallet-step={@operation.step}
            data-bid-signer={@operation.signer}
          >
            Confirm in wallet
          </Regent.Primitives.button>
          <p :if={@operation.signer != @wallet && is_nil(@operation.terminal_at)} role="status">
            This bid belongs to another wallet. Switch back to it to finish.
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
            phx-click="cancel_bid_review"
            phx-value-action-id={@operation.action_id}
            phx-target={@myself}
            variant="secondary"
          >
            Cancel
          </Regent.Primitives.button>
          <Regent.Primitives.button
            :if={@operation.state in [:dispatched, :submitted]}
            type="button"
            phx-click="start_new_bid"
            phx-value-action-id={@operation.action_id}
            phx-target={@myself}
            variant="secondary"
          >
            Start a new bid
          </Regent.Primitives.button>
          <Regent.Primitives.button
            :if={@operation.terminal_at}
            type="button"
            phx-click="clear_bid"
            phx-target={@myself}
            variant="secondary"
          >
            Place another bid
          </Regent.Primitives.button>
        </section>
      </div>
      <AutolaunchWeb.WalletPressComponent.history
        :if={AutolaunchWeb.WalletPressComponent.scope(assigns)}
        history={@wallet_press_history}
        target={@myself}
        label={fn step, operation -> step_label(step, argument(operation, "currency_symbol")) end}
      />
    </section>
    """
  end

  # The wallet Privy has selected, whenever it changes.
  @impl true
  def handle_event("wallet_press_dispatch", params, socket),
    do:
      {:noreply,
       AutolaunchWeb.WalletPressComponent.dispatch(socket, :bid, params, opts(socket), __MODULE__)}

  def handle_event("wallet_press_report", params, socket),
    do:
      {:noreply,
       AutolaunchWeb.WalletPressComponent.report(socket, :bid, params, opts(socket), __MODULE__)}

  def handle_event("wallet_press_verify", params, socket),
    do:
      {:noreply,
       AutolaunchWeb.WalletPressComponent.verify(socket, :bid, params, opts(socket), __MODULE__)}

  def handle_event("bid_active_wallet", %{"address" => address}, socket),
    do: {:noreply, adopt(socket, address)}

  def handle_event("bid_form_changed", %{"amount" => amount, "max_price" => max_price}, socket) do
    {:noreply,
     socket |> assign(amount: amount, max_price: max_price, notice: nil) |> assign_estimate()}
  end

  def handle_event("fill_bid_amount", _params, socket) do
    {:noreply,
     socket
     |> assign(amount: balance(socket.assigns.balance, socket.assigns.auction), notice: nil)
     |> assign_estimate()}
  end

  def handle_event("review_bid", %{"amount" => amount, "max_price" => max_price}, socket) do
    {:noreply,
     socket.assigns.auction.id
     |> Autolaunch.prepare_bid(socket.assigns.wallet, amount, max_price, opts(socket))
     |> settled(assign(socket, amount: amount, max_price: max_price))}
  end

  def handle_event(
        "usdc_bid_form_changed",
        %{"usdc_amount" => amount, "max_price" => price},
        socket
      ),
      do: {:noreply, assign(socket, usdc_amount: amount, usdc_max_price: price, notice: nil)}

  def handle_event(
        "review_usdc_bid",
        %{"usdc_amount" => amount, "max_price" => max_price},
        socket
      ) do
    {:noreply,
     socket.assigns.auction.id
     |> Autolaunch.prepare_usdc_bid(socket.assigns.wallet, amount, max_price, opts(socket))
     |> settled(assign(socket, usdc_amount: amount, usdc_max_price: max_price))}
  end

  def handle_event("cancel_bid_review", %{"action-id" => action_id}, socket),
    do: {:noreply, action_id |> Autolaunch.cancel_bid_review(opts(socket)) |> settled(socket)}

  def handle_event("start_new_bid", %{"action-id" => action_id}, socket),
    do: {:noreply, action_id |> Autolaunch.start_new_bid(opts(socket)) |> settled(socket)}

  def handle_event("clear_bid", _params, socket),
    do:
      {:noreply,
       socket
       |> assign(
         operation: nil,
         amount: "",
         max_price: "",
         usdc_amount: "",
         usdc_max_price: "",
         estimate: nil
       )
       |> cleared()}

  attr :notice, :map, required: true

  defp notice(assigns) do
    ~H"""
    <p class="bid-notice" role={if @notice.tone == :error, do: "alert", else: "status"}>
      {@notice.message}
    </p>
    """
  end

  attr :hash, :string, default: nil
  attr :chain_id, :integer, default: @chain_id

  defp transaction(assigns) do
    ~H"""
    <a
      :if={@hash && @chain_id == 8453}
      class="bid-mono"
      href={"https://basescan.org/tx/#{@hash}"}
      target="_blank"
      rel="noopener"
      aria-label="View this transaction on Basescan"
    >
      {short_hash(@hash)}
    </a>
    <span :if={@hash && @chain_id == 31_337} class="bid-mono" data-local-transaction-hash>
      {short_hash(@hash)}
    </span>
    """
  end

  defp settled({:ok, %{operation: operation}}, socket),
    do: socket |> assign(operation: operation, notice: nil) |> published()

  defp settled({:error, error}, socket),
    do: assign(socket, notice: notice(:error, refusal(error)))

  # The one acknowledgement the browser waits for before it drops its own copy
  # of a reported hash: this exact hash is durable on this exact step.
  # The whole reviewed sequence, so the browser can check that what it is asked
  # to send really belongs to the operation it is holding.
  defp published(%{assigns: %{operation: nil}} = socket), do: cleared(socket)

  defp published(%{assigns: %{operation: operation}} = socket) do
    push_event(socket, "autolaunch-bid:operation", %{
      component_id: socket.assigns.id,
      action_id: operation.action_id,
      signer: operation.signer,
      chain_id: operation.envelope["chain_id"],
      lab: operation.envelope["metadata"]["lab"],
      lab_anchor: lab_anchor(operation.envelope),
      terminal: not is_nil(operation.terminal_at),
      steps: BidActions.steps(operation)
    })
  end

  defp lab_anchor(envelope),
    do: %{
      block_number: envelope["arguments"]["block_number"],
      block_hash: envelope["arguments"]["block_hash"]
    }

  defp cleared(socket), do: push_event(socket, "autolaunch-bid:cleared", %{})

  # No Ethereum wallet selected — disconnected, unlinked, or Solana in front of
  # the customer. That is the ordinary empty state, not a refusal, and it reads
  # nothing and says nothing.
  defp adopt(socket, nil), do: assign(socket, wallet: nil, balance: nil, notice: nil)

  defp adopt(socket, address) do
    case Autolaunch.bid_position(socket.assigns.auction.id, address, opts(socket)) do
      {:ok, %{signer: signer, balance: balance}} -> switched(socket, signer, balance)
      {:error, error} -> refused(socket, address, refusal(error))
    end
  end

  # A review is prepared for one signer, so another wallet cannot spend it and
  # it is withdrawn. Anything already claimed stays exactly where it is, bound
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
      {:ok, _cancelled} -> socket |> assign(operation: nil, estimate: nil) |> cleared()
      denied -> settled(denied, socket)
    end
  end

  # Membership is a session fact and a balance is a chain fact. Any wallet but
  # the signed-in one is not adopted at all; the signed-in one stays on
  # screen with the reason its position could not be read.
  defp refused(socket, _address, reason) when reason in @unheld,
    do: assign(socket, wallet: nil, balance: nil, notice: notice(:error, reason))

  defp refused(socket, address, reason),
    do: assign(socket, wallet: address, balance: nil, notice: notice(:info, reason))

  defp assign_estimate(%{assigns: %{amount: amount, max_price: max_price}} = socket) do
    case Autolaunch.quote_auction_bid(socket.assigns.auction.id, amount, max_price) do
      {:ok, %{estimated_tokens_if_end_now: estimate}} -> assign(socket, estimate: estimate)
      {:error, _incomplete} -> assign(socket, estimate: nil)
    end
  end

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

  defp started?(operation),
    do: Enum.any?(BidActions.steps(operation), &BidActions.step_hash(operation, &1["step"]))

  # Where the sequence has got to, read from the operation's own step and state.
  defp step_state(%{step: step} = operation, step_name) do
    cond do
      Atom.to_string(step) == step_name -> current_state(operation.state)
      BidActions.step_hash(operation, step_name) -> "Confirmed"
      true -> "Waiting"
    end
  end

  defp current_state(:prepared), do: "Ready"
  defp current_state(:dispatched), do: "In your wallet"
  defp current_state(:submitted), do: "Sent"
  defp current_state(:confirmed), do: "Confirmed"
  defp current_state(:cancelled), do: "Cancelled"
  defp current_state(:expired), do: "Expired"

  defp step_label("token_approval", symbol), do: "Allow #{symbol} to be spent"
  defp step_label("permit2_approval", symbol), do: "Allow this auction to draw #{symbol}"
  defp step_label("bid", _symbol), do: "Place the bid"
  defp step_label("usdc_approval", _symbol), do: "Allow USDC to be spent"
  defp step_label("usdc_bid", symbol), do: "Buy #{symbol} with USDC and place the bid"

  defp deadline(unix) when is_binary(unix) do
    unix
    |> String.to_integer()
    |> DateTime.from_unix!()
    |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
  end

  # USDC bids exist only for Stocks auctions, and only where the Stocks lab that
  # names the adapter is running.
  @doc "The currency a bidder pays this auction in: USDC where the auction takes it, else its own."
  def bid_currency(auction),
    do: if(usdc_bids?(auction), do: "USDC", else: auction.quote_token_symbol)

  defp usdc_bids?(%{kind: :stocks}), do: StocksLab.configured?()
  defp usdc_bids?(_auction), do: false

  # An amount chosen before the panel opened is entered once, in the form that
  # pays in the auction's bid currency.
  defp preset(%{assigns: %{preset_amount: amount, auction: auction}} = socket)
       when is_binary(amount) and not is_map_key(socket.assigns, :preset_entered?) do
    field = if usdc_bids?(auction), do: :usdc_amount, else: :amount
    assign(socket, [{field, amount}, {:preset_entered?, true}])
  end

  defp preset(socket), do: socket

  defp confirmed_copy(%{envelope: %{"chain_id" => chain_id}} = operation) do
    if Lab.test_chain?(chain_id),
      do:
        "Bid #{operation.onchain_bid_id} was verified on the fork. Test assets have no mainnet value.",
      else:
        "Bid #{operation.onchain_bid_id} is on Base. Your position appears once it is read back."
  end

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

  defp requested_max_price(operation),
    do: argument(operation, "requested_max_price") || argument(operation, "max_price")

  # The dollar price of the auction's currency, read once per auction and
  # apart from the form, so a slow price never holds a bid back.
  defp assign_usd_rate(%{assigns: %{auction: %{id: id}, usd_rate_for: id}} = socket), do: socket

  defp assign_usd_rate(%{assigns: %{auction: auction}} = socket) do
    socket
    |> assign(:usd_rate_for, auction.id)
    |> assign_async(:usd_rate, fn -> {:ok, %{usd_rate: UsdValue.rate(auction)}} end)
  end

  defp balance(nil, _auction), do: "—"

  defp balance(atomic, %{quote_token_decimals: decimals}),
    do: atomic |> String.to_integer() |> Autolaunch.bid_amount_units(decimals)

  defp short("0x" <> address),
    do: "0x#{String.slice(address, 0, 4)}…#{String.slice(address, -4, 4)}"

  defp short_hash("0x" <> hash),
    do: "0x#{String.slice(hash, 0, 6)}…#{String.slice(hash, -4, 4)}"
end
