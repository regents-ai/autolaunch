defmodule AutolaunchWeb.CoveredCallsLive do
  @moduledoc """
  `/covered-calls`: covered calls on a Base stock, in two tabs that share one
  address each. **Buy** lists the calls for sale, and a listing's panel opens
  below it at `?listing=<id>`. **Sell** is one form to lock stock and list calls
  on it, beside the reference price, a suggested premium and the outcome at
  expiry. Every figure is read from the contract (`Autolaunch.CoveredCalls`);
  every press goes to the wallet through `AutolaunchWeb.CoveredCallComponent`.

  With covered calls switched off the address is the site's 404.
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [current_human_id: 1]

  alias Autolaunch.CoveredCalls
  alias Autolaunch.CoveredCalls.{Chain, Deployment, Terms}
  alias AutolaunchWeb.CoveredCallComponent
  alias AutolaunchWeb.CoveredCallsFormat, as: F
  alias AutolaunchWeb.NotFoundError
  alias Phoenix.LiveView.AsyncResult
  alias Regent.Primitives, as: P

  # Strikes the Sell tab suggests, above the reference price, in percent.
  @suggested_strikes [1, 3, 5]

  def mount(_params, _session, socket) do
    with true <- Deployment.enabled?(),
         {:ok, %{markets: [market | _]}} <- Deployment.current() do
      if connected?(socket), do: Phoenix.PubSub.subscribe(Autolaunch.PubSub, topic(market))

      {:ok,
       socket
       |> assign(AutolaunchWeb.PublicDocuments.page("/covered-calls"))
       |> assign(market: market, book: AsyncResult.loading(), tab: :buy, selected: nil, done: nil)
       |> read_book()}
    else
      _off -> raise NotFoundError
    end
  end

  def handle_params(params, _uri, socket) do
    tab = if params["tab"] == "sell", do: :sell, else: :buy

    selected =
      case Integer.parse(params["listing"] || "") do
        {id, ""} when id > 0 -> id
        _none -> nil
      end

    {:noreply, assign(socket, tab: tab, selected: selected)}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, read_book(socket)}
  def handle_event("dismiss_done", _params, socket), do: {:noreply, assign(socket, done: nil)}

  # A press landed here: every open page of this market reads it again.
  def handle_info({:covered_calls_changed, symbol}, socket) do
    Phoenix.PubSub.broadcast(Autolaunch.PubSub, "covered_calls:" <> symbol, :read_again)
    {:noreply, socket}
  end

  def handle_info(:read_again, socket), do: {:noreply, read_book(socket)}

  # A panel's last step landed; the page says what moved.
  def handle_info({:covered_call_done, done}, socket), do: {:noreply, assign(socket, done: done)}

  def handle_async(:book, {:ok, {:ok, book}}, socket),
    do: {:noreply, assign(socket, book: AsyncResult.ok(socket.assigns.book, book))}

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
            Available to eligible people outside the US.
          </p>
          <p>
            Sell someone the right to buy your {@market.symbol} at a set price until Friday's close,
            and keep the premium they pay. Or buy that right. Paid in USDC on Base.
          </p>
        </div>
        <P.last_read
          id="covered-calls-read"
          at={@reading && @reading.read_at}
          phx-click="refresh"
          label="Read the listings again"
        />
      </header>

      <nav class="covered-calls__tabs" aria-label="Covered calls">
        <.link patch={~p"/covered-calls"} aria-current={@tab == :buy && "page"}>Buy calls</.link>
        <.link patch={~p"/covered-calls?tab=sell"} aria-current={@tab == :sell && "page"}>
          Sell calls
        </.link>
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
                <th scope="col">Expiry</th>
                <th scope="col">Available</th>
                <th scope="col"><span class="visually-hidden">Buy</span></th>
              </tr>
            </thead>
            <tbody :for={listing <- @open} id={"covered-call-#{listing.id}"}>
              <tr>
                <td data-label="Strike">{F.usd(listing.strike_per_token)}</td>
                <td data-label="Premium">
                  {F.usd(listing.premium_per_token)} <small>per {@market.symbol}</small>
                </td>
                <td data-label="Expiry">{F.expiry(listing.expiry)}</td>
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
          <.link patch={~p"/covered-calls?tab=sell"} class="rg-button rg-button--secondary">
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
          <dl class="covered-calls__facts">
            <dt>Reference price</dt>
            <dd>{reference(@reading)}</dd>
            <dt>Shares per {@market.symbol}</dt>
            <dd>{multiplier(@reading.multiplier)}</dd>
          </dl>
          <.suggestions reading={@reading} symbol={@market.symbol} />
          <ul class="covered-calls__terms">
            <li>Dividends during the week stay with the tokens.</li>
            <li>
              Buyers can exercise for 24 hours from Friday 21:00 UTC. Whatever isn't exercised comes
              back to you after that.
            </li>
            <li>1% of each premium goes to REGENT stakers.</li>
            <li>You can stop selling what hasn't sold at any time.</li>
          </ul>
        </aside>
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
      <h3 id={"covered-call-buy-#{@listing.id}-title"}>
        Buy calls at {F.usd(@listing.strike_per_token)}, {F.expiry(@listing.expiry)}
      </h3>
      <p class="covered-calls__note">
        Each call lets you buy {@market.symbol} at {F.usd(@listing.strike_per_token)} from {F.expiry(
          @listing.expiry
        )} until {F.window_closes(@listing.expiry)}. You can let it lapse.
      </p>
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

  attr :reading, :map, required: true
  attr :symbol, :string, required: true

  # Suggested premiums for the next expiry at a few strikes above the reference
  # price, and what a seller ends with at expiry for the middle one.
  defp suggestions(%{reading: %{price: %{answer: answer}} = reading} = assigns) do
    spot = div(answer, 100)
    expiry = hd(Terms.expiries(reading.now))

    rows =
      for percent <- @suggested_strikes do
        strike = round_cents(spot * (100 + percent) / 100)
        premium = Terms.suggested_premium(spot, strike, expiry, reading.now, 0.30)
        %{percent: percent, strike: strike, premium: premium}
      end

    middle = Enum.at(rows, 1)

    assigns =
      assign(assigns,
        rows: rows,
        expiry: expiry,
        spot: spot,
        middle: middle,
        outcomes: [
          {"Falls 20%", round_cents(spot * 0.8)},
          {"Unchanged", spot},
          {"Rises 20%", round_cents(spot * 1.2)}
        ]
      )

    ~H"""
    <div class="covered-calls__suggest">
      <h3>Suggested premiums for {F.expiry(@expiry)}</h3>
      <table class="covered-calls__mini">
        <thead>
          <tr>
            <th scope="col">Strike</th><th scope="col">Premium per {@symbol}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows}>
            <td>{F.usd(row.strike)} <small>+{row.percent}%</small></td>
            <td>{F.usd(row.premium)}</td>
          </tr>
        </tbody>
      </table>
      <p class="covered-calls__note">A guide only. You choose the premium.</p>
      <h3>Result at expiry per {@symbol}, {F.usd(@middle.strike)} strike</h3>
      <table class="covered-calls__mini">
        <tbody>
          <tr :for={{label, price} <- @outcomes}>
            <th scope="row">{label} to {F.usd(price)}</th>
            <td>{signed(Terms.payoff(price, @middle.strike, @middle.premium, @spot))}</td>
          </tr>
        </tbody>
      </table>
      <p class="covered-calls__note">
        Against today's price, premium included. Above the strike your {@symbol} is sold at the
        strike; below it you keep your {@symbol}.
      </p>
    </div>
    """
  end

  defp suggestions(assigns) do
    ~H"""
    <p class="covered-calls__note">
      No suggested premium right now: the reference price hasn't updated recently.
    </p>
    """
  end

  defp signed(micro) when micro < 0, do: "−" <> F.usd(-micro)
  defp signed(micro), do: "+" <> F.usd(micro)

  defp reference(%{price: %{answer: answer, updated_at: at}}),
    do:
      "#{F.usd(div(answer, 100))} · #{at |> DateTime.from_unix!() |> Calendar.strftime("%-d %b, %H:%M UTC")}"

  defp reference(_reading), do: "Not available"

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
