defmodule AutolaunchWeb.ExposureLive do
  @moduledoc """
  `/after-hour-stocks`: Isolated Exposure to After-hours Stocks on a Base stock.
  One series at a time, the newest unless `?series=<address>` names another the
  site offers, picked by name at the top: its two tokens with their recorded
  ledger, stock claim and leverage, panels to split the stock and redeem tokens,
  the prices it has applied, and, under Series details, its addresses and the
  panels anyone may use to record and apply prices or end it after a missing
  one. Every figure is read from the chain (`Autolaunch.Exposure`); every press
  goes to the wallet through `AutolaunchWeb.ExposureComponent`.

  With Exposure switched off the address is the site's 404.
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [current_human_id: 1]
  import AutolaunchWeb.Components.PriceChart, only: [price_chart: 1]

  alias Autolaunch.Exposure
  alias Autolaunch.Exposure.{Chain, Deployment}
  alias AutolaunchWeb.ExposureComponent
  alias AutolaunchWeb.ExposureFormat, as: F
  alias AutolaunchWeb.NotFoundError
  alias AutolaunchWeb.ShareCard
  alias Phoenix.LiveView.AsyncResult
  alias Regent.Primitives, as: P

  @long_wait 10 * 60_000
  @tabs %{"buy" => :buy, "sell" => :sell, "split" => :mint, "redeem" => :redeem}

  def mount(params, _session, socket) do
    with true <- Deployment.enabled?(),
         {:ok, config} <- Deployment.current() do
      share =
        if connected?(socket),
          do: nil,
          else: ShareCard.market_meta(:exposure, shown(params, config.series))

      {:ok,
       socket
       |> assign(AutolaunchWeb.PublicDocuments.page("/after-hour-stocks"))
       |> assign(share: share, catalog: %{}, next_read: nil, done: nil)
       |> assign(all: config.series, address: nil, reading: AsyncResult.loading())
       |> assign(tab: nil, leg: nil)}
    else
      _off -> raise NotFoundError
    end
  end

  def handle_params(params, _uri, socket) do
    address = shown(params, socket.assigns.all)

    socket =
      assign(socket,
        tab: Map.get(@tabs, params["tab"]),
        leg: Map.get(%{"after-hours" => :overnight, "market-hours" => :session}, params["leg"])
      )

    if address == socket.assigns.address,
      do: {:noreply, socket},
      else: {:noreply, follow(socket, address)}
  end

  # The series `?series=` names when the site offers it, else the newest.
  defp shown(params, all) do
    case Deployment.series(params["series"]) do
      {:ok, address} -> address
      {:error, _unknown} -> List.last(all)
    end
  end

  # Another series: the page hears its changes instead of the last one's, and reads it.
  defp follow(socket, address) do
    if connected?(socket) do
      if socket.assigns.address,
        do: Phoenix.PubSub.unsubscribe(Autolaunch.PubSub, topic(socket.assigns.address))

      Phoenix.PubSub.subscribe(Autolaunch.PubSub, topic(address))
    end

    socket
    |> assign(address: address, reading: AsyncResult.loading())
    |> read_series()
  end

  def handle_event("refresh", _params, socket), do: {:noreply, read_series(socket)}

  def handle_event("dismiss_done", _params, socket), do: {:noreply, assign(socket, done: nil)}

  def handle_event("tab", %{"tab" => tab}, socket) when is_map_key(@tabs, tab) do
    %{reading: reading, leg: leg, all: all} = socket.assigns
    {:noreply, push_patch(socket, to: tab_path(reading.result, Map.fetch!(@tabs, tab), leg, all))}
  end

  def handle_event("leg", %{"leg" => leg}, socket) when leg in ["after-hours", "market-hours"] do
    %{reading: reading, tab: tab, all: all} = socket.assigns
    leg = if leg == "market-hours", do: :session, else: :overnight
    tab = tab || default_tab(reading.result)
    {:noreply, push_patch(socket, to: tab_path(reading.result, tab, leg, all))}
  end

  # A press landed here: every open page of this series reads it again.
  def handle_info({:exposure_changed, address}, socket) do
    Phoenix.PubSub.broadcast(Autolaunch.PubSub, topic(address), :read_again)
    {:noreply, socket}
  end

  def handle_info(:read_again, socket), do: {:noreply, read_series(socket)}

  def handle_info({:exposure_done, done}, socket), do: {:noreply, assign(socket, done: done)}

  def handle_info({:read_when_due, ref}, %{assigns: %{next_read: ref}} = socket),
    do: {:noreply, read_series(socket)}

  def handle_info({:read_when_due, _older}, socket), do: {:noreply, socket}

  def handle_async(:series, {:ok, {address, {:ok, series}}}, socket) do
    if address == socket.assigns.address,
      do:
        {:noreply,
         socket
         |> assign(reading: AsyncResult.ok(socket.assigns.reading, series))
         |> read_when_due(series)},
      else: {:noreply, socket}
  end

  def handle_async(:series, {:ok, {address, {:error, error}}}, socket) do
    if address == socket.assigns.address,
      do:
        {:noreply,
         assign(socket,
           reading: AsyncResult.failed(socket.assigns.reading, Exposure.reason(error))
         )},
      else: {:noreply, socket}
  end

  def handle_async(:series, {:exit, reason}, socket),
    do: {:noreply, assign(socket, reading: AsyncResult.failed(socket.assigns.reading, reason))}

  # Every series by name for the picker, read again with the shown series; one
  # not read yet keeps its short address, so no series is ever out of reach.
  def handle_async(:catalog, {:ok, {:ok, all}}, socket),
    do: {:noreply, assign(socket, catalog: Map.new(all, &{&1.address, name(&1)}))}

  def handle_async(:catalog, _unread, socket), do: {:noreply, socket}

  defp read_series(socket) do
    address = socket.assigns.address

    socket
    |> start_async(:series, fn -> {address, Exposure.exposure_series(address)} end)
    |> read_catalog()
  end

  defp read_catalog(%{assigns: %{all: [_, _ | _]}} = socket) do
    if connected?(socket),
      do: start_async(socket, :catalog, fn -> Exposure.exposure_series_list() end),
      else: socket
  end

  defp read_catalog(socket), do: socket

  # The page reads the series again when its next price becomes recordable and
  # when its deadline passes, so the summary never goes stale while it is open.
  # Only the newest timer counts.
  defp read_when_due(socket, %{next: %{recordable_at: recordable, deadline: deadline}, now: now}) do
    case Enum.find([recordable, deadline + 1], &(&1 > now)) do
      nil ->
        socket

      at ->
        ref = make_ref()
        wait = min((at - now) * 1_000 + 2_000, @long_wait)
        Process.send_after(self(), {:read_when_due, ref}, wait)
        assign(socket, next_read: ref)
    end
  end

  defp read_when_due(socket, _series), do: socket

  defp topic(address), do: "exposure:" <> address

  def render(assigns) do
    series = assigns.reading.result

    assigns =
      assign(assigns,
        series: series,
        human_id: current_human_id(assigns.access_context),
        active: assigns.tab || default_tab(series),
        leg: assigns.leg || default_leg(series)
      )

    ~H"""
    <article class="exposure">
      <ExposureComponent.toast :if={@done} id="exposure-done" done={@done} dismiss="dismiss_done" />
      <header class="exposure__header">
        <div class="exposure__intro">
          <h1>Isolated Exposure to After-hours Stocks</h1>
          <p>
            Split a stock token into two for a fixed term. After-hours carries the stock's moves
            while the market is closed, from each close to the next open. Market-hours carries its
            moves while the market is open. While the series runs, one of each redeems for one
            stock token, within the issuer's controls described in the terms.
          </p>
          <p id="exposure-eligibility" class="exposure__muted">
            Available to eligible people outside the US.
          </p>
        </div>
        <AutolaunchWeb.Components.ShareMarket.share_market
          :if={@address}
          id="exposure-share"
          kind={:exposure}
          subject={@address}
          account_control={@account_control}
        />
        <P.last_read
          id="exposure-read"
          at={@series && @series.read_at}
          phx-click="refresh"
          label="Read the series again"
        />
      </header>

      <nav
        :if={match?([_, _ | _], @all)}
        id="exposure-series"
        class="exposure__picker"
        aria-label="Series"
      >
        <.link
          :for={address <- Enum.reverse(@all)}
          id={"exposure-series-#{address}"}
          patch={~p"/after-hour-stocks?#{[series: address]}"}
          class="exposure__pick"
          aria-current={address == @address && "page"}
        >
          {@catalog[address] || short_address(address)}
        </.link>
      </nav>

      <p :if={@reading.failed} class="exposure__muted" role="alert">
        The series couldn't be read just now. Try again in a moment.
      </p>
      <div :if={!@series && !@reading.failed} class="exposure__loading" aria-busy="true">
        <span class="loading-block"></span>
      </div>

      <%= if @series do %>
        <section class="exposure__summary" aria-label="Series">
          <dl class="exposure__facts">
            <div>
              <dt>Stock</dt>
              <dd>{@series.stock.symbol}</dd>
            </div>
            <div>
              <dt>Term</dt>
              <dd>{term(@series)}</dd>
            </div>
            <div>
              <dt>Status</dt>
              <dd>{status(@series)}</dd>
            </div>
            <div>
              <dt>Deposited</dt>
              <dd>
                {F.tokens(@series.accounted, @series.stock.decimals)} of {F.tokens(
                  @series.deposit_cap,
                  @series.stock.decimals
                )} {@series.stock.symbol}
              </dd>
            </div>
            <div>
              <dt>{@series.stock.symbol} price</dt>
              <dd>{if @series.settled > 0, do: F.usd(@series.price), else: "Not set yet"}</dd>
            </div>
            <div :if={@series.next}>
              <dt>Next price</dt>
              <dd id="exposure-next">{next_price(@series)}</dd>
            </div>
          </dl>
        </section>

        <section class="exposure__section" aria-labelledby="exposure-tokens-title">
          <h2 id="exposure-tokens-title" class="exposure__title">Tokens</h2>
          <p
            :if={@series.settled == 0 and @series.status != :ended}
            id="exposure-pending"
            class="exposure__pending"
          >
            Allocations are set when the first closing price is applied.
          </p>
          <p
            :if={@series.settled == 0 and @series.status == :ended}
            id="exposure-pending"
            class="exposure__pending"
          >
            This series ended before its first price, so no tokens were made.
          </p>
          <div
            id="exposure-legs"
            class="exposure__legs"
            phx-hook="MotionCascade"
            data-variant={AutolaunchWeb.Motion.standard("grid")}
          >
            <.leg
              id="exposure-overnight"
              title="After-hours"
              window="close to open"
              token={@series.overnight}
              ledger={@series.night}
              leg={:overnight}
              series={@series}
              pool={@series.pools.overnight}
            />
            <.leg
              id="exposure-session"
              title="Market-hours"
              window="open to close"
              token={@series.session}
              ledger={@series.day}
              leg={:session}
              series={@series}
              pool={@series.pools.session}
            />
          </div>
          <P.disclosure
            id="exposure-example"
            class="exposure__disclosure"
            summary="Example"
            phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
          >
            <div class="exposure__example">
              <p>
                Illustrative only. If the stock closes at $100, each token's ledger starts at $50.
                If the next open is $110, After-hours becomes $60 and Market-hours stays $50: a 20%
                gain for After-hours from a 10% move in the stock.
              </p>
              <p>
                That multiple changes as prices move, and a price that takes either ledger to zero
                ends the series early, with the other token receiving all the stock.
              </p>
            </div>
          </P.disclosure>
        </section>

        <section
          id="exposure-act"
          class="exposure__section"
          aria-label="Trade"
          phx-hook="MotionTabs"
          data-active={@active}
          data-variant={AutolaunchWeb.Motion.standard("tabs")}
        >
          <div class="token-trade__tabs" role="tablist" aria-label="Trade">
            <span
              id="exposure-act-ink"
              class="token-trade__ink"
              data-ink
              aria-hidden="true"
              phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["style"])}
            ></span>
            <button
              :for={
                {tab, value, label} <- [
                  {:buy, "buy", "Buy"},
                  {:sell, "sell", "Sell"},
                  {:mint, "split", "Split"},
                  {:redeem, "redeem", "Redeem"}
                ]
              }
              type="button"
              role="tab"
              id={"exposure-act-tab-#{tab}"}
              data-tab={tab}
              aria-selected={to_string(tab == @active)}
              aria-controls="exposure-act-panel"
              phx-click="tab"
              phx-value-tab={value}
            >
              {label}
            </button>
          </div>
          <div
            id="exposure-act-panel"
            role="tabpanel"
            aria-labelledby={"exposure-act-tab-#{@active}"}
          >
            <div :if={@active in [:buy, :sell]} class="exposure__panel">
              <div class="exposure__legs-pick" role="group" aria-label="Token">
                <button
                  :for={
                    {leg, value, label} <- [
                      {:overnight, "after-hours", "After-hours"},
                      {:session, "market-hours", "Market-hours"}
                    ]
                  }
                  type="button"
                  id={"exposure-leg-#{value}"}
                  class="exposure__pick"
                  aria-pressed={to_string(leg == @leg)}
                  phx-click="leg"
                  phx-value-leg={value}
                >
                  {label}
                </button>
              </div>
              <p class="exposure__muted">{trade_note(@active, @leg, @series)}</p>
              <p :if={!liquid?(@series, @leg)} id="exposure-no-liquidity" class="exposure__opens">
                Trading opens when liquidity is added.
              </p>
              <.live_component
                module={ExposureComponent}
                id={"exposure-#{@active}-#{@leg}-#{@series.address}"}
                kind={@active}
                leg={@leg}
                series={@series}
                session_lease={@session_lease}
                current_human_id={@human_id}
              />
            </div>
            <div :if={@active == :mint} class="exposure__panel">
              <p class="exposure__muted">
                Deposit {@series.stock.symbol} and receive the same amount of each token. Keep both
                for the stock's whole move, or sell the one you don't want once it trades.
              </p>
              <p :if={@series.status == :pending} id="exposure-opens" class="exposure__opens">
                Splitting opens after the first price is recorded and applied, no earlier than {F.moment(
                  @series.next.recordable_at
                )} New York.
              </p>
              <.live_component
                module={ExposureComponent}
                id={"exposure-mint-#{@series.address}"}
                kind={:mint}
                series={@series}
                session_lease={@session_lease}
                current_human_id={@human_id}
              />
            </div>
            <div :if={@active == :redeem} class="exposure__panel">
              <p class="exposure__muted">{redeem_note(@series)}</p>
              <.live_component
                module={ExposureComponent}
                id={"exposure-redeem-#{@series.address}"}
                kind={:redeem}
                series={@series}
                session_lease={@session_lease}
                current_human_id={@human_id}
              />
            </div>
          </div>
        </section>

        <section class="exposure__section" aria-labelledby="exposure-prices-title">
          <h2 id="exposure-prices-title" class="exposure__title">Prices</h2>
          <.price_chart
            id="exposure-chart"
            label={"#{@series.stock.symbol} at each price"}
            history={history(@series)}
            unit="USD"
            count_label="Prices"
          />
          <div class="market-list__scroll">
            <table class="market-list__table exposure__table">
              <caption class="visually-hidden">Prices this series has applied</caption>
              <thead>
                <tr>
                  <th scope="col">Time (New York)</th>
                  <th scope="col">{@series.stock.symbol}</th>
                  <th scope="col">After-hours</th>
                  <th scope="col">Market-hours</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={print <- @series.prints} id={"exposure-print-#{print.index}"}>
                  <td data-label="Time">
                    {if print.open?, do: "Open", else: "Close"}, {F.moment(print.at)}
                  </td>
                  <td data-label={@series.stock.symbol}>{F.usd(print.price)}</td>
                  <td data-label="After-hours">{F.usd(print.night)}</td>
                  <td data-label="Market-hours">{F.usd(print.day)}</td>
                </tr>
                <tr :if={@series.next} class="exposure__next">
                  <td data-label="Time">
                    {if @series.next.open?, do: "Open", else: "Close"}, {F.moment(@series.next.at)}
                  </td>
                  <td colspan="3">Next price</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section class="exposure__section" aria-labelledby="exposure-terms-title">
          <h2 id="exposure-terms-title" class="exposure__title">Terms</h2>
          <ul class="exposure__terms">
            <li>
              Prices are the Coinbase {ticker(@series)} Chainlink feed on Base at 9:30am and 4:00pm New
              York time, not the exchange's official open and close.
            </li>
            <li>
              If a price takes either token's value to zero or below, the series ends and the other
              token receives all the {@series.stock.symbol}.
            </li>
            <li>
              Before the end, one of each redeems for one {@series.stock.symbol}. At the end, each
              token redeems for its own final share.
            </li>
            <li>
              Coinbase controls {@series.stock.symbol}. It can pause it, block an account, or take {@series.stock.symbol} from the series, which reduces every redemption by the same
              share.
            </li>
          </ul>
          <p class="exposure__muted">
            <.link href={~p"/after-hour-stocks/terms/#{@series.terms_hash}"}>Full terms</.link>
            · fingerprint on Base <code class="exposure__hash">{short_hash(@series.terms_hash)}</code>
          </p>
        </section>

        <P.disclosure
          id="exposure-details"
          class="exposure__disclosure"
          summary="Series details"
          phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
        >
          <div class="exposure__details">
            <dl class="exposure__addresses">
              <div>
                <dt>Series</dt>
                <dd><P.address id="exposure-address-series" address={@series.address} /></dd>
              </div>
              <div>
                <dt>{@series.stock.symbol}</dt>
                <dd><P.address id="exposure-address-stock" address={@series.stock.address} /></dd>
              </div>
              <div>
                <dt>{@series.overnight.symbol}</dt>
                <dd>
                  <P.address id="exposure-address-overnight" address={@series.overnight.address} />
                </dd>
              </div>
              <div>
                <dt>{@series.session.symbol}</dt>
                <dd>
                  <P.address id="exposure-address-session" address={@series.session.address} />
                </dd>
              </div>
              <div>
                <dt>Price recorder</dt>
                <dd><P.address id="exposure-address-oracle" address={@series.oracle} /></dd>
              </div>
            </dl>
            <div :if={@series.next} class="exposure__panel">
              <p class="exposure__muted">
                Each price is recorded from the feed an hour after its time, then applied to the
                series. Anyone can do either, and the first press counts. If a price can't be
                recorded within {days(@series.max_report_delay)}, anyone can end the series at the
                last recorded values.
              </p>
              <.live_component
                module={ExposureComponent}
                id={"exposure-update-#{@series.address}"}
                kind={:update}
                series={@series}
                session_lease={@session_lease}
                current_human_id={@human_id}
              />
              <.live_component
                module={ExposureComponent}
                id={"exposure-end-#{@series.address}"}
                kind={:end}
                series={@series}
                session_lease={@session_lease}
                current_human_id={@human_id}
              />
            </div>
          </div>
        </P.disclosure>
      <% end %>
    </article>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :window, :string, required: true
  attr :token, :map, required: true
  attr :ledger, :integer, required: true
  attr :series, :map, required: true
  attr :pool, :map, default: nil
  attr :leg, :atom, required: true, values: [:overnight, :session]

  defp leg(assigns) do
    ~H"""
    <section id={@id} class="exposure__leg" aria-labelledby={"#{@id}-title"}>
      <header class="exposure__leg-head">
        <h3 id={"#{@id}-title"}>{@title}</h3>
        <span class="exposure__muted">{@window}</span>
      </header>
      <p class="exposure__muted">{@token.symbol}</p>
      <dl
        :if={@series.settled > 0}
        id={"#{@id}-facts"}
        class="exposure__leg-facts"
        phx-hook="MotionCount"
        data-variant={AutolaunchWeb.Motion.standard("count")}
      >
        <div>
          <dt>Ledger value</dt>
          <dd>{F.usd(@ledger)} <small>{ledger_note(@series)}</small></dd>
        </div>
        <div>
          <dt>Stock claim</dt>
          <dd>{claim(@series, @leg)} <small>{claim_note(@series)}</small></dd>
        </div>
        <div>
          <dt>Leverage</dt>
          <dd>
            {leverage(@series, @ledger)}
            <small :if={@series.status != :ended}>in its own window</small>
          </dd>
        </div>
      </dl>
      <p class="exposure__trade-line">
        <span>{pool_line(@pool)}</span>
        <.link
          :if={@pool && @pool.usdc_per_token}
          href={"https://aerodrome.finance/swap?from=eth&to=#{@token.address}"}
          class="rg-button rg-button--secondary exposure__trade"
          target="_blank"
          rel="noopener"
        >
          Trade
        </.link>
      </p>
    </section>
    """
  end

  # The stock's applied prices as a line for the price chart, in dollars.
  defp history(%{prints: prints}) do
    prices = Enum.map(prints, fn print -> print.price / 1.0e18 end)

    %{
      points: prices |> Enum.with_index() |> Enum.map(fn {price, index} -> [index, price] end),
      low: Enum.min(prices, fn -> 0.0 end),
      high: Enum.max(prices, fn -> 0.0 end),
      trades: length(prices)
    }
  end

  # The ledger is the dollar figure the series has recorded for one token at its
  # last price. The stock claim is the stock that ledger stands for: provisional
  # while prices still move it, final once the series has ended, when each token
  # redeems for it and its dollar value moves with the stock.
  defp ledger_note(%{status: :ended}), do: "per token, at the final price"
  defp ledger_note(_series), do: "per token, at the last price"

  # After the end the claim is what redeeming one whole token pays, as the
  # contract works it out, cut for any stock the issuer took from the series.
  defp claim(%{status: :ended, stock: stock} = series, leg) do
    unit = Integer.pow(10, stock.decimals)

    paid =
      if leg == :overnight, do: Chain.paid(series, unit, 0), else: Chain.paid(series, 0, unit)

    "#{F.tokens(paid, stock.decimals)} #{stock.symbol}"
  end

  defp claim(%{stock: stock, price: price} = series, leg) do
    unit = Integer.pow(10, stock.decimals)
    "#{F.tokens(div(ledger(series, leg) * unit, price), stock.decimals)} #{stock.symbol}"
  end

  defp claim_note(%{status: :ended}), do: "per token, final"
  defp claim_note(_series), do: "per token, provisional"

  defp ledger(series, :overnight), do: series.night
  defp ledger(series, :session), do: series.day

  defp leverage(%{status: :ended}, 0), do: "Nothing left"
  defp leverage(%{status: :ended, stock: stock}, _ledger), do: "Moves with #{stock.symbol}"

  defp leverage(series, ledger),
    do: "#{F.times(series.price, ledger)} #{series.stock.symbol}'s move"

  defp pool_line(%{usdc_per_token: usdc}) when is_integer(usdc), do: "Pool price #{F.usdc(usdc)}"
  defp pool_line(_no_liquidity), do: "Trading opens when liquidity is added."

  # The next price and where it stands: not yet recordable, due to be recorded
  # and applied (under Series details), or missed, when the series can be ended.
  defp next_price(%{next: next, now: now}) do
    price = "#{if next.open?, do: "Open", else: "Close"}, #{F.moment(next.at)}"

    cond do
      now < next.recordable_at ->
        "#{price}, recordable from #{F.time(next.recordable_at)} New York"

      now <= next.deadline ->
        "#{price}, due to be recorded and applied"

      true ->
        "#{price}, missed: the series can be ended"
    end
  end

  defp days(seconds) do
    case div(seconds, 86_400) do
      1 -> "a day"
      count -> "#{count} days"
    end
  end

  defp short_address("0x" <> hex),
    do: "0x" <> String.slice(hex, 0, 4) <> "…" <> String.slice(hex, -4, 4)

  # A series by its stock, its days and where it stands, as in "AMZNc · 2–6 Nov · Upcoming".
  defp name(%{stock: stock, boundaries: boundaries, status: status}),
    do:
      "#{stock.symbol} · #{F.days(List.first(boundaries), List.last(boundaries))} · #{stage(status)}"

  defp stage(:pending), do: "Upcoming"
  defp stage(:active), do: "Live"
  defp stage(:ended), do: "Ended"

  defp term(%{boundaries: [first | _] = boundaries}),
    do: "#{F.moment(first)} to #{F.moment(List.last(boundaries))}"

  defp status(%{status: :pending, next: next}),
    do: "Opens after the close on #{F.moment(next.at)}"

  defp status(%{status: :active, settled: settled, boundaries: boundaries}),
    do: "Live, #{settled} of #{length(boundaries)} prices applied"

  defp status(%{status: :ended, end_reason: reason}), do: "Ended: " <> ended(reason)

  defp ended(:maturity), do: "term complete"
  defp ended(:overnight_depleted), do: "After-hours reached zero"
  defp ended(:session_depleted), do: "Market-hours reached zero"
  defp ended(:missing_print), do: "a price was not recorded in time"

  defp redeem_note(%{status: :ended, stock: stock}),
    do:
      "The series has ended. Each token redeems for its final share of #{stock.symbol}, and what that is worth in dollars moves with #{stock.symbol}."

  defp redeem_note(%{stock: stock}),
    do:
      "Redeem one of each token for one #{stock.symbol}, at any time. After the end, each token redeems on its own for its final share of #{stock.symbol}."

  # Buy leads once a token can be bought; until then, Split.
  defp default_tab(series) do
    if series && (liquid?(series, :overnight) or liquid?(series, :session)),
      do: :buy,
      else: :mint
  end

  # After-hours, unless only Market-hours can be bought now.
  defp default_leg(nil), do: :overnight

  defp default_leg(series) do
    if not liquid?(series, :overnight) and liquid?(series, :session),
      do: :session,
      else: :overnight
  end

  defp liquid?(%{pools: pools}, leg),
    do: match?(%{usdc_per_token: usdc} when is_integer(usdc), pools[leg])

  defp trade_note(:buy, :overnight, series),
    do:
      "Pay USDC for After-hours, to hold only #{series.stock.symbol}'s moves while the market is closed."

  defp trade_note(:buy, :session, series),
    do:
      "Pay USDC for Market-hours, to hold only #{series.stock.symbol}'s moves while the market is open."

  defp trade_note(:sell, _leg, _series),
    do:
      "Sell the token for USDC at its pool's price. After the end you can also redeem it for its share of the stock."

  defp tab_path(series, tab, leg, all) do
    value = Enum.find_value(@tabs, fn {value, atom} -> atom == tab && value end)

    query =
      [
        series: if(series.address != List.last(all), do: series.address),
        tab: value,
        leg: if(tab in [:buy, :sell] and leg == :session, do: "market-hours")
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    ~p"/after-hour-stocks?#{query}"
  end

  defp ticker(series), do: String.replace_suffix(series.stock.symbol, "c", "")

  defp short_hash("0x" <> hex),
    do: "0x" <> String.slice(hex, 0, 8) <> "…" <> String.slice(hex, -6, 6)
end
