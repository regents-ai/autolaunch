defmodule AutolaunchWeb.UpcomingLive do
  @moduledoc """
  Stocks on Base and Robinhood, as a short list: each stock token is named with
  its issuer and chain and links to its own page (`AutolaunchWeb.StockLive`)
  with its addresses, links and dated pool research. The established Available to Pair list is preserved; new research
  remains in its preview sections and never changes launchpad admission.

  Above the lists, the stock products as the home page's cards: Memestock and
  covered calls.
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.HomeProducts, only: [product_cards: 1]
  import AutolaunchWeb.Components.StockIdentity, only: [stock_identity: 1]
  import AutolaunchWeb.Components.StockSelect, only: [stock_logo: 1]

  alias Autolaunch.Stocks.UpcomingCatalog

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(AutolaunchWeb.PublicDocuments.page("/stocks"))
     |> assign(chains: UpcomingCatalog.chains())}
  end

  def render(assigns) do
    ~H"""
    <div class="fact-page upcoming">
      <header class="autolaunch-heading">
        <h1>Onchain Stocks</h1>
      </header>

      <.product_cards
        launches_open={!Autolaunch.Prelaunch.read_only?()}
        only={~w(memestock calls)}
      />

      <section class="fact-page__section" aria-labelledby="upcoming-eligible">
        <h2 id="upcoming-eligible">Soon Available</h2>
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
        <h2 id="upcoming-feed-required">Feed Required</h2>
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
            navigate={~p"/stocks/#{stock["symbol"]}"}
            class="upcoming-stock"
            aria-label={"#{stock["symbol"]} on #{@chain.name}: stock details"}
          >
            <.stock_logo stock={%{symbol: stock["symbol"]}} />
            <span class="stock-select__symbol">{stock["symbol"]}</span>
            <span class="stock-select__name">{stock["name"]}</span>
            <.stock_identity :if={stock["token_address"]} chain={@chain.chain} />
          </.link>
        </li>
      </ul>
      <p :if={@stocks == []} class="upcoming-column__none">None right now.</p>
    </section>
    """
  end
end
