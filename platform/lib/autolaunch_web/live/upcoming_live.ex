defmodule AutolaunchWeb.UpcomingLive do
  @moduledoc """
  Stocks on Base and Robinhood, as a short list: each stock links to its own
  page (`AutolaunchWeb.StockLive`) with its addresses, links and dated pool
  research. The established Available to Pair list is preserved; new research
  remains in its preview sections and never changes launchpad admission.
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.StockSelect, only: [stock_logo: 1]

  alias Autolaunch.Stocks.UpcomingCatalog

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(AutolaunchWeb.PublicDocuments.page("/stock-listing"))
     |> assign(chains: UpcomingCatalog.chains())}
  end

  def render(assigns) do
    ~H"""
    <div class="fact-page upcoming">
      <header class="autolaunch-heading">
        <h1>Onchain Stocks</h1>
        <p>
          Launch a pair with a meme ticker and earn from trading fees. Covered Call Options coming soon.
        </p>
        <p class="upcoming__hint">
          Open a stock for its addresses, company links and pool details.
          Research snapshot: 14 October 2026. Liquidity figures are dated observations, not live quotes.
        </p>
      </header>

      <section class="fact-page__section" aria-labelledby="upcoming-eligible">
        <h2 id="upcoming-eligible">Soon Available</h2>
        <p>Stocks with a matched Chainlink feed, not yet open for launches on Autolaunch.</p>
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
        <h2 id="upcoming-available" class="upcoming__pairing">
          <span>Available to Pair:</span>
          <a href="/create" class="standalone-link">Memestock</a>
          <span aria-hidden="true">|</span>
          <span
            class="upcoming__pairing-soon"
            title="Coming soon"
            aria-label="Dual Stock Token: Coming soon"
            tabindex="0"
          >Dual Stock Token</span>
        </h2>
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
    </div>
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
          <.link
            navigate={~p"/stock-listing/#{stock["symbol"]}"}
            class="upcoming-stock"
            aria-label={"#{stock["symbol"]} on #{@chain.name}: stock details"}
          >
            <.stock_logo stock={%{symbol: stock["symbol"]}} />
            <span class="stock-select__symbol">{stock["symbol"]}</span>
            <span class="stock-select__name">{stock["name"]}</span>
          </.link>
        </li>
      </ul>
      <p :if={@stocks == []} class="upcoming-column__none">None right now.</p>
    </section>
    """
  end
end
