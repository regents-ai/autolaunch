defmodule AutolaunchWeb.ExposureLive do
  @moduledoc """
  `/stock/isolated-afters`: Isolated Exposure to After-hours Stocks on a Base
  stock, one week at a time: this week, unless `?week=<number>` names one that
  has opened. The week's two tokens with their ledger, stock claim and
  leverage; panels to buy or sell a token, deposit the stock for a pair and
  redeem; Update prices, which applies every price that is due; each open and
  close of the week with its price; its terms, the last eight weeks and its
  addresses. Every figure is read from the chain (`Autolaunch.Exposure`);
  every press goes to the wallet through `AutolaunchWeb.ExposureComponent`.

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
  @tabs %{"buy" => :buy, "sell" => :sell, "deposit" => :deposit, "redeem" => :redeem}

  def mount(params, _session, socket) do
    if Deployment.enabled?() do
      asked = asked(params)

      share =
        if asked && not connected?(socket),
          do: ShareCard.market_meta(:exposure, Integer.to_string(asked))

      {:ok,
       socket
       |> assign(AutolaunchWeb.PublicDocuments.page("/stock/isolated-afters"))
       |> assign(share: share, next_read: nil, done: nil, topic: nil, terms?: false)
       |> assign(asked: :unread, reading: AsyncResult.loading(), weeks: AsyncResult.loading())
       |> assign(tab: nil, leg: nil)}
    else
      raise NotFoundError
    end
  end

  def handle_params(params, _uri, socket) do
    asked = asked(params)

    socket =
      assign(socket,
        tab: Map.get(@tabs, params["tab"]),
        leg: Map.get(%{"after-hours" => :overnight, "market-hours" => :session}, params["leg"])
      )

    if asked == socket.assigns.asked,
      do: {:noreply, socket},
      else: {:noreply, socket |> assign(asked: asked, reading: AsyncResult.loading()) |> read()}
  end

  # The week `?week=` names, written as the page writes it; nil for this week.
  defp asked(%{"week" => week}) do
    case Integer.parse(week) do
      {number, ""} when number > 0 -> if Integer.to_string(number) == week, do: number
      _not_a_week -> nil
    end
  end

  defp asked(_params), do: nil

  def handle_event("refresh", _params, socket), do: {:noreply, read(socket)}

  def handle_event("dismiss_done", _params, socket), do: {:noreply, assign(socket, done: nil)}

  def handle_event("tab", %{"tab" => tab}, socket) when is_map_key(@tabs, tab) do
    %{leg: leg, asked: asked} = socket.assigns
    {:noreply, push_patch(socket, to: tab_path(Map.fetch!(@tabs, tab), leg, asked))}
  end

  def handle_event("leg", %{"leg" => leg}, socket) when leg in ["after-hours", "market-hours"] do
    %{reading: reading, tab: tab, asked: asked} = socket.assigns
    leg = if leg == "market-hours", do: :session, else: :overnight
    {:noreply, push_patch(socket, to: tab_path(active_tab(tab, reading.result), leg, asked))}
  end

  # A press landed here: every open page of this week reads it again.
  def handle_info({:exposure_changed, week}, socket) do
    Phoenix.PubSub.broadcast(Autolaunch.PubSub, topic(week), :read_again)
    {:noreply, socket}
  end

  def handle_info(:read_again, socket), do: {:noreply, read(socket)}

  def handle_info({:exposure_done, done}, socket), do: {:noreply, assign(socket, done: done)}

  def handle_info({:read_when_due, ref}, %{assigns: %{next_read: ref}} = socket),
    do: {:noreply, read(socket)}

  def handle_info({:read_when_due, _older}, socket), do: {:noreply, socket}

  def handle_async(:week, {:ok, {asked, {:ok, reading}}}, %{assigns: %{asked: asked}} = socket) do
    {:noreply,
     socket
     |> assign(
       reading: AsyncResult.ok(socket.assigns.reading, reading),
       terms?: match?({:ok, _text}, Exposure.terms(reading.terms_hash))
     )
     |> listen(reading.week)
     |> read_when_due(reading)}
  end

  def handle_async(:week, {:ok, {asked, {:error, error}}}, %{assigns: %{asked: asked}} = socket),
    do:
      {:noreply,
       assign(socket, reading: AsyncResult.failed(socket.assigns.reading, Exposure.reason(error)))}

  def handle_async(:week, {:ok, {_older, _result}}, socket), do: {:noreply, socket}

  def handle_async(:week, {:exit, reason}, socket),
    do: {:noreply, assign(socket, reading: AsyncResult.failed(socket.assigns.reading, reason))}

  def handle_async(:weeks, {:ok, {:ok, list}}, socket),
    do: {:noreply, assign(socket, weeks: AsyncResult.ok(socket.assigns.weeks, list))}

  def handle_async(:weeks, _unread, socket),
    do: {:noreply, assign(socket, weeks: AsyncResult.failed(socket.assigns.weeks, :unread))}

  # The shown week and the list of weeks, read again together.
  defp read(socket) do
    asked = socket.assigns.asked

    socket
    |> start_async(:week, fn -> {asked, Exposure.exposure_week(asked)} end)
    |> start_async(:weeks, fn -> Exposure.exposure_weeks() end)
  end

  # The page hears the presses on the week it shows.
  defp listen(%{assigns: %{topic: topic}} = socket, week) do
    if connected?(socket) and topic != topic(week) do
      if topic, do: Phoenix.PubSub.unsubscribe(Autolaunch.PubSub, topic)
      Phoenix.PubSub.subscribe(Autolaunch.PubSub, topic(week))
      assign(socket, topic: topic(week))
    else
      socket
    end
  end

  # The page reads the week again at each open and close, so each token's
  # light never goes stale, and when each price becomes due an hour later, so
  # its figures and Update prices follow it. The last close's hour is also
  # when the next week takes over. Only the newest timer counts.
  defp read_when_due(socket, %{now: now, boundaries: boundaries}) do
    due = Enum.flat_map(boundaries, &[&1, &1 + Chain.settle_delay()])

    case due |> Enum.filter(&(&1 > now)) |> Enum.min(fn -> nil end) do
      nil ->
        socket

      at ->
        ref = make_ref()
        wait = min((at - now) * 1_000 + 2_000, @long_wait)
        Process.send_after(self(), {:read_when_due, ref}, wait)
        assign(socket, next_read: ref)
    end
  end

  defp topic(week), do: "exposure:#{week}"

  def render(assigns) do
    series = assigns.reading.result

    assigns =
      assign(assigns,
        series: series,
        human_id: current_human_id(assigns.access_context),
        tabs: tabs(series),
        active: active_tab(assigns.tab, series),
        leg: assigns.leg || default_leg(series)
      )

    ~H"""
    <article class="exposure">
      <ExposureComponent.toast :if={@done} id="exposure-done" done={@done} dismiss="dismiss_done" />
      <header class="exposure__header">
        <div class="exposure__intro">
          <h1>Isolated Exposure to After-hours Stocks</h1>
          <p>
            Split a stock token into two for one trading week. After-hours carries the stock's
            moves while the market is closed, from each close to the next open. Market-hours
            carries its moves while the market is open. One of each redeems for one stock token at
            any time, within the issuer's controls described in the terms.
          </p>
          <p id="exposure-eligibility" class="exposure__muted">
            Available to eligible people outside the US.
          </p>
          <p id="exposure-version" class="exposure__muted">
            Version 2 runs by itself: prices come straight from Chainlink with nobody recording
            them, and each week opens with its first deposit. Version 1's two series stay
            redeemable on Base, at the
            <.link
              id="exposure-version-first"
              href="https://basescan.org/address/0xcae5aad4cc21700b32931404c366efd4fc1ddfa0"
              target="_blank"
              rel="noopener noreferrer"
            >
              first series
            </.link>
            and the
            <.link
              id="exposure-version-second"
              href="https://basescan.org/address/0x1df53a86c8260c20ab79b5f620544209bd454266"
              target="_blank"
              rel="noopener noreferrer"
            >
              second series
            </.link>
            on Basescan.
          </p>
        </div>
        <AutolaunchWeb.Components.ShareMarket.share_market
          :if={@series && @series.opened?}
          id="exposure-share"
          kind={:exposure}
          subject={Integer.to_string(@series.week)}
          account_control={@account_control}
        />
        <P.last_read
          id="exposure-read"
          at={@series && @series.read_at}
          phx-click="refresh"
          label="Read the week again"
        />
      </header>

      <p :if={@reading.failed == :unknown_week} id="exposure-unknown" class="exposure__muted">
        That week hasn't opened on this site.
        <.link patch={~p"/stock/isolated-afters"}>This week</.link>
      </p>
      <p
        :if={@reading.failed && @reading.failed != :unknown_week}
        class="exposure__muted"
        role="alert"
      >
        The week couldn't be read just now. Try again in a moment.
      </p>
      <div :if={!@series && !@reading.failed} class="exposure__loading" aria-busy="true">
        <span class="loading-block"></span>
      </div>

      <%= if @series do %>
        <section id="exposure-summary" class="exposure__summary" aria-label="Week">
          <dl class="exposure__facts">
            <div>
              <dt>Week</dt>
              <dd id="exposure-week">{week_days(@series)}</dd>
            </div>
            <div>
              <dt>Status</dt>
              <dd id="exposure-status">{status(@series)}</dd>
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
              <dt>Room</dt>
              <dd id="exposure-room">
                {F.tokens(Chain.room(@series), @series.stock.decimals)} {@series.stock.symbol}
              </dd>
            </div>
            <div>
              <dt>{@series.stock.symbol} price</dt>
              <dd>{if @series.applied > 0, do: F.usd(@series.price), else: "Not set yet"}</dd>
            </div>
            <div :if={next_boundary(@series)}>
              <dt>Next price</dt>
              <dd id="exposure-next">{next_price(@series)}</dd>
            </div>
          </dl>
          <p
            :if={not @series.opened? and @series.paused}
            id="exposure-paused"
            class="exposure__pending"
          >
            Opening new weeks is paused, so this week can't open with a deposit now.
          </p>
          <p :if={@series.unreadable?} id="exposure-unreadable" class="exposure__pending">
            {unreadable(@series)}
          </p>
        </section>

        <section
          id="exposure-act"
          class="exposure__section"
          aria-label="Trade"
          phx-hook="MotionTabs"
          data-active={@active}
          data-variant={AutolaunchWeb.Motion.standard("tabs")}
        >
          <div class="token-trade__tabs" role="tablist" aria-label="Trade" data-tabs={length(@tabs)}>
            <span
              id="exposure-act-ink"
              class="token-trade__ink"
              data-ink
              aria-hidden="true"
              phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["style"])}
            ></span>
            <button
              :for={{tab, value, label} <- @tabs}
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
                id={"exposure-#{@active}-#{@leg}-#{@series.week}"}
                kind={@active}
                leg={@leg}
                series={@series}
                session_lease={@session_lease}
                current_human_id={@human_id}
              />
            </div>
            <div :if={@active == :deposit} class="exposure__panel">
              <p class="exposure__muted">
                Deposit {@series.stock.symbol} and receive the same amount of each token. Keep both
                for the stock's whole move, or sell the one you don't want once it trades.
              </p>
              <p :if={not @series.opened?} id="exposure-opens" class="exposure__opens">
                Opens with the first deposit.
              </p>
              <.live_component
                module={ExposureComponent}
                id={"exposure-deposit-#{@series.week}"}
                kind={:deposit}
                series={@series}
                session_lease={@session_lease}
                current_human_id={@human_id}
              />
            </div>
            <div :if={@active == :redeem} class="exposure__panel">
              <p class="exposure__muted">{redeem_note(@series)}</p>
              <.live_component
                module={ExposureComponent}
                id={"exposure-redeem-#{@series.week}"}
                kind={:redeem}
                series={@series}
                session_lease={@session_lease}
                current_human_id={@human_id}
              />
            </div>
          </div>
        </section>

        <section class="exposure__section" aria-labelledby="exposure-tokens-title">
          <h2 id="exposure-tokens-title" class="exposure__title">Tokens</h2>
          <p :if={pending_note(@series)} id="exposure-pending" class="exposure__pending">
            {pending_note(@series)}
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
              running={running(@series) == :overnight}
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
              running={running(@series) == :session}
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
                ends the week early, with the other token receiving all the stock.
              </p>
            </div>
          </P.disclosure>
        </section>

        <section id="exposure-prices" class="exposure__section" aria-labelledby="exposure-prices-title">
          <h2 id="exposure-prices-title" class="exposure__title">Prices</h2>
          <.price_chart
            :if={match?([_ | _], @series[:prints])}
            id="exposure-chart"
            label={"#{@series.stock.symbol} at each price"}
            history={history(@series.prints)}
            unit="USD"
            count_label="Prices"
          />
          <div class="market-list__scroll">
            <table class="market-list__table exposure__table">
              <caption class="visually-hidden">Each open and close of the week</caption>
              <thead>
                <tr>
                  <th scope="col">Time (New York)</th>
                  <th scope="col">{@series.stock.symbol}</th>
                  <th scope="col">After-hours</th>
                  <th scope="col">Market-hours</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={{at, index} <- Enum.with_index(@series.boundaries)}
                  id={"exposure-price-#{index}"}
                  data-state={boundary_state(@series, index)}
                >
                  <td data-label="Time">
                    {if rem(index, 2) == 1, do: "Open", else: "Close"}, {F.moment(at)}
                  </td>
                  <%= case print(@series, index) do %>
                    <% nil -> %>
                      <td colspan="3">{boundary_words(@series, index)}</td>
                    <% print -> %>
                      <td data-label={@series.stock.symbol}>{F.usd(print.price)}</td>
                      <td data-label="After-hours">{F.usd(print.night)}</td>
                      <td data-label="Market-hours">{F.usd(print.day)}</td>
                  <% end %>
                </tr>
              </tbody>
            </table>
          </div>
          <div
            :if={@series.opened? and not @series.ended_on_chain?}
            id="exposure-update"
            class="exposure__panel"
          >
            <p class="exposure__muted">
              Each price applies from an hour after its open or close. The figures here already
              include every price that's due; anyone can press Update prices to write them to Base.
            </p>
            <.live_component
              module={ExposureComponent}
              id={"exposure-settle-#{@series.week}"}
              kind={:settle}
              series={@series}
              session_lease={@session_lease}
              current_human_id={@human_id}
            />
          </div>
        </section>

        <section class="exposure__section" aria-labelledby="exposure-terms-title">
          <h2 id="exposure-terms-title" class="exposure__title">Terms</h2>
          <ul class="exposure__terms">
            <li>
              Prices are the Coinbase {ticker(@series)} Chainlink feed on Base at 9:30am and 4:00pm New
              York time on each trading day, read by the contract itself, not the exchange's
              official open and close.
            </li>
            <li>
              If a price takes either token's value to zero or below, the week ends and the other
              token receives all the {@series.stock.symbol}.
            </li>
            <li>
              The week also ends early, at its last prices, if the feed has no price in the 84 hours
              before an open or close, gives a price that can't be used, or can't be read for 7 days.
            </li>
            <li>
              One of each redeems for one {@series.stock.symbol} at any time. After the end, each
              token also redeems on its own for its final share.
            </li>
            <li>
              Coinbase controls {@series.stock.symbol}. It can pause it, block an account, or take {@series.stock.symbol} from the series, which reduces every redemption by the same
              share.
            </li>
          </ul>
          <p class="exposure__muted">
            <.link :if={@terms?} id="exposure-terms" href={~p"/stock/isolated-afters/terms/#{@series.terms_hash}"}>
              Full terms
            </.link>
            <span :if={@terms?}>·</span>
            fingerprint on Base <code class="exposure__hash">{short_hash(@series.terms_hash)}</code>
          </p>
        </section>
      <% end %>

      <section
        :if={past(@weeks) != [] or (@series && not @series.current?)}
        id="exposure-weeks"
        class="exposure__section"
        aria-labelledby="exposure-weeks-title"
      >
        <h2 id="exposure-weeks-title" class="exposure__title">Past weeks</h2>
        <nav class="exposure__picker" aria-label="Weeks">
          <.link
            :if={@series && not @series.current?}
            id="exposure-week-current"
            patch={~p"/stock/isolated-afters"}
            class="exposure__pick"
          >
            This week
          </.link>
          <.link
            :for={week <- past(@weeks)}
            id={"exposure-week-#{week.week}"}
            patch={~p"/stock/isolated-afters?#{[week: week.week]}"}
            class="exposure__pick"
            aria-current={@series && @series.week == week.week && "page"}
          >
            {week_days(week)} · {stage(week)}
          </.link>
        </nav>
      </section>

      <P.disclosure
        :if={@series}
        id="exposure-details"
        class="exposure__disclosure"
        summary="Details"
        phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
      >
        <div class="exposure__details">
          <dl class="exposure__addresses">
            <div>
              <dt>Factory</dt>
              <dd><P.address id="exposure-address-factory" address={@series.factory} /></dd>
            </div>
            <div>
              <dt>{if @series.opened?, do: "Series", else: "Opens at"}</dt>
              <dd><P.address id="exposure-address-series" address={@series.address} /></dd>
            </div>
            <div>
              <dt>{@series.stock.symbol}</dt>
              <dd><P.address id="exposure-address-stock" address={@series.stock.address} /></dd>
            </div>
            <div :if={@series.opened?}>
              <dt>{@series.overnight.symbol}</dt>
              <dd>
                <P.address id="exposure-address-overnight" address={@series.overnight.address} />
              </dd>
            </div>
            <div :if={@series.opened?}>
              <dt>{@series.session.symbol}</dt>
              <dd>
                <P.address id="exposure-address-session" address={@series.session.address} />
              </dd>
            </div>
            <div>
              <dt>Price feed</dt>
              <dd><P.address id="exposure-address-feed" address={@series.feed} /></dd>
            </div>
          </dl>
        </div>
      </P.disclosure>
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
  attr :running, :boolean, required: true

  defp leg(assigns) do
    ~H"""
    <section id={@id} class="exposure__leg" aria-labelledby={"#{@id}-title"}>
      <header class="exposure__leg-head">
        <h3 id={"#{@id}-title"}>{@title}</h3>
        <span class="exposure__muted">{@window}</span>
        <span
          id={"#{@id}-light"}
          class="exposure__light"
          data-running={to_string(@running)}
          role="img"
          aria-label={if @running, do: "Running", else: "Paused"}
          title={if @running, do: "Running", else: "Paused"}
        >
          <span class="exposure__lamp exposure__lamp--stop"></span>
          <span class="exposure__lamp exposure__lamp--go"></span>
        </span>
      </header>
      <p class="exposure__muted">{@token.symbol}</p>
      <dl
        :if={@series.applied > 0}
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
          </dd>
        </div>
      </dl>
      <p :if={@series.opened?} class="exposure__trade-line">
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

  # The week's tabs: a week not open yet takes only a deposit; an open one
  # trades and redeems, and takes deposits while it is this week.
  defp tabs(nil), do: []
  defp tabs(%{opened?: false}), do: [{:deposit, "deposit", "Deposit"}]

  defp tabs(series) do
    [{:buy, "buy", "Buy"}, {:sell, "sell", "Sell"}] ++
      if(series.current?, do: [{:deposit, "deposit", "Deposit"}], else: []) ++
      [{:redeem, "redeem", "Redeem"}]
  end

  # The tab asked for when the week has it; else Buy once a token can be
  # bought, Deposit while the week takes deposits, and Redeem after.
  defp active_tab(_tab, nil), do: nil

  defp active_tab(tab, series) do
    shown = Enum.map(tabs(series), &elem(&1, 0))

    cond do
      tab in shown -> tab
      liquid?(series, :overnight) or liquid?(series, :session) -> :buy
      :deposit in shown and series.status in [:unopened, :active] -> :deposit
      true -> List.last(shown)
    end
  end

  # Which token carries the stock's moves now: After-hours from a close to the
  # next open, Market-hours from an open to the next close. Neither before the
  # week starts, after its last close, or once it has ended.
  defp running(%{status: status}) when status in [:unopened, :ended], do: nil

  defp running(%{boundaries: boundaries, now: now}) do
    case Enum.count(boundaries, &(&1 <= now)) do
      0 -> nil
      passed when passed == length(boundaries) -> nil
      passed when rem(passed, 2) == 1 -> :overnight
      _even -> :session
    end
  end

  # The applied prices as a line for the price chart, in dollars.
  defp history(prints) do
    prices = Enum.map(prints, fn print -> print.price / 1.0e18 end)

    %{
      points: prices |> Enum.with_index() |> Enum.map(fn {price, index} -> [index, price] end),
      times: nil,
      low: Enum.min(prices),
      high: Enum.max(prices),
      trades: length(prices)
    }
  end

  defp print(%{prints: [_ | _] = prints}, index), do: Enum.at(prints, index)
  defp print(_series, _index), do: nil

  # Where one open or close stands: its price written to Base, due to apply
  # (an hour after it, until Update prices writes it), still to come, or never
  # applied because the week ended first.
  defp boundary_state(series, index) do
    at = Enum.at(series.boundaries, index)

    cond do
      index < series.settled -> "applied"
      index < series.applied -> "due"
      series.status == :ended -> "skipped"
      series.now >= at + Chain.settle_delay() -> "due"
      true -> "upcoming"
    end
  end

  defp boundary_words(series, index) do
    case boundary_state(series, index) do
      "applied" -> "Applied"
      "due" -> "Due"
      "skipped" -> "Not applied"
      "upcoming" -> "Upcoming"
    end
  end

  # The ledger is the dollar figure one token stands at after the last price.
  # The stock claim is the stock that ledger stands for: provisional while
  # prices still move it, final once the week has ended, when each token
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

  defp pending_note(%{opened?: false}),
    do: "This week opens with its first deposit. Each token's value is set by the first price."

  defp pending_note(%{applied: 0, status: :ended}),
    do: "This week ended before its first price, so each token redeems only as a pair."

  defp pending_note(%{applied: 0}), do: "Each token's value is set when the first price applies."
  defp pending_note(_series), do: nil

  # The first open or close not applied yet, while the week runs.
  defp next_boundary(%{status: :ended}), do: nil

  defp next_boundary(%{boundaries: boundaries, applied: applied}) do
    case Enum.at(boundaries, applied) do
      nil -> nil
      at -> %{at: at, open?: rem(applied, 2) == 1}
    end
  end

  defp next_price(series) do
    next = next_boundary(series)
    price = "#{if next.open?, do: "Open", else: "Close"}, #{F.moment(next.at)}"
    applies = next.at + Chain.settle_delay()

    if series.now < applies,
      do: "#{price}, applies from #{F.time(applies)} New York",
      else: "#{price}, due"
  end

  defp unreadable(%{unreadable_since: nil}),
    do:
      "The price feed can't be read just now. If it stays unreadable for 7 days, the week ends at its last prices."

  defp unreadable(%{unreadable_since: since}),
    do:
      "The price feed hasn't been readable since #{F.moment(since)} New York. If it stays unreadable for 7 days, the week ends at its last prices."

  defp week_days(%{boundaries: [first | _] = boundaries}),
    do: F.days(Enum.at(boundaries, 1, first), List.last(boundaries))

  defp status(%{status: :unopened}), do: "Opens with the first deposit"
  defp status(%{status: :pending}), do: "Waiting for its first price"

  defp status(%{status: :active, applied: applied, boundaries: boundaries}),
    do: "Live, #{applied} of #{length(boundaries)} prices applied"

  defp status(%{status: :ended, end_reason: reason}), do: "Ended: " <> ended(reason)

  defp ended(:maturity), do: "week complete"
  defp ended(:overnight_depleted), do: "After-hours reached zero"
  defp ended(:session_depleted), do: "Market-hours reached zero"
  defp ended(:stale_feed), do: "the price feed had no price in the 84 hours before a moment"
  defp ended(:bad_price), do: "the price feed gave a price that can't be used"
  defp ended(:feed_unreadable), do: "the price feed couldn't be read for 7 days"

  defp stage(%{status: :ended}), do: "Ended"
  defp stage(_week), do: "Live"

  # The listed weeks before this one, newest first.
  defp past(%{result: %{weeks: weeks}}), do: Enum.reject(weeks, & &1.current?)
  defp past(_unread), do: []

  defp redeem_note(%{status: :ended, stock: stock}),
    do:
      "The week has ended. Each token redeems for its final share of #{stock.symbol}, and what that is worth in dollars moves with #{stock.symbol}."

  defp redeem_note(%{stock: stock}),
    do:
      "Redeem one of each token for one #{stock.symbol}, at any time. After the end, each token redeems on its own for its final share of #{stock.symbol}."

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

  defp tab_path(tab, leg, asked) do
    value = Enum.find_value(@tabs, fn {value, atom} -> atom == tab && value end)

    query =
      [
        week: asked,
        tab: value,
        leg: if(tab in [:buy, :sell] and leg == :session, do: "market-hours")
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    ~p"/stock/isolated-afters?#{query}"
  end

  defp ticker(series), do: String.replace_suffix(series.stock.symbol, "c", "")

  defp short_hash("0x" <> hex),
    do: "0x" <> String.slice(hex, 0, 8) <> "…" <> String.slice(hex, -6, 6)
end
