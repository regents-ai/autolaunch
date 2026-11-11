defmodule AutolaunchWeb.CoveredCallsLive do
  @moduledoc """
  `/stock/covered-call`: covered calls on a Base stock as a trade ticket, in two tabs
  with an address each.

  **Sell**, first and at `/stock/covered-call`, takes an amount, one of the next four
  Fridays, a strike (three suggestions or a custom price) and a premium (the
  suggestion, or typed). Beside it a receipt and the three ways the listing can end
  follow the ticket as it changes. Every figure comes from the market's quote
  (`Autolaunch.CoveredCalls.covered_call_quote/3`), read again on each change; a
  receipt shows only once the quote answers for exactly what the ticket holds.

  **Buy** (`?tab=buy`, with how many are for sale) lists the calls for sale, and a
  listing's ticket opens below the list at `?listing=<id>`: the amount, what it costs
  and the three ways it can end, counted by `Autolaunch.CoveredCalls.Terms`.

  The page owns each ticket's fields; every press goes to the wallet through
  `AutolaunchWeb.CoveredCallComponent`, handed the ticket's order as it stands.

  With covered calls switched off the address is the site's 404.
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [current_human_id: 1]

  alias Autolaunch.CoveredCalls
  alias Autolaunch.CoveredCalls.{Book, Chain, Deployment, Quote, Terms}
  alias AutolaunchWeb.CoveredCallComponent
  alias AutolaunchWeb.CoveredCallsFormat, as: F
  alias AutolaunchWeb.{NotFoundError, Read}
  alias Phoenix.LiveView.{AsyncResult, JS}
  alias Regent.Primitives, as: P

  # A new Sell ticket: no amount yet, the next Friday, the middle suggested strike
  # (the quote's own choice when none is asked) and the suggested premium.
  @sell %{"amount" => "", "expiry" => nil, "strike" => "1", "custom" => "", "premium" => nil}
  @presets ~w(0 1 2)

  def mount(_params, _session, socket) do
    with true <- Deployment.enabled?(),
         {:ok, %{chain_id: chain_id, markets: [market | _]}} <- Deployment.current() do
      if connected?(socket), do: Phoenix.PubSub.subscribe(Autolaunch.PubSub, topic(market))

      {:ok,
       socket
       |> assign(AutolaunchWeb.PublicDocuments.page("/stock/covered-call"))
       |> assign(
         share:
           if(connected?(socket),
             do: nil,
             else: AutolaunchWeb.ShareCard.market_meta(:covered_calls, market.symbol)
           )
       )
       |> assign(
         market: market,
         chain_id: chain_id,
         book: AsyncResult.loading(),
         quote: %Read{},
         tab: :sell,
         selected: nil,
         done: nil,
         due: nil,
         sell: @sell,
         balance: nil,
         buy: nil
       )
       |> read_book()}
    else
      _off -> raise NotFoundError
    end
  end

  def handle_params(params, _uri, socket) do
    selected =
      case Integer.parse(params["listing"] || "") do
        {id, ""} when id > 0 -> id
        _none -> nil
      end

    # Selling comes first; a listing's own address opens it on the Buy tab.
    tab = if params["tab"] == "buy" or selected, do: :buy, else: :sell

    # Another listing's ticket starts at all that is left of it.
    # The wallet's stock is read by the Sell ticket's panel, so it is read anew
    # each time the ticket opens.
    socket =
      socket
      |> assign(tab: tab, selected: selected)
      |> then(&if(selected == socket.assigns.selected, do: &1, else: assign(&1, buy: nil)))
      |> then(&if(tab == :sell, do: &1, else: assign(&1, balance: nil)))
      |> read_quote()

    # A shared link to one listing reads the market again unless it was read
    # in the last ten seconds, so it is never turned away on an old reading.
    if selected && connected?(socket) do
      Book.refresh(socket.assigns.chain_id)
      {:noreply, read_book(socket)}
    else
      {:noreply, socket}
    end
  end

  # The Refresh press asks every reader of the chain to read again, so the
  # shared book is taken anew unless it was taken in the last ten seconds.
  def handle_event("refresh", _params, socket) do
    Autolaunch.ChainRefresh.request(socket.assigns.chain_id)
    {:noreply, read_book(socket)}
  end

  def handle_event("dismiss_done", _params, socket), do: {:noreply, assign(socket, done: nil)}

  # The Sell ticket's typed fields. The premium follows the suggestion until it
  # is typed in itself.
  def handle_event("sell", params, socket) do
    %{sell: sell} = socket.assigns
    premium = if params["_target"] == ["premium"], do: params["premium"], else: sell["premium"]
    sell = sell |> Map.merge(Map.take(params, ~w(amount custom))) |> Map.put("premium", premium)
    {:noreply, socket |> assign(sell: sell) |> read_quote()}
  end

  def handle_event("sell_expiry", %{"expiry" => expiry}, socket),
    do: {:noreply, socket |> update(:sell, &Map.put(&1, "expiry", expiry)) |> read_quote()}

  # Custom starts from the strike chosen before it, to change from there.
  def handle_event("sell_strike", %{"strike" => choice}, socket)
      when choice in ["custom" | @presets] do
    %{sell: sell, book: book, quote: quote} = socket.assigns
    ticket = ticket(sell, book.result, quote.value)

    custom =
      if choice == "custom" and sell["custom"] == "" and ticket.strike,
        do: F.plain_usd(ticket.strike),
        else: sell["custom"]

    {:noreply,
     socket |> assign(sell: %{sell | "strike" => choice, "custom" => custom}) |> read_quote()}
  end

  def handle_event("suggested_premium", _params, socket),
    do: {:noreply, socket |> update(:sell, &Map.put(&1, "premium", nil)) |> read_quote()}

  def handle_event("buy", %{"amount" => amount}, socket),
    do: {:noreply, assign(socket, buy: amount)}

  # A press landed here: every open page of this market hears which listing
  # and wallet.
  def handle_info({:covered_calls_changed, symbol, press}, socket) do
    Phoenix.PubSub.broadcast(
      Autolaunch.PubSub,
      "covered_calls:" <> symbol,
      {:covered_call_pressed, press}
    )

    {:noreply, socket}
  end

  def handle_info({:covered_call_pressed, _press}, socket), do: {:noreply, read_book(socket)}

  def handle_info({:covered_call_balance, _symbol, balance}, socket),
    do: {:noreply, assign(socket, balance: balance)}

  # A listing's expiry or a scheduled multiplier change came: the shared book
  # is taken anew unless it was taken in the last ten seconds, and the page
  # and its panels read it, so a button the chain held back comes back.
  def handle_info(:covered_calls_due, socket) do
    Book.refresh(socket.assigns.chain_id)
    {:noreply, read_book(socket)}
  end

  # A panel's last step landed; the page says what moved, and a listing made
  # leaves the Sell ticket ready for the next one on the same terms.
  def handle_info({:covered_call_done, done}, socket) do
    socket =
      case done.kind do
        :list -> socket |> update(:sell, &Map.put(&1, "amount", "")) |> read_quote()
        :fill -> assign(socket, buy: nil)
        _other -> socket
      end

    {:noreply, assign(socket, done: done)}
  end

  def handle_async(:book, {:ok, {:ok, book}}, socket) do
    if socket.assigns.due, do: Process.cancel_timer(socket.assigns.due)

    open =
      for listing <- book.listings, Terms.stage(listing, book.now) == :open, do: listing.expiry

    wait = Terms.next_wait([book.effective_at | open], book.now)

    {:noreply,
     socket
     |> assign(
       book: AsyncResult.ok(socket.assigns.book, book),
       due: wait && Process.send_after(self(), :covered_calls_due, (wait + 5) * 1_000)
     )
     |> read_quote()}
  end

  def handle_async(:book, {:ok, {:error, error}}, socket),
    do:
      {:noreply,
       assign(socket, book: AsyncResult.failed(socket.assigns.book, CoveredCalls.reason(error)))}

  def handle_async(:book, {:exit, reason}, socket),
    do: {:noreply, assign(socket, book: AsyncResult.failed(socket.assigns.book, reason))}

  # A quote that answered for other strikes than the ticket now names (the
  # reference price moved, and the suggestions with it) is read again for them.
  def handle_async({Read, :quote, _generation} = name, result, socket) do
    socket = Read.settle(socket, name, result)
    %{quote: quote, sell: sell, book: book} = socket.assigns

    if quote.state == :ready and
         !answers?(quote.value, request(ticket(sell, book.result, quote.value))),
       do: {:noreply, read_quote(socket)},
       else: {:noreply, socket}
  end

  defp read_book(socket) do
    symbol = socket.assigns.market.symbol
    start_async(socket, :book, fn -> CoveredCalls.covered_call_book(symbol) end)
  end

  # The Sell ticket's quote, for the ticket as it stands. The latest read wins.
  defp read_quote(%{assigns: %{tab: :sell, book: %AsyncResult{ok?: true, result: book}}} = socket) do
    %{market: %{symbol: symbol}, sell: sell, quote: quote} = socket.assigns
    asked = request(ticket(sell, book, quote.value))

    Read.start(socket, :quote, symbol, fn ->
      case CoveredCalls.covered_call_quote(symbol, asked, actor: nil) do
        {:ok, answer} -> {:ok, answer}
        {:error, error} -> {:error, CoveredCalls.reason(error)}
      end
    end)
  end

  defp read_quote(socket), do: socket

  defp topic(market), do: "covered_calls:" <> market.symbol

  # What the Sell ticket holds, read from its fields and the latest quote: the
  # expiry chosen (the next Friday until one is), the strike (a suggestion's,
  # or the custom price typed), the premium (typed, or the suggestion for that
  # strike and expiry), and the order once all of them and an amount read. The
  # receipt is the quote's only when the quote answered for exactly that order.
  defp ticket(sell, book, quote) do
    expiries = Terms.expiries(book.now)
    expiry = Enum.find(expiries, hd(expiries), &(Integer.to_string(&1) == sell["expiry"]))
    presets = quoted_presets(quote)
    amount = F.parse_tokens(sell["amount"], book.unit)
    {strike, suggested} = strike(sell, presets, priced(quote, expiry))
    {typed, premium} = premium(sell["premium"], suggested)
    order = order(amount, strike, premium, expiry)

    %{
      expiries: expiries,
      expiry: expiry,
      presets: presets,
      amount: amount,
      strike: strike,
      suggested: suggested,
      edited?: sell["premium"] != nil,
      typed: typed,
      premium: premium,
      order: order,
      value: value(amount, quote),
      receipt: receipt(order, quote),
      lead: lead(order, quote)
    }
  end

  # The typed amount's worth at the reference price, once the quote answered for it.
  defp value(amount, %{amount: amount, receipt: %{reference_value: value}})
       when is_integer(amount),
       do: value

  defp value(_amount, _quote), do: nil

  defp quoted_presets(nil), do: []
  defp quoted_presets(%{presets: presets}), do: presets

  # The quote prices the ticket only when it answered for the chosen expiry.
  defp priced(%{expiry: expiry} = quote, expiry), do: quote
  defp priced(_quote, _expiry), do: nil

  # The premium typed in, and the one the ticket uses: the typed one once
  # there is one, until then the suggestion.
  defp premium(nil, suggested), do: {nil, suggested}

  defp premium(field, _suggested) do
    typed = F.parse_usd(field)
    {typed, typed}
  end

  defp order(amount, strike, premium, _expiry)
       when is_nil(amount) or is_nil(strike) or is_nil(premium),
       do: nil

  defp order(amount, strike, premium, expiry),
    do: %{amount: amount, strike_per_token: strike, premium_per_token: premium, expiry: expiry}

  defp receipt(nil, _quote), do: nil
  defp receipt(order, quote), do: if(answers?(quote, order), do: quote.receipt)

  # Under You receive: what the seller keeps as a share of the stock's worth,
  # for the term to expiry.
  defp lead(order, quote) do
    case receipt(order, quote) do
      nil ->
        nil

      %{net_premium_yield: share} ->
        "#{:erlang.float_to_binary(share * 100, decimals: 2)}% · #{days(quote.term_days)}"
    end
  end

  defp days(1), do: "1 day"
  defp days(count), do: "#{count} days"

  # The strike chosen and the premium suggested for it at the chosen expiry,
  # once the quote has answered for that expiry (and, for a custom strike, for
  # that strike).
  defp strike(%{"strike" => "custom", "custom" => custom}, _presets, priced) do
    strike = F.parse_usd(custom)

    {strike,
     if(priced && priced.strike_per_token == strike, do: priced.suggested_premium_per_token)}
  end

  defp strike(%{"strike" => choice}, presets, priced) do
    index = String.to_integer(choice)

    case Enum.at(presets, index) do
      nil ->
        {nil, nil}

      preset ->
        {preset.strike_per_token,
         if(priced, do: Enum.at(priced.presets, index).suggested_premium_per_token)}
    end
  end

  # The quote's arguments for a ticket: what it holds so far. A premium is asked
  # for only once typed, so the quote suggests one for the strike.
  defp request(ticket) do
    [
      expiry: ticket.expiry,
      amount: ticket.amount,
      strike_per_token: ticket.strike,
      premium_per_token: ticket.typed
    ]
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Map.new()
  end

  # Whether a quote answered for every figure asked.
  defp answers?(nil, _asked), do: false
  defp answers?(quote, asked), do: Enum.all?(asked, fn {name, value} -> quote[name] == value end)

  def render(assigns) do
    book = assigns.book.result

    assigns =
      assign(assigns,
        reading: book,
        open:
          if(book,
            do: Enum.filter(book.listings, &(Terms.stage(&1, book.now) == :open)),
            else: []
          ),
        human_id: current_human_id(assigns.access_context)
      )

    ~H"""
    <article class="covered-calls">
      <CoveredCallComponent.toast
        :if={@done}
        id="covered-call-done"
        done={@done}
        dismiss="dismiss_done"
      />
      <header class="covered-calls__header">
        <div class="covered-calls__intro">
          <h1>Covered calls</h1>
          <p id="covered-calls-eligibility" class="covered-calls__eligibility">
            Available to
            <a href="https://www.coinbase.com/tokenize" target="_blank" rel="noopener">
              eligible people
            </a>
            outside the US.
          </p>
        </div>
        <div class="covered-calls__header-actions">
          <AutolaunchWeb.Components.ShareMarket.share_market
            id="covered-calls-share"
            kind={:covered_calls}
            subject={@market.symbol}
            account_control={@account_control}
          />
          <P.last_read
            id="covered-calls-read"
            at={@reading && @reading.read_at}
            phx-click="refresh"
            label="Read the listings again"
          />
        </div>
      </header>

      <nav
        id="covered-calls-tabs"
        class="covered-calls__tabs"
        aria-label="Covered calls"
        phx-hook="MotionTabs"
        data-active={@tab}
        data-variant={AutolaunchWeb.Motion.standard("tabs")}
      >
        <span
          id="covered-calls-tabs-ink"
          class="covered-calls__ink"
          data-ink
          aria-hidden="true"
          phx-mounted={JS.ignore_attributes(["style"])}
        ></span>
        <.link patch={~p"/stock/covered-call"} data-tab="sell" aria-current={@tab == :sell && "page"}>
          Sell
        </.link>
        <.link
          patch={~p"/stock/covered-call?tab=buy"}
          data-tab="buy"
          aria-current={@tab == :buy && "page"}
        >
          Buy <span :if={@reading} class="covered-calls__count">{length(@open)}</span>
        </.link>
        <.link :if={@human_id} navigate={~p"/portfolio"} class="covered-calls__mine">My calls</.link>
      </nav>

      <p :if={@book.failed} class="covered-calls__note" role="alert">
        The listings couldn't be read just now. Try again in a moment.
      </p>

      <section
        :if={@tab == :buy}
        class="covered-calls__section"
        aria-labelledby="covered-calls-buy-title"
      >
        <h2 id="covered-calls-buy-title" class="covered-calls__title">For sale</h2>
        <div :if={@open != []} class="market-list__scroll">
          <table class="market-list__table covered-calls__table">
            <caption class="visually-hidden">Calls for sale on {@market.symbol}</caption>
            <thead>
              <tr>
                <th scope="col">Strike</th>
                <th scope="col">Premium</th>
                <th scope="col">Exercise window</th>
                <th scope="col">Available</th>
                <th scope="col"><span class="visually-hidden">Buy</span></th>
              </tr>
            </thead>
            <tbody :for={listing <- @open} id={"covered-call-#{listing.id}"}>
              <tr class={@selected == listing.id && "covered-calls__chosen"}>
                <td data-label="Strike">{F.usd(listing.strike_per_token)}</td>
                <td data-label="Premium">
                  {F.usd(listing.premium_per_token)} <small>per {@market.symbol}</small>
                </td>
                <td data-label="Exercise window">{F.window_days(listing.expiry)}</td>
                <td data-label="Available">
                  {F.tokens(Terms.available(listing), @reading.unit)} {@market.symbol}
                  <small>{shares(Terms.available(listing), @reading)}</small>
                </td>
                <td class="covered-calls__row-action">
                  <.link
                    patch={~p"/stock/covered-call?listing=#{listing.id}"}
                    class="rg-button rg-button--secondary"
                    aria-expanded={to_string(@selected == listing.id)}
                  >
                    Buy
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p
          :if={@reading && @selected && !Enum.any?(@open, &(&1.id == @selected))}
          class="covered-calls__note"
          role="status"
        >
          Listing {@selected} isn't for sale now: it has sold out, passed its expiry or stopped
          selling.
        </p>
        <.buy_ticket
          :for={listing <- @open}
          :if={@selected == listing.id}
          listing={listing}
          market={@market}
          reading={@reading}
          typed={@buy}
          session_lease={@session_lease}
          human_id={@human_id}
        />
        <div :if={@reading && @open == []} class="market-list__scroll market-list__empty">
          <h2>No listings</h2>
          <.link patch={~p"/stock/covered-call"} class="rg-button rg-button--secondary">
            Sell calls
          </.link>
        </div>
        <div :if={!@reading && !@book.failed} class="market-list__scroll" aria-busy="true">
          <span class="loading-block"></span>
        </div>
      </section>

      <section :if={@tab == :sell} class="covered-calls__section" aria-label="Sell">
        <.sell_ticket
          :if={@reading}
          market={@market}
          reading={@reading}
          sell={@sell}
          quote={@quote}
          balance={@balance}
          session_lease={@session_lease}
          human_id={@human_id}
        />
        <div :if={!@reading && !@book.failed} class="covered-calls__waiting" aria-busy="true">
          <span class="loading-block"></span>
        </div>
      </section>

      <section class="covered-calls__section" aria-labelledby="covered-calls-contract-title">
        <h2 id="covered-calls-contract-title" class="covered-calls__title">Contract</h2>
        <dl class="covered-calls__facts covered-calls__contract">
          <dt>Covered calls</dt>
          <dd><P.address id="covered-calls-contract" address={@market.contract} /></dd>
          <dt>{@market.symbol}</dt>
          <dd><P.address id="covered-calls-stock" address={@market.stock} /></dd>
          <dt>Price feed</dt>
          <dd><P.address id="covered-calls-feed" address={@market.feed} /></dd>
          <dt>Code</dt>
          <dd>
            <a
              href={"https://basescan.org/address/#{@market.contract}#code"}
              target="_blank"
              rel="noopener"
            >
              Verified on Basescan
            </a>
          </dd>
          <dt>Owner</dt>
          <dd>None</dd>
          <dt>Upgrades</dt>
          <dd>None</dd>
          <dt>Issuer</dt>
          <dd>Coinbase can pause or seize {@market.symbol}</dd>
          <dt>Buying</dt>
          <dd>Stops while REGENT staking is paused</dd>
        </dl>
      </section>
    </article>
    """
  end

  attr :market, :map, required: true
  attr :reading, :map, required: true
  attr :sell, :map, required: true
  attr :quote, Read, required: true

  attr :balance, :integer,
    default: nil,
    doc: "the listing wallet's stock; nil signed out or unread"

  attr :session_lease, :any, required: true
  attr :human_id, :any, required: true

  # The Sell ticket: amount, expiry, strike and premium, then the wallet's
  # button, beside the receipt and the three ways the listing can end.
  defp sell_ticket(%{sell: sell, reading: reading, quote: quote} = assigns) do
    ticket = ticket(sell, reading, quote.value)
    spot = spot(reading)

    assigns =
      assign(assigns,
        t: ticket,
        symbol: assigns.market.symbol,
        unit: reading.unit,
        spot: spot,
        custom?: sell["strike"] == "custom",
        refused: if(quote.state in [:error, :stale], do: quote_refusal(quote.error))
      )

    ~H"""
    <Regent.Structure.panel id="covered-calls-sell" class="covered-calls__ticket">
      <div class="covered-calls__fields">
        <div class="covered-calls__market">
          <h2 class="covered-calls__title">{@symbol}</h2>
          <P.tip id="covered-calls-price-tip" class="covered-calls__spot">
            <:figure>{F.usd(@spot)}</:figure>
            {price_words(@reading, @symbol)}
          </P.tip>
        </div>

        <form id="covered-calls-sell-form" phx-change="sell" phx-submit="sell">
          <div class="covered-calls__field">
            <div class="covered-calls__label">
              <label for="covered-calls-sell-amount">Amount</label>
              <P.tip id="covered-calls-amount-tip" label="About the amount">
                Dividends during the week stay with the tokens: they raise each token's share
                count ({multiplier(@reading.multiplier)} shares per {@symbol} now), so they go to
                whoever ends up with the {@symbol}.
              </P.tip>
              <span :if={@balance} id="covered-calls-sell-balance" class="covered-calls__balance">
                <span class="visually-hidden">Balance</span>
                {F.tokens(@balance, @unit)} {@symbol}
                <button
                  id="covered-calls-sell-max"
                  type="button"
                  class="covered-calls__max"
                  phx-click={
                    JS.dispatch("autolaunch:fill",
                      to: "#covered-calls-sell-amount",
                      detail: %{value: F.tokens(@balance, @unit)}
                    )
                  }
                  disabled={@balance == 0}
                >
                  Max
                </button>
              </span>
            </div>
            <span class="covered-calls__input">
              <input
                id="covered-calls-sell-amount"
                name="amount"
                type="text"
                value={@sell["amount"]}
                inputmode="decimal"
                autocomplete="off"
                spellcheck="false"
                placeholder="0"
              />
              <span aria-hidden="true">{@symbol}</span>
            </span>
            <small id="covered-calls-sell-value" class="covered-calls__hint covered-calls__value">
              {amount_hint(@t, @reading)}
            </small>
          </div>

          <fieldset class="covered-calls__field">
            <legend class="covered-calls__label">
              <span id="covered-calls-sell-expiry-label">Expiry</span>
              <P.tip id="covered-calls-expiry-tip" label="About the expiry">
                Calls expire on a Friday at 21:00 UTC. The buyer can exercise for the 24 hours
                after.
              </P.tip>
            </legend>
            <.pills id="covered-calls-sell-expiry" active={@t.expiry}>
              <:pill
                :for={expiry <- @t.expiries}
                value={expiry}
                event="sell_expiry"
                name="expiry"
                label={F.window_days(expiry)}
              >
                {F.date(expiry)}
              </:pill>
            </.pills>
          </fieldset>

          <fieldset class="covered-calls__field">
            <legend class="covered-calls__label">
              <span>Strike</span>
              <P.tip id="covered-calls-strike-tip" label="About the strike">
                The price per {@symbol} the buyer pays if they exercise. Any rise above it goes
                to the buyer.
              </P.tip>
            </legend>
            <.pills id="covered-calls-sell-strike" active={@sell["strike"]}>
              <:pill
                :for={{choice, preset} <- presets(@t.presets)}
                value={choice}
                event="sell_strike"
                name="strike"
                disabled={is_nil(preset)}
              >
                <span>{F.usd(preset && preset.strike_per_token)}</span>
                <small>{above(preset)}</small>
              </:pill>
              <:pill value="custom" event="sell_strike" name="strike">Custom</:pill>
            </.pills>
            <span class="covered-calls__input covered-calls__custom" inert={!@custom?}>
              <input
                id="covered-calls-sell-custom"
                name="custom"
                type="text"
                value={@sell["custom"]}
                inputmode="decimal"
                autocomplete="off"
                spellcheck="false"
                placeholder="0.00"
                aria-label="Custom strike"
              />
              <span aria-hidden="true">USDC</span>
            </span>
          </fieldset>

          <div class="covered-calls__field">
            <div class="covered-calls__label">
              <label for="covered-calls-sell-premium">Premium</label>
              <P.tip id="covered-calls-premium-tip" label="About the premium">
                The suggestion is a standard option price with an assumed {round(
                  Quote.volatility() * 100
                )}% yearly volatility, counted to the window's close. You choose the premium.
              </P.tip>
              <button
                id="covered-calls-sell-suggested"
                type="button"
                class="covered-calls__suggested"
                phx-click="suggested_premium"
                inert={!suggest?(@t)}
              >
                Suggested {F.usd(@t.suggested)}
              </button>
            </div>
            <span class="covered-calls__input">
              <input
                id="covered-calls-sell-premium"
                name="premium"
                type="text"
                value={@sell["premium"] || (@t.suggested && F.plain_usd(@t.suggested))}
                inputmode="decimal"
                autocomplete="off"
                spellcheck="false"
                placeholder="0.00"
              />
              <span aria-hidden="true">per {@symbol}</span>
            </span>
          </div>
        </form>

        <.live_component
          module={CoveredCallComponent}
          id="covered-call-list"
          kind={:list}
          symbol={@symbol}
          unit={@unit}
          order={@t.order}
          session_lease={@session_lease}
          current_human_id={@human_id}
        />
      </div>

      <div
        id="covered-calls-sell-result"
        class="covered-calls__result"
        phx-hook="MotionCount"
        data-variant={AutolaunchWeb.Motion.standard("count")}
      >
        <section class="covered-calls__receipt" aria-labelledby="covered-calls-sell-receipt-title">
          <div class="covered-calls__label">
            <h3 id="covered-calls-sell-receipt-title">Receipt</h3>
            <P.tip id="covered-calls-receipt-tip" label="About the receipt">
              If all of it sells. Buyers can buy part, and you can stop selling the rest at any
              time. 1% of each premium goes to REGENT stakers. Strike payments wait in the
              contract until you collect them.
            </P.tip>
            <span class="covered-calls__status" role="status">{@refused}</span>
          </div>
          <dl id="covered-calls-sell-receipt" class="covered-calls__lines">
            <div>
              <dt>You receive</dt>
              <dd class="covered-calls__lead">
                <span id="covered-calls-sell-net" data-count>
                  {F.usd(@t.receipt && @t.receipt.net_premium)}
                </span>
                <small id="covered-calls-sell-yield">{@t.lead}</small>
              </dd>
            </div>
            <div>
              <dt>Fee</dt>
              <dd id="covered-calls-sell-fee" data-count>{F.usd(@t.receipt && @t.receipt.fee)}</dd>
            </div>
            <div>
              <dt>If exercised</dt>
              <dd id="covered-calls-sell-exercised" data-count>
                {F.usd(@t.receipt && @t.receipt.strike)}
              </dd>
            </div>
            <div>
              <dt>Opens</dt>
              <dd><.local_time id="covered-calls-sell-opens" at={@t.expiry} /></dd>
            </div>
            <div>
              <dt>Closes</dt>
              <dd>
                <.local_time id="covered-calls-sell-closes" at={@t.expiry + Terms.exercise_window()} />
              </dd>
            </div>
          </dl>
        </section>

        <ul id="covered-calls-sell-outcomes" class="covered-calls__outcomes" aria-label="Outcomes">
          <li id="covered-calls-sell-below">
            <strong>Below strike</strong>
            <span data-count>{F.usd(@t.receipt && @t.receipt.net_premium)}</span>
            <small>Keep the premium and your {yours(@t.amount, @unit, @symbol)}</small>
          </li>
          <li id="covered-calls-sell-above">
            <strong>Above strike</strong>
            <span data-count>
              {F.usd(@t.receipt && @t.receipt.strike + @t.receipt.net_premium)}
            </span>
            <small>Strike plus premium for your {yours(@t.amount, @unit, @symbol)}</small>
          </li>
          <li id="covered-calls-sell-unsold">
            <strong>Unsold</strong>
            <span data-count>{held(@t.amount, @unit, @symbol)}</span>
            <small>Take it back at any time</small>
          </li>
        </ul>
      </div>
    </Regent.Structure.panel>
    """
  end

  attr :listing, :map, required: true
  attr :market, :map, required: true
  attr :reading, :map, required: true
  attr :typed, :string, default: nil, doc: "the amount typed; nil for all that is left"
  attr :session_lease, :any, required: true
  attr :human_id, :any, required: true

  # The chosen listing's Buy ticket, under the list so it is never wider than
  # the screen: the amount, what it costs and how it can end, counted as the
  # contract counts them.
  defp buy_ticket(%{listing: listing, reading: reading, typed: typed} = assigns) do
    unit = reading.unit
    left = Terms.available(listing)
    amount = if typed, do: F.parse_tokens(typed, unit), else: left
    break_even = listing.strike_per_token + listing.premium_per_token

    assigns =
      assign(assigns,
        id: "covered-call-buy-#{listing.id}",
        symbol: assigns.market.symbol,
        unit: unit,
        value: typed || F.tokens(left, unit),
        left: F.tokens(left, unit),
        order: amount && %{listing_id: listing.id, amount: amount},
        pay: amount && Terms.usdc_for(amount, listing.premium_per_token, unit),
        break_even: break_even
      )

    ~H"""
    <Regent.Structure.panel id={@id} class="covered-calls__ticket" aria-labelledby={"#{@id}-title"}>
      <div class="covered-calls__fields">
        <div class="covered-calls__market">
          <h3 id={"#{@id}-title"} class="covered-calls__title">Buy calls</h3>
        </div>
        <form id={"#{@id}-form"} phx-change="buy" phx-submit="buy">
          <div class="covered-calls__field">
            <div class="covered-calls__label">
              <label for={"#{@id}-amount"}>Amount</label>
              <small class="covered-calls__hint">of {@left}</small>
            </div>
            <span class="covered-calls__input">
              <input
                id={"#{@id}-amount"}
                name="amount"
                type="text"
                value={@value}
                inputmode="decimal"
                autocomplete="off"
                spellcheck="false"
                placeholder="0"
              />
              <span aria-hidden="true">{@symbol}</span>
            </span>
          </div>
        </form>
        <.live_component
          module={CoveredCallComponent}
          id={"covered-call-fill-#{@listing.id}"}
          kind={:fill}
          symbol={@symbol}
          unit={@unit}
          listing={@listing}
          order={@order}
          session_lease={@session_lease}
          current_human_id={@human_id}
        />
      </div>

      <div
        id={"#{@id}-result"}
        class="covered-calls__result"
        phx-hook="MotionCount"
        data-variant={AutolaunchWeb.Motion.standard("count")}
      >
        <section class="covered-calls__receipt" aria-labelledby={"#{@id}-receipt-title"}>
          <div class="covered-calls__label">
            <h4 id={"#{@id}-receipt-title"}>Receipt</h4>
          </div>
          <dl id={"#{@id}-receipt"} class="covered-calls__lines">
            <div>
              <dt>You pay</dt>
              <dd id={"#{@id}-pay"} data-count>{if @pay, do: F.usd_due(@pay), else: F.usd(nil)}</dd>
            </div>
            <div>
              <dt>Strike</dt>
              <dd id={"#{@id}-strike"}>{F.usd(@listing.strike_per_token)}</dd>
            </div>
            <div>
              <dt>Break-even</dt>
              <dd id={"#{@id}-break-even"}>{F.usd(@break_even)}</dd>
            </div>
            <div>
              <dt>Opens</dt>
              <dd><.local_time id={"#{@id}-opens"} at={@listing.expiry} /></dd>
            </div>
            <div>
              <dt>Closes</dt>
              <dd>
                <.local_time id={"#{@id}-closes"} at={@listing.expiry + Terms.exercise_window()} />
              </dd>
            </div>
          </dl>
        </section>

        <ul id={"#{@id}-outcomes"} class="covered-calls__outcomes" aria-label="Outcomes">
          <li>
            <strong>Above break-even</strong>
            <span>Over {F.usd(@break_even)}</span>
            <small>Exercise for a profit</small>
          </li>
          <li>
            <strong>In between</strong>
            <span>{F.usd(@listing.strike_per_token)} – {F.usd(@break_even)}</span>
            <small>Exercise to win back part of the premium</small>
          </li>
          <li>
            <strong>Below strike</strong>
            <span>Under {F.usd(@listing.strike_per_token)}</span>
            <small>Let it lapse; the premium is spent</small>
          </li>
        </ul>
      </div>
    </Regent.Structure.panel>
    """
  end

  attr :id, :string, required: true
  attr :active, :any, required: true, doc: "the value chosen"

  slot :pill, required: true do
    attr :value, :any, required: true
    attr :event, :string, required: true
    attr :name, :string, required: true, doc: "the event's value name"
    attr :label, :string, doc: "the choice's name when its words are short"
    attr :disabled, :boolean
  end

  # One choice of a few, side by side, the chosen one marked by a block that
  # travels to it (`MotionTabs`). Each choice is a button the page hears.
  defp pills(assigns) do
    ~H"""
    <div
      id={@id}
      class="covered-calls__pills"
      role="group"
      phx-hook="MotionTabs"
      data-active={@active}
      data-variant={AutolaunchWeb.Motion.standard("tabs")}
      style={"--pills: #{length(@pill)}"}
    >
      <span
        id={"#{@id}-ink"}
        class="covered-calls__pill-ink"
        data-ink
        aria-hidden="true"
        phx-mounted={JS.ignore_attributes(["style"])}
      ></span>
      <button
        :for={pill <- @pill}
        type="button"
        data-tab={pill.value}
        aria-pressed={to_string(to_string(pill.value) == to_string(@active))}
        aria-label={pill[:label]}
        disabled={pill[:disabled]}
        phx-click={pill.event}
        {%{"phx-value-#{pill.name}" => pill.value}}
      >
        {render_slot(pill)}
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :at, :integer, required: true

  # A time in the reader's own time zone once the page is live (`LocalTime`),
  # with the time in UTC, the time the contract keeps, beside it.
  defp local_time(assigns) do
    ~H"""
    <time
      id={@id}
      class="covered-calls__local"
      datetime={@at |> DateTime.from_unix!() |> DateTime.to_iso8601()}
      phx-hook="LocalTime"
      phx-mounted={JS.ignore_attributes(["data-local"])}
    >{F.expiry(@at)}</time><small class="covered-calls__utc">{F.utc_time(@at)}</small>
    """
  end

  # The three suggestions by their place, or empty places until the quote is in.
  defp presets([_, _, _] = presets), do: Enum.zip(@presets, presets)
  defp presets(_none), do: Enum.map(@presets, &{&1, nil})

  defp above(nil), do: "—"

  defp above(preset),
    do: "+#{:erlang.float_to_binary(preset.above_reference * 100, decimals: 1)}%"

  # The way back to the suggestion, once a different premium is typed.
  defp suggest?(%{edited?: edited?, typed: typed, suggested: suggested}),
    do: edited? and is_integer(suggested) and typed != suggested

  defp held(nil, _unit, _symbol), do: "—"
  defp held(amount, unit, symbol), do: "#{F.tokens(amount, unit)} #{symbol}"

  defp yours(nil, _unit, symbol), do: symbol
  defp yours(amount, unit, symbol), do: held(amount, unit, symbol)

  defp quote_refusal(:price_unavailable), do: "No reference price right now"
  defp quote_refusal(_unavailable), do: "The price couldn't be read"

  defp spot(reading) do
    case Quote.spot(reading) do
      {:ok, spot} -> spot
      {:error, :price_unavailable} -> nil
    end
  end

  defp price_words(%{price: %{updated_at: at}, now: now} = reading, symbol) do
    if spot(reading),
      do:
        "Chainlink's price for #{symbol} on Base, #{age(now - at)}. A reference, not a price you can trade at.",
      else: "Chainlink's price for #{symbol} on Base is more than four days old."
  end

  defp price_words(_reading, symbol),
    do: "Chainlink's price for #{symbol} on Base couldn't be read just now."

  defp age(seconds) when seconds >= 2 * 86_400, do: "updated #{div(seconds, 86_400)} days ago"
  defp age(seconds) when seconds >= 2 * 3_600, do: "updated #{div(seconds, 3_600)} hours ago"
  defp age(_seconds), do: "updated in the last two hours"

  defp multiplier(wad) do
    wad
    |> Decimal.new()
    |> Decimal.div(Decimal.new(1_000_000_000_000_000_000))
    |> Decimal.round(4)
    |> Decimal.to_string(:normal)
  end

  defp shares?(%{multiplier: wad}), do: wad != 1_000_000_000_000_000_000

  # Under the amount: its worth at the reference price, and its share count
  # when a token is more than one share.
  defp amount_hint(%{amount: nil}, _reading), do: nil

  defp amount_hint(%{amount: amount, value: value}, reading) do
    worth = if value, do: "≈ #{F.usd(value)}"
    Enum.join(Enum.reject([worth, shares(amount, reading)], &is_nil/1), " · ")
  end

  defp shares(raw, %{multiplier: wad, unit: unit} = reading) do
    if shares?(reading), do: "#{F.tokens(Chain.shares(raw, wad), unit)} shares"
  end
end
