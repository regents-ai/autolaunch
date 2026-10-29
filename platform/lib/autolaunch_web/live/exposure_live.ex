defmodule AutolaunchWeb.ExposureLive do
  @moduledoc """
  `/after-hour-stocks`: After-hours Exposure on a Base stock. One series at a time, the newest
  unless `?series=<address>` names another the site offers: its two tokens with
  what each is worth now, the prices it has applied, and panels to mint pairs,
  return tokens for the stock, and record the next price. Every figure is read
  from the chain (`Autolaunch.Exposure`); every press goes to the wallet through
  `AutolaunchWeb.ExposureComponent`.

  With Exposure switched off the address is the site's 404.
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [current_human_id: 1]
  import AutolaunchWeb.Components.PriceChart, only: [price_chart: 1]

  alias Autolaunch.Exposure
  alias Autolaunch.Exposure.Deployment
  alias AutolaunchWeb.ExposureComponent
  alias AutolaunchWeb.ExposureFormat, as: F
  alias AutolaunchWeb.NotFoundError
  alias Phoenix.LiveView.AsyncResult
  alias Regent.Primitives, as: P

  def mount(_params, _session, socket) do
    with true <- Deployment.enabled?(),
         {:ok, config} <- Deployment.current() do
      {:ok,
       socket
       |> assign(AutolaunchWeb.PublicDocuments.page("/after-hour-stocks"))
       |> assign(all: config.series, address: nil, reading: AsyncResult.loading(), tab: :mint)}
    else
      _off -> raise NotFoundError
    end
  end

  def handle_params(params, _uri, socket) do
    address =
      case Deployment.series(params["series"]) do
        {:ok, address} -> address
        {:error, _unknown} -> List.last(socket.assigns.all)
      end

    tab = if params["tab"] == "return", do: :return, else: :mint
    socket = assign(socket, tab: tab)

    if address == socket.assigns.address,
      do: {:noreply, socket},
      else: {:noreply, follow(socket, address)}
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

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["mint", "return"] do
    tab = String.to_existing_atom(tab)

    {:noreply,
     push_patch(socket, to: tab_path(socket.assigns.reading.result, tab, socket.assigns.all))}
  end

  # A press landed here: every open page of this series reads it again.
  def handle_info({:exposure_changed, address}, socket) do
    Phoenix.PubSub.broadcast(Autolaunch.PubSub, topic(address), :read_again)
    {:noreply, socket}
  end

  def handle_info(:read_again, socket), do: {:noreply, read_series(socket)}

  def handle_async(:series, {:ok, {address, {:ok, series}}}, socket) do
    if address == socket.assigns.address,
      do: {:noreply, assign(socket, reading: AsyncResult.ok(socket.assigns.reading, series))},
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

  defp read_series(socket) do
    address = socket.assigns.address
    start_async(socket, :series, fn -> {address, Exposure.exposure_series(address)} end)
  end

  defp topic(address), do: "exposure:" <> address

  def render(assigns) do
    assigns =
      assign(assigns,
        series: assigns.reading.result,
        human_id: current_human_id(assigns.access_context)
      )

    ~H"""
    <article class="exposure">
      <header class="exposure__header">
        <div class="exposure__intro">
          <h1>After-hours Exposure</h1>
          <p>
            Split a stock token into two for a week. After-hours carries the stock's moves while
            the market is closed, from each close to the next open. Market-hours carries its moves
            while the market is open. One of each always returns one stock token.
          </p>
          <p id="exposure-eligibility" class="exposure__muted">
            Available to eligible people outside the US.
          </p>
        </div>
        <P.last_read
          id="exposure-read"
          at={@series && @series.read_at}
          phx-click="refresh"
          label="Read the series again"
        />
      </header>

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
              <dd>
                {@series.stock.symbol}
                <P.address id="exposure-stock" address={@series.stock.address} />
              </dd>
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
              <dd>{if @series.settled > 0, do: F.usd(@series.price), else: "—"}</dd>
            </div>
          </dl>
        </section>

        <section class="exposure__section" aria-labelledby="exposure-tokens-title">
          <h2 id="exposure-tokens-title" class="exposure__title">Tokens</h2>
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
              series={@series}
              pool={@series.pools.overnight}
            />
            <.leg
              id="exposure-session"
              title="Market-hours"
              window="open to close"
              token={@series.session}
              ledger={@series.day}
              series={@series}
              pool={@series.pools.session}
            />
          </div>
        </section>

        <section
          id="exposure-act"
          class="exposure__section"
          aria-label="Mint or return"
          phx-hook="MotionTabs"
          data-active={@tab}
          data-variant={AutolaunchWeb.Motion.standard("tabs")}
        >
          <div class="token-trade__tabs" role="tablist" aria-label="Mint or return">
            <span
              id="exposure-act-ink"
              class="token-trade__ink"
              data-ink
              aria-hidden="true"
              phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["style"])}
            ></span>
            <button
              :for={{tab, label} <- [mint: "Mint", return: "Return"]}
              type="button"
              role="tab"
              id={"exposure-act-tab-#{tab}"}
              data-tab={tab}
              aria-selected={to_string(tab == @tab)}
              aria-controls="exposure-act-panel"
              phx-click="tab"
              phx-value-tab={tab}
            >
              {label}
            </button>
          </div>
          <div id="exposure-act-panel" role="tabpanel" aria-labelledby={"exposure-act-tab-#{@tab}"}>
            <div :if={@tab == :mint} class="exposure__panel">
              <p class="exposure__muted">
                Deposit {@series.stock.symbol} and receive the same amount of each token.
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
            <div :if={@tab == :return} class="exposure__panel">
              <p class="exposure__muted">{return_note(@series)}</p>
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
          <div :if={@series.next} class="exposure__panel">
            <p class="exposure__muted">
              Anyone can record a price an hour after its time, then apply it to the series.
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
              :if={@series.now > @series.next.deadline}
              module={ExposureComponent}
              id={"exposure-end-#{@series.address}"}
              kind={:end}
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
              York time, not the exchange's official open and close.
            </li>
            <li>
              If a price takes either token's value to zero or below, the series ends and the other
              token receives all the {@series.stock.symbol}.
            </li>
            <li>
              Before the end, one of each returns one {@series.stock.symbol}. At the end, each token
              returns its own share.
            </li>
            <li>Coinbase controls {@series.stock.symbol} and can pause or block it.</li>
          </ul>
          <p class="exposure__muted">
            <.link href={~p"/after-hour-stocks/terms/#{@series.terms_hash}"}>Full terms</.link>
            · fingerprint on Base <code class="exposure__hash">{short_hash(@series.terms_hash)}</code>
          </p>
        </section>

        <nav :if={length(@all) > 1} class="exposure__section" aria-label="Every series">
          <h2 class="exposure__title">Series</h2>
          <ul class="exposure__series-list">
            <li :for={address <- Enum.reverse(@all)}>
              <P.address id={"exposure-series-#{address}"} address={address} />
              <.link
                patch={~p"/after-hour-stocks?series=#{address}"}
                aria-current={address == @series.address && "page"}
              >
                {if address == @series.address, do: "Showing", else: "Show"}
              </.link>
            </li>
          </ul>
        </nav>
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

  defp leg(assigns) do
    ~H"""
    <section id={@id} class="exposure__leg" aria-labelledby={"#{@id}-title"}>
      <header class="exposure__leg-head">
        <h3 id={"#{@id}-title"}>{@title}</h3>
        <span class="exposure__muted">{@window}</span>
      </header>
      <p class="exposure__muted">
        {@token.symbol} <P.address id={"#{@id}-address"} address={@token.address} />
      </p>
      <dl
        id={"#{@id}-facts"}
        class="exposure__leg-facts"
        phx-hook="MotionCount"
        data-variant={AutolaunchWeb.Motion.standard("count")}
      >
        <div>
          <dt>Value</dt>
          <dd>{if @series.settled > 0, do: F.usd(@ledger), else: "—"}</dd>
        </div>
        <div>
          <dt>Share</dt>
          <dd>
            {if @series.settled > 0,
              do: "#{F.percent(@ledger, @series.price)} of #{@series.stock.symbol}",
              else: "—"}
          </dd>
        </div>
        <div>
          <dt>Moves</dt>
          <dd>{if @series.settled > 0, do: F.times(@series.price, @ledger), else: "—"}</dd>
        </div>
        <div>
          <dt>Pool</dt>
          <dd>{pool_price(@pool)}</dd>
        </div>
      </dl>
      <.link
        :if={@pool}
        href={"https://aerodrome.finance/swap?from=eth&to=#{@token.address}"}
        class="rg-button rg-button--secondary exposure__trade"
        target="_blank"
        rel="noopener"
      >
        Trade
      </.link>
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

  defp pool_price(nil), do: "No pool yet"
  defp pool_price(%{usdc_per_token: nil}), do: "No liquidity"
  defp pool_price(%{usdc_per_token: usdc}), do: F.usdc(usdc)

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

  defp return_note(%{status: :ended, stock: stock}),
    do: "The series has ended. Each token returns its own share of #{stock.symbol}."

  defp return_note(%{stock: stock}),
    do: "Return one of each token for one #{stock.symbol}, at any time."

  defp tab_path(series, tab, all) do
    query =
      [
        series: if(series.address != List.last(all), do: series.address),
        tab: if(tab == :return, do: "return")
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    if query == [], do: ~p"/after-hour-stocks", else: ~p"/after-hour-stocks?#{query}"
  end

  defp ticker(series), do: String.replace_suffix(series.stock.symbol, "c", "")

  defp short_hash("0x" <> hex),
    do: "0x" <> String.slice(hex, 0, 8) <> "…" <> String.slice(hex, -6, 6)
end
