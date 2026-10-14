defmodule AutolaunchWeb.UpcomingLive do
  @moduledoc """
  The public Upcoming page: for Base and for Robinhood, the stocks next in line
  to be added, then the stocks a Memestock token can be paired with today.

  A stock is next in line when the hourly look
  (`Autolaunch.Stocks.StockCandidate`) last found a Chainlink price for it and
  more than $10,000 in its deepest dollar pool. That is advice from outside
  services, not a promise: a stock is added only when the Safe admits it on
  the chain's launchpad. The page shows a ticker and a pool size and links to
  no token. A stock already admitted is shown only under "Available to Pair",
  also in the hour before the look drops its row.
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.StockSelect, only: [stock_logo: 1, company: 1, compact_usd: 1]

  alias Autolaunch.Stocks.{Assets, PriceFeeds}

  @chains [base: "Base", robinhood: "Robinhood"]

  def mount(_params, _session, socket) do
    eligible = Enum.group_by(Autolaunch.eligible_stock_candidates!(), & &1.chain_id)

    chains =
      for {chain, name} <- @chains do
        available = Assets.all(chain)
        admitted = MapSet.new(available, &PriceFeeds.ticker(&1.symbol))

        %{
          chain: chain,
          name: name,
          available: Enum.map(available, &%{symbol: &1.symbol, note: company(&1)}),
          eligible:
            for %{ticker: ticker, liquidity_usd: usd} <-
                  Map.get(eligible, Assets.chain_id(chain), []),
                ticker not in admitted do
              %{symbol: ticker, note: "#{compact_usd(Decimal.to_float(usd))} liquidity"}
            end
        }
      end

    {:ok,
     socket
     |> assign(AutolaunchWeb.PublicDocuments.page("/upcoming"))
     |> assign(chains: chains)}
  end

  def render(assigns) do
    ~H"""
    <main class="fact-page upcoming">
      <header class="autolaunch-heading">
        <h1>Onchain Stocks</h1>
        <p>
          Launch a pair with a meme ticker and earn from trading fees. Covered Call Options coming soon.
        </p>
      </header>

      <section class="fact-page__section" aria-labelledby="upcoming-eligible">
        <h2 id="upcoming-eligible">Soon Available</h2>
        <p>A live Chainlink price and more than $10,000 of liquidity.</p>
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
    </main>
    """
  end

  attr :id, :string, required: true
  attr :chain, :map, required: true
  attr :stocks, :list, required: true, doc: "each a symbol and the few words under it"

  # One chain's column in the chain's own colour: its name and how many
  # stocks it lists, then the stocks, or a line saying there are none.
  defp column(assigns) do
    ~H"""
    <section class={"upcoming-column upcoming-column--#{@chain.chain}"} aria-labelledby={@id}>
      <h3 id={@id}>
        <span>{@chain.name}</span>
        <span>{length(@stocks)}</span>
      </h3>
      <ul :if={@stocks != []} class="upcoming-column__stocks">
        <li :for={stock <- @stocks} class="upcoming-stock">
          <.stock_logo stock={stock} />
          <span class="stock-select__symbol">{stock.symbol}</span>
          <span class="stock-select__name">{stock.note}</span>
        </li>
      </ul>
      <p :if={@stocks == []} class="upcoming-column__none">None right now.</p>
    </section>
    """
  end
end
