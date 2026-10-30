defmodule AutolaunchWeb.StockLive do
  @moduledoc """
  One stock from the stock listing at `/stock-listing/<symbol>`: where it
  stands for launches, its onchain token and Chainlink feed, its company and
  market links, and its dated pool research, each pool with its venue,
  address and observed liquidity. A symbol the catalog does not hold is the
  site's 404.
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.StockSelect, only: [stock_logo: 1]

  alias Autolaunch.Stocks.UpcomingCatalog
  alias AutolaunchWeb.{NotFoundError, PublicDocuments, UsdValue}

  def mount(%{"symbol" => symbol}, _session, socket) do
    case UpcomingCatalog.stock(symbol) do
      nil ->
        raise NotFoundError

      {stock, chain} ->
        {:ok,
         socket
         |> assign(PublicDocuments.market_page(:stock, stock["name"], stock["symbol"]))
         |> assign(stock: stock, chain: chain, covered_calls?: covered_calls?(stock))}
    end
  end

  def render(assigns) do
    ~H"""
    <article class="fact-page upcoming-details">
      <header class="autolaunch-heading">
        <.link navigate={~p"/stock-listing"} class="market-back">← Onchain Stocks</.link>
        <div class="upcoming-details__heading">
          <.stock_logo stock={%{symbol: @stock["symbol"]}} />
          <div>
            <h1>{@stock["symbol"]} <span>· {@chain.name}</span></h1>
            <p>{@stock["name"]}</p>
          </div>
        </div>
      </header>
      <p :if={@stock["status"]} class="upcoming-details__status">{@stock["status"]}</p>
      <p :if={@stock["blocker"]} class="upcoming-details__note">{@stock["blocker"]}</p>
      <p :if={@covered_calls?} class="upcoming-details__action">
        <.link navigate={~p"/stock/covered-call"} class="rg-button">Covered calls on {@stock["symbol"]}</.link>
        <span>Sell calls on your {@stock["symbol"]} for a premium, or buy them.</span>
      </p>
      <dl class="upcoming-details__facts">
        <.address label="Onchain token address" value={@stock["token_address"]} id="token" />
        <.address label="Chainlink feed address" value={@stock["feed_address"]} id="feed" />
        <dt>Feed verification</dt><dd>{feed_note(@stock)}</dd>
        <dt>Company URL</dt>
        <dd>
          <.external
            :if={@stock["company_url"]}
            href={@stock["company_url"]}
            label={@stock["company_url"]}
          /><span :if={!@stock["company_url"]}>Not available</span>
        </dd>
        <dt>Real-world stock</dt>
        <dd>
          <.external :if={@stock["view_url"]} href={@stock["view_url"]} label="View ↗" /><span :if={
            !@stock["view_url"]
          }>Not available</span>
        </dd>
      </dl>
      <.pool :for={{pool, index} <- Enum.with_index(@stock["pools"], 1)} pool={pool} index={index} />
      <p :if={@stock["pools"] == []} class="upcoming-details__note">
        Pool 1: address and liquidity not available.
      </p>
      <p class="upcoming-details__note">
        Buy opens the pool's market page. Liquidity is a dated observation and may have changed.
        Research snapshot: 14 October 2026.
      </p>
    </article>
    """
  end

  # Covered calls are offered for a stock only while they are switched on and
  # its market is described.
  defp covered_calls?(stock),
    do:
      Autolaunch.CoveredCalls.Deployment.enabled?() and
        match?({:ok, _}, Autolaunch.CoveredCalls.Deployment.market(stock["symbol"]))

  attr :pool, :map, required: true
  attr :index, :integer, required: true

  defp pool(assigns) do
    ~H"""
    <section class="upcoming-details__pool" aria-label={"Pool #{@index}"}>
      <header>
        <h2>Pool {@index}<span :if={@pool["venue"]}> · {@pool["venue"]}</span></h2>
        <.external
          :if={@pool["buy_url"] && @pool["identifier"]}
          href={@pool["buy_url"]}
          label="Buy ↗"
        />
      </header>
      <dl class="upcoming-details__facts">
        <.address
          label={if @pool["kind"] == "v4", do: "Onchain pool ID", else: "Onchain pool address"}
          value={@pool["identifier"]}
          id={"pool-#{@index}"}
        />
        <.address
          :if={@pool["kind"] == "v4"}
          label="PoolManager address"
          value={@pool["manager"]}
          id={"manager-#{@index}"}
        />
        <dt>Liquidity depth</dt><dd>{liquidity(@pool["liquidity_usd"])}</dd>
        <dt>Observed</dt><dd>
          {@pool["observed_at"] || "Date not available"}<span :if={@pool["historical"]}> · Historical; current depth unknown</span>
        </dd>
      </dl>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, default: nil
  attr :id, :string, required: true

  defp address(assigns) do
    ~H"""
    <dt>{@label}</dt>
    <dd class="upcoming-details__address">
      <code :if={@value}>{@value}</code>
      <Regent.Primitives.copy_button
        :if={@value}
        id={"copy-#{@id}"}
        text={@value}
        variant="quiet"
        aria-label={"Copy #{@label}"}
      >Copy</Regent.Primitives.copy_button>
      <span :if={!@value}>Not verified</span>
    </dd>
    """
  end

  attr :href, :string, required: true
  attr :label, :string, required: true

  defp external(assigns) do
    ~H"""
    <a href={@href} target="_blank" rel="noopener noreferrer">{@label}</a>
    """
  end

  defp liquidity(nil), do: "Unknown"
  defp liquidity(usd), do: usd |> Decimal.new() |> UsdValue.dollars()

  defp feed_note(%{"feed_address" => nil}),
    do: "No verified same-chain feed address is available."

  defp feed_note(%{"section" => "available"}),
    do: "Current price is not checked here."

  defp feed_note(_stock),
    do: "Address identified; current price and token binding need verification."
end
