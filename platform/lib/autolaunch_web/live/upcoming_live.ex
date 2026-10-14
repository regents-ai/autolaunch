defmodule AutolaunchWeb.UpcomingLive do
  @moduledoc """
  Stocks on Base and Robinhood, with dated pool research in a native modal
  dialog. The established Available to Pair list is preserved; new research
  remains in its preview sections and never changes launchpad admission.
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.StockSelect, only: [stock_logo: 1, compact_usd: 1]

  alias Autolaunch.Stocks.UpcomingCatalog

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(AutolaunchWeb.PublicDocuments.page("/upcoming-stocks"))
     |> assign(chains: UpcomingCatalog.chains())}
  end

  def render(assigns) do
    ~H"""
    <main class="fact-page upcoming">
      <header class="autolaunch-heading">
        <h1>Onchain Stocks</h1>
        <p>
          Launch a pair with a meme ticker and earn from trading fees. Covered Call Options coming soon.
        </p>
        <p class="upcoming__hint">
          Select a stock for addresses, company links and pool details.
          Research snapshot: 14 October 2026. Liquidity figures are dated observations, not live quotes.
        </p>
      </header>

      <section class="fact-page__section" aria-labelledby="upcoming-eligible">
        <h2 id="upcoming-eligible">Soon Available</h2>
        <p>Stocks with a matched Chainlink feed, pending Autolaunch smart contract enablement.</p>
        <div class="upcoming__columns">
          <.column
            :for={chain <- @chains}
            id={"upcoming-eligible-#{chain.chain}"}
            chain={chain}
            stocks={chain.eligible}
          />
        </div>
      </section>

      <section class="fact-page__section" aria-labelledby="upcoming-available">
        <h2 id="upcoming-available">Available to Pair</h2>
        <div class="upcoming__columns">
          <.column
            :for={chain <- @chains}
            id={"upcoming-available-#{chain.chain}"}
            chain={chain}
            stocks={chain.available}
          />
        </div>
      </section>

      <section class="fact-page__section" aria-labelledby="upcoming-feed-required">
        <h2 id="upcoming-feed-required">Chainlink Feed Required</h2>
        <p>
          A matching Chainlink feed has not been identified. These stocks are not available to pair.
        </p>
        <div class="upcoming__columns">
          <.column
            :for={chain <- @chains}
            id={"upcoming-feed-required-#{chain.chain}"}
            chain={chain}
            stocks={chain.feed_required}
          />
        </div>
      </section>
    </main>
    """
  end

  attr :id, :string, required: true
  attr :chain, :map, required: true
  attr :stocks, :list, required: true

  defp column(assigns) do
    ~H"""
    <section class={"upcoming-column upcoming-column--#{@chain.chain}"} aria-labelledby={@id}>
      <h3 id={@id}><span>{@chain.name}</span><span>{length(@stocks)}</span></h3>
      <ul :if={@stocks != []} class="upcoming-column__stocks">
        <li :for={stock <- @stocks}>
          <button
            type="button"
            class="upcoming-stock"
            phx-click={JS.dispatch("autolaunch:open-dialog", to: "#stock-details-#{stock["id"]}")}
            aria-haspopup="dialog"
            aria-controls={"stock-details-#{stock["id"]}"}
            aria-label={"#{stock["symbol"]} on #{@chain.name}: stock details"}
          >
            <.stock_logo stock={%{symbol: stock["symbol"]}} />
            <span class="stock-select__symbol">{stock["symbol"]}</span>
            <span class="stock-select__name">{stock["name"]}</span>
          </button>
          <.details stock={stock} chain={@chain} />
        </li>
      </ul>
      <p :if={@stocks == []} class="upcoming-column__none">None right now.</p>
    </section>
    """
  end

  attr :stock, :map, required: true
  attr :chain, :map, required: true

  defp details(assigns) do
    ~H"""
    <dialog
      id={"stock-details-#{@stock["id"]}"}
      class="upcoming-details"
      aria-labelledby={"stock-title-#{@stock["id"]}"}
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <header class="upcoming-details__heading">
        <div>
          <h3 id={"stock-title-#{@stock["id"]}"}>{@stock["symbol"]} <span>· {@chain.name}</span></h3>
          <p>{@stock["name"]}</p>
        </div>
        <button
          type="button"
          class="rg-button rg-button--quiet"
          phx-click={JS.dispatch("autolaunch:close-dialog", to: "#stock-details-#{@stock["id"]}")}
          aria-label="Close stock details"
          autofocus
        >Close</button>
      </header>
      <p :if={@stock["status"]} class="upcoming-details__status">{@stock["status"]}</p>
      <p :if={@stock["blocker"]} class="upcoming-details__note">{@stock["blocker"]}</p>
      <dl class="upcoming-details__facts">
        <.address
          label="Onchain token address"
          value={@stock["token_address"]}
          id={"#{@stock["id"]}-token"}
        />
        <.address
          label="Chainlink feed address"
          value={@stock["feed_address"]}
          id={"#{@stock["id"]}-feed"}
        />
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
      <.pool
        :for={{pool, index} <- Enum.with_index(@stock["pools"], 1)}
        pool={pool}
        index={index}
        stock_id={@stock["id"]}
      />
      <p :if={@stock["pools"] == []} class="upcoming-details__note">
        Pool 1: address and liquidity not available.
      </p>
      <p class="upcoming-details__note">
        Buy opens the pool's market page. Liquidity is a dated observation and may have changed.
      </p>
    </dialog>
    """
  end

  attr :pool, :map, required: true
  attr :index, :integer, required: true
  attr :stock_id, :string, required: true

  defp pool(assigns) do
    ~H"""
    <section class="upcoming-details__pool" aria-label={"Pool #{@index}"}>
      <header>
        <h4>Pool {@index}<span :if={@pool["venue"]}> · {@pool["venue"]}</span></h4>
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
          id={"#{@stock_id}-pool-#{@index}"}
        />
        <.address
          :if={@pool["kind"] == "v4"}
          label="PoolManager address"
          value={@pool["manager"]}
          id={"#{@stock_id}-manager-#{@index}"}
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
  defp liquidity(usd), do: usd |> Decimal.new() |> Decimal.to_float() |> compact_usd()

  defp feed_note(%{"feed_address" => nil}),
    do: "No verified same-chain feed address is available."

  defp feed_note(%{"section" => "available"}),
    do: "Current price is not checked here."

  defp feed_note(_stock),
    do: "Address identified; current price and token binding need verification."
end
