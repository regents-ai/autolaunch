defmodule AutolaunchWeb.CoveredCallsLive do
  @moduledoc """
  `/covered-calls`: covered calls on a Base stock, in two tabs with an address
  each. **Sell**, first and at `/covered-calls`, is one form to lock stock and
  list calls on it, beside the guide. **Buy** (`?tab=buy`, with how many are for
  sale) lists the calls for sale, and a listing's panel opens below it at
  `?listing=<id>`. Every figure is read from the contract (`Autolaunch.CoveredCalls`);
  every press goes to the wallet through `AutolaunchWeb.CoveredCallComponent`.

  With covered calls switched off the address is the site's 404.
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [current_human_id: 1]

  alias Autolaunch.CoveredCalls
  alias Autolaunch.CoveredCalls.{Book, Chain, Deployment, Quote, Terms}
  alias AutolaunchWeb.CoveredCallComponent
  alias AutolaunchWeb.CoveredCallsFormat, as: F
  alias AutolaunchWeb.NotFoundError
  alias Phoenix.LiveView.AsyncResult
  alias Regent.Primitives, as: P

  # Strikes the Sell tab suggests, above the reference price, in percent.
  @suggested_strikes [1, 3, 5]

  def mount(_params, _session, socket) do
    with true <- Deployment.enabled?(),
         {:ok, %{chain_id: chain_id, markets: [market | _]}} <- Deployment.current() do
      if connected?(socket), do: Phoenix.PubSub.subscribe(Autolaunch.PubSub, topic(market))

      {:ok,
       socket
       |> assign(AutolaunchWeb.PublicDocuments.page("/covered-calls"))
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
         tab: :sell,
         selected: nil,
         done: nil,
         due: nil,
         sell: %{}
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

    # A shared link to one listing reads the market again unless it was read
    # in the last ten seconds, so it is never turned away on an old reading.
    # The List form is built anew on the Sell tab, so the guide starts from it again.
    socket =
      socket
      |> assign(tab: tab, selected: selected)
      |> then(&if(tab == socket.assigns.tab, do: &1, else: assign(&1, sell: %{})))

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

  # A suggested strike and its premium, put into the List form.
  def handle_event("use_suggestion", %{"strike" => strike, "premium" => premium}, socket) do
    send_update(CoveredCallComponent,
      id: "covered-call-list",
      fill: %{"strike" => strike, "premium" => premium}
    )

    {:noreply, socket}
  end

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

  # A listing's expiry or a scheduled multiplier change came: the shared book
  # is taken anew unless it was taken in the last ten seconds, and the page
  # and its panels read it, so a button the chain held back comes back.
  def handle_info(:covered_calls_due, socket) do
    Book.refresh(socket.assigns.chain_id)
    {:noreply, read_book(socket)}
  end

  # The List form changed: the guide follows the trade being made.
  def handle_info({:covered_call_form, inputs}, socket),
    do: {:noreply, assign(socket, sell: inputs)}

  # A panel's last step landed; the page says what moved.
  def handle_info({:covered_call_done, done}, socket), do: {:noreply, assign(socket, done: done)}

  def handle_async(:book, {:ok, {:ok, book}}, socket) do
    if socket.assigns.due, do: Process.cancel_timer(socket.assigns.due)

    open =
      for listing <- book.listings, Terms.stage(listing, book.now) == :open, do: listing.expiry

    wait = Terms.next_wait([book.effective_at | open], book.now)

    {:noreply,
     assign(socket,
       book: AsyncResult.ok(socket.assigns.book, book),
       due: wait && Process.send_after(self(), :covered_calls_due, (wait + 5) * 1_000)
     )}
  end

  def handle_async(:book, {:ok, {:error, error}}, socket),
    do:
      {:noreply,
       assign(socket, book: AsyncResult.failed(socket.assigns.book, CoveredCalls.reason(error)))}

  def handle_async(:book, {:exit, reason}, socket),
    do: {:noreply, assign(socket, book: AsyncResult.failed(socket.assigns.book, reason))}

  defp read_book(socket) do
    symbol = socket.assigns.market.symbol
    start_async(socket, :book, fn -> CoveredCalls.covered_call_book(symbol) end)
  end

  defp topic(market), do: "covered_calls:" <> market.symbol

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
          <h1>Covered calls on {@market.symbol}</h1>
          <p id="covered-calls-eligibility" class="covered-calls__eligibility">
            Available to
            <a href="https://www.coinbase.com/tokenize" target="_blank" rel="noopener">
              eligible people
            </a>
            outside the US.
          </p>
          <p>Earn USDC on your {@market.symbol}, or buy the right to own it at a set price.</p>
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

      <.summary :if={@reading} reading={@reading} open={@open} symbol={@market.symbol} />
      <.steps tab={@tab} symbol={@market.symbol} />

      <nav class="covered-calls__tabs" aria-label="Covered calls">
        <.link patch={~p"/covered-calls"} aria-current={@tab == :sell && "page"}>Sell calls</.link>
        <.link patch={~p"/covered-calls?tab=buy"} aria-current={@tab == :buy && "page"}>
          Buy calls <span :if={@reading} class="covered-calls__count">({length(@open)})</span>
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
        <h2 id="covered-calls-buy-title" class="covered-calls__title">Calls for sale</h2>
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
                    patch={~p"/covered-calls?listing=#{listing.id}"}
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
        <.buy_panel
          :for={listing <- @open}
          :if={@selected == listing.id}
          listing={listing}
          market={@market}
          unit={@reading.unit}
          session_lease={@session_lease}
          human_id={@human_id}
        />
        <div :if={@reading && @open == []} class="market-list__scroll market-list__empty">
          <h2>No calls for sale right now</h2>
          <p>New listings appear here as soon as a seller lists them.</p>
          <.link patch={~p"/covered-calls"} class="rg-button rg-button--secondary">
            Sell calls
          </.link>
        </div>
        <div :if={!@reading && !@book.failed} class="market-list__scroll" aria-busy="true">
          <span class="loading-block"></span>
        </div>
      </section>

      <section
        :if={@tab == :sell}
        class="covered-calls__section covered-calls__sell"
        aria-labelledby="covered-calls-sell-title"
      >
        <div class="covered-calls__form">
          <h2 id="covered-calls-sell-title" class="covered-calls__title">List calls</h2>
          <p class="covered-calls__note">
            Keep the premium either way. You keep any fall in {@market.symbol} and give up any rise
            above the strike.
          </p>
          <.live_component
            :if={@reading}
            module={CoveredCallComponent}
            id="covered-call-list"
            kind={:list}
            symbol={@market.symbol}
            unit={@reading.unit}
            expiries={Terms.expiries(@reading.now)}
            session_lease={@session_lease}
            current_human_id={@human_id}
          />
        </div>
        <aside :if={@reading} class="covered-calls__guide" aria-labelledby="covered-calls-guide-title">
          <h2 id="covered-calls-guide-title" class="covered-calls__title">Guide</h2>
          <.guide reading={@reading} symbol={@market.symbol} sell={@sell} />
        </aside>
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
        </dl>
        <p class="covered-calls__note covered-calls__panel-head">
          No owner. Nobody can change or upgrade it.
          <P.tip id="covered-calls-limits-tip" label="Limits">
            It holds each listing's {@market.symbol} until the buyer or the seller collects it.
            Coinbase controls {@market.symbol} and can pause or seize it, and buying stops while
            REGENT staking, which takes the 1% fee, is paused.
          </P.tip>
        </p>
      </section>
    </article>
    """
  end

  attr :listing, :map, required: true
  attr :market, :map, required: true
  attr :unit, :integer, required: true
  attr :session_lease, :any, required: true
  attr :human_id, :any, required: true

  # The chosen listing's Buy panel, under the list so it is never wider than the screen.
  defp buy_panel(assigns) do
    ~H"""
    <section class="covered-calls__panel" aria-labelledby={"covered-call-buy-#{@listing.id}-title"}>
      <div class="covered-calls__panel-head">
        <h3 id={"covered-call-buy-#{@listing.id}-title"}>Buy calls</h3>
        <P.tip id={"covered-call-buy-#{@listing.id}-tip"} label="About buying calls">
          You pay the premium now. Each call is then the right to buy one {@market.symbol} at the
          strike during the window. If you don't exercise, it lapses and the premium isn't returned.
        </P.tip>
      </div>
      <dl class="covered-calls__strip covered-calls__strip--panel">
        <div>
          <dt>Strike</dt>
          <dd>{F.usd(@listing.strike_per_token)}</dd>
        </div>
        <div>
          <dt>Premium</dt>
          <dd>{F.usd(@listing.premium_per_token)} <small>per {@market.symbol}</small></dd>
        </div>
        <div>
          <dt>Exercise window</dt>
          <dd>{F.window_days(@listing.expiry)} <small>21:00 UTC</small></dd>
        </div>
      </dl>
      <.live_component
        module={CoveredCallComponent}
        id={"covered-call-fill-#{@listing.id}"}
        kind={:fill}
        symbol={@market.symbol}
        unit={@unit}
        listing={@listing}
        session_lease={@session_lease}
        current_human_id={@human_id}
      />
    </section>
    """
  end

  attr :tab, :atom, required: true
  attr :symbol, :string, required: true

  # What a covered call is, for the side of it the tab is for.
  defp steps(%{tab: :sell} = assigns) do
    ~H"""
    <ol class="covered-calls__steps" aria-label="Steps">
      <li><strong>List</strong> <span>Lock {@symbol} at your strike and premium.</span></li>
      <li><strong>Earn</strong> <span>Buyers pay you the premium in USDC.</span></li>
      <li>
        <strong>Settle</strong> <span>Fri–Sat window: the buyer may exercise. Collect yours.</span>
      </li>
    </ol>
    """
  end

  defp steps(assigns) do
    ~H"""
    <ol class="covered-calls__steps" aria-label="Steps">
      <li><strong>Buy</strong> <span>Pay the premium in USDC.</span></li>
      <li><strong>Hold</strong> <span>The right to buy {@symbol} at the strike.</span></li>
      <li>
        <strong>Exercise</strong> <span>Fri–Sat window: pay the strike, collect {@symbol}.</span>
      </li>
    </ol>
    """
  end

  attr :reading, :map, required: true
  attr :open, :list, required: true
  attr :symbol, :string, required: true

  # The market's figures, one line each: the price, the next window, what is for sale, the fee.
  defp summary(%{reading: reading, open: open} = assigns) do
    assigns =
      assign(assigns,
        spot: spot(reading),
        next: hd(Terms.expiries(reading.now)),
        calls: length(open),
        tokens: open |> Enum.map(&Terms.available/1) |> Enum.sum() |> F.tokens(reading.unit)
      )

    ~H"""
    <dl class="covered-calls__strip" id="covered-calls-summary">
      <div>
        <dt>
          {@symbol} price
          <P.tip id="covered-calls-price-tip" label="About the price">
            Chainlink's AMZN feed on Base, {reference(@reading)}. A reference, not a price you can
            trade at.
          </P.tip>
        </dt>
        <dd>{if @spot, do: F.usd(@spot), else: "—"}</dd>
      </div>
      <div>
        <dt>Next window</dt>
        <dd>{F.window_days(@next)}</dd>
      </div>
      <div>
        <dt>For sale</dt>
        <dd>
          {@tokens} {@symbol}
          <small>{@calls} {if @calls == 1, do: "listing", else: "listings"}</small>
        </dd>
      </div>
      <div>
        <dt>Fee</dt>
        <dd>1% <small>of each premium</small></dd>
      </div>
    </dl>
    """
  end

  attr :reading, :map, required: true
  attr :symbol, :string, required: true
  attr :sell, :map, required: true

  # The guide follows the List form: suggested premiums for the window chosen,
  # the result at expiry of the strike and premium typed (an example from the
  # middle suggestion until both are), the reference price and its basis, then
  # the terms.
  defp guide(%{reading: reading, sell: sell} = assigns) do
    expiry = chosen_expiry(sell, Terms.expiries(reading.now))
    spot = spot(reading)
    rows = suggestions(spot, expiry, reading.now)
    trade = trade(sell, rows)

    assigns = assign(assigns, expiry: expiry, spot: spot, rows: rows, trade: trade)

    ~H"""
    <div :if={@trade && @spot} class="covered-calls__suggest" id="covered-calls-outcome">
      <div class="covered-calls__panel-head">
        <h3>{@trade.title}</h3>
        <P.tip id="covered-calls-outcome-tip" label="About the result">
          Per {@symbol} against the reference price, with the premium after the 1% fee, if the
          buyer exercises whenever the price is above the strike. Exercising, they pay the strike,
          which you collect, and the {@symbol} is theirs to collect. If they don't, you collect your {@symbol} after the window.
        </P.tip>
      </div>
      <p class="covered-calls__note">
        {F.usd(@trade.strike)} strike · {F.usd(@trade.premium)} premium per {@symbol}
      </p>
      <table class="covered-calls__mini">
        <caption class="visually-hidden">Result at expiry per {@symbol}</caption>
        <tbody>
          <tr :for={{label, price} <- outcomes(@spot)}>
            <th scope="row">{label} {F.usd(price)}</th>
            <td>
              {signed(
                Terms.payoff(price, @trade.strike, @trade.premium - Terms.fee(@trade.premium), @spot)
              )}
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <div :if={@rows != []} class="covered-calls__suggest" id="covered-calls-suggestions">
      <h3>Suggested premiums, {F.window_days(@expiry)}</h3>
      <table class="covered-calls__mini">
        <thead>
          <tr>
            <th scope="col">Strike</th>
            <th scope="col">Premium</th>
            <th scope="col"><span class="visually-hidden">Use</span></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows}>
            <td>{F.usd(row.strike)} <small>+{row.percent}%</small></td>
            <td>{F.usd(row.premium)}</td>
            <td>
              <button
                type="button"
                class="rg-button rg-button--secondary covered-calls__use"
                phx-click="use_suggestion"
                phx-value-strike={F.plain_usd(row.strike)}
                phx-value-premium={F.plain_usd(row.premium)}
                aria-label={"Use #{F.usd(row.strike)} strike and #{F.usd(row.premium)} premium"}
              >
                Use
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <p :if={@rows == []} class="covered-calls__note">
      No suggested premium right now: the reference price couldn't be read or is more than four
      days old.
    </p>

    <P.disclosure id="covered-calls-estimate" summary="Estimate" class="covered-calls__more">
      <p>
        A model estimate, not a market quote: a standard option price with an assumed {round(
          Quote.volatility() * 100
        )}% yearly volatility and no interest, counted to the
        window's close (Saturday 21:00 UTC). It starts from the reference price, Chainlink's feed
        for the stock on Base, {reference(@reading)}, which updates less often while the market is
        closed and is not a price you can trade at. You choose the premium.
      </p>
    </P.disclosure>

    <P.disclosure id="covered-calls-terms" summary="Terms" class="covered-calls__more">
      <ul class="covered-calls__terms">
        <li>
          Dividends during the week stay with the tokens: they raise each token's share count
          ({multiplier(@reading.multiplier)} shares per {@symbol} now), so they go to whoever ends
          up with the {@symbol}.
        </li>
        <li>
          Buyers can exercise for 24 hours from Friday 21:00 UTC. After that, on your portfolio,
          collect any {@symbol} the buyer didn't exercise.
        </li>
        <li>Strike payments wait in the contract until you collect them.</li>
        <li>1% of each premium goes to REGENT stakers.</li>
        <li>You can stop selling what hasn't sold at any time.</li>
      </ul>
    </P.disclosure>
    """
  end

  # The window the form has chosen, or the next one before it has.
  defp chosen_expiry(sell, [next | _later] = expiries) do
    case Integer.parse(sell["expiry"] || "") do
      {chosen, ""} -> if chosen in expiries, do: chosen, else: next
      _none -> next
    end
  end

  defp spot(reading) do
    case Quote.spot(reading) do
      {:ok, spot} -> spot
      {:error, :price_unavailable} -> nil
    end
  end

  defp suggestions(nil, _expiry, _now), do: []

  defp suggestions(spot, expiry, now) do
    for percent <- @suggested_strikes do
      strike = round_cents(spot * (100 + percent) / 100)
      # To the cent, as the form takes a premium.
      premium = max(round_cents(Quote.premium(spot, strike, expiry, now)), 10_000)
      %{percent: percent, strike: strike, premium: premium}
    end
  end

  # The strike and premium typed, or the middle suggestion as an example.
  defp trade(sell, rows) do
    case {F.parse_usd(sell["strike"] || ""), F.parse_usd(sell["premium"] || ""), rows} do
      {strike, premium, _rows} when is_integer(strike) and is_integer(premium) ->
        %{title: "Your trade", strike: strike, premium: premium}

      {_strike, _premium, [_low, middle | _high]} ->
        %{title: "Example", strike: middle.strike, premium: middle.premium}

      _no_price ->
        nil
    end
  end

  defp outcomes(spot),
    do: [
      {"Falls 20% to", round_cents(spot * 0.8)},
      {"Unchanged at", spot},
      {"Rises 20% to", round_cents(spot * 1.2)}
    ]

  defp signed(micro) when micro < 0, do: "−" <> F.usd(-micro)
  defp signed(micro), do: "+" <> F.usd(micro)

  defp reference(%{price: %{answer: answer, updated_at: at}, now: now}),
    do:
      "#{F.usd(div(answer, 100))} · #{at |> DateTime.from_unix!() |> Calendar.strftime("%-d %b, %H:%M UTC")}#{age(now - at)}"

  defp reference(_reading), do: "Not available"

  # How old the reference price is, once it is old enough to matter.
  defp age(seconds) when seconds >= 2 * 86_400, do: ", #{div(seconds, 86_400)} days ago"
  defp age(seconds) when seconds >= 2 * 3_600, do: ", #{div(seconds, 3_600)} hours ago"
  defp age(_seconds), do: ""

  defp multiplier(wad) do
    wad
    |> Decimal.new()
    |> Decimal.div(Decimal.new(1_000_000_000_000_000_000))
    |> Decimal.round(4)
    |> Decimal.to_string(:normal)
  end

  defp shares(raw, %{multiplier: wad, unit: unit}) do
    if wad == 1_000_000_000_000_000_000,
      do: nil,
      else: "#{F.tokens(Chain.shares(raw, wad), unit)} shares"
  end

  defp round_cents(micro), do: round(micro / 10_000) * 10_000
end
