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

  alias Autolaunch.Search
  alias Autolaunch.Stocks.UpcomingCatalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, AutolaunchWeb.PublicDocuments.page("/stocks"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = filters(params)
    chains = UpcomingCatalog.search(filters.q, filters.chain, filters.availability)

    count =
      Enum.sum_by(chains, fn chain ->
        length(chain.available) + length(chain.eligible) + length(chain.feed_required)
      end)

    {:noreply, assign(socket, filters: filters, chains: chains, count: count)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    query = params |> filters() |> Enum.reject(fn {_name, value} -> value == "" end)
    {:noreply, push_patch(socket, to: ~p"/stocks?#{query}")}
  end

  defp filters(params) do
    %{
      q: Search.normalize(params["q"]),
      chain: choice(params["chain"], ~w(base robinhood)),
      availability: choice(params["availability"], ~w(available soon feed_required))
    }
  end

  defp choice(value, allowed), do: if(value in allowed, do: value, else: "")

  @impl true
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

      <form
        id="stock-directory-filters"
        class="upcoming__filters"
        phx-submit="filter"
        action={~p"/stocks"}
        method="get"
      >
        <label>
          <span>Search stocks</span>
          <input type="search" name="q" value={@filters.q} placeholder="Name, ticker or address" />
        </label>
        <label>
          <span>Network</span>
          <select name="chain">
            <option value="" selected={@filters.chain == ""}>All networks</option>
            <option value="base" selected={@filters.chain == "base"}>Base</option>
            <option value="robinhood" selected={@filters.chain == "robinhood"}>Robinhood</option>
          </select>
        </label>
        <label>
          <span>Availability</span>
          <select name="availability">
            <option value="" selected={@filters.availability == ""}>All stocks</option>
            <option value="available" selected={@filters.availability == "available"}>
              Available to Pair
            </option>
            <option value="soon" selected={@filters.availability == "soon"}>Soon Available</option>
            <option value="feed_required" selected={@filters.availability == "feed_required"}>
              Feed Required
            </option>
          </select>
        </label>
        <button class="rg-button" type="submit">Apply</button>
        <.link
          :if={@filters.q != "" or @filters.chain != "" or @filters.availability != ""}
          patch={~p"/stocks"}
        >Reset</.link>
      </form>
      <p id="stock-directory-count" role="status">
        {if @count == 0,
          do: "No stocks match these filters.",
          else: "#{@count} #{if @count == 1, do: "stock", else: "stocks"}"}
      </p>

      <section
        :if={@count > 0 and @filters.availability in ["", "soon"]}
        class="fact-page__section"
        aria-labelledby="upcoming-eligible"
      >
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

      <section
        :if={@count > 0 and @filters.availability in ["", "available"]}
        class="fact-page__section"
        aria-labelledby="upcoming-available"
      >
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

      <section
        :if={@count > 0 and @filters.availability in ["", "feed_required"]}
        class="fact-page__section"
        aria-labelledby="upcoming-feed-required"
      >
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
