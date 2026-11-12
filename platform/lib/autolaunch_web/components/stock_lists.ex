defmodule AutolaunchWeb.Components.StockLists do
  @moduledoc """
  The home page's list of the covered calls for sale, read from Base. Every row
  opens the product's own page, where every press goes to the wallet.
  """

  use Phoenix.Component

  alias Autolaunch.CoveredCalls.{Deployment, Terms}
  alias AutolaunchWeb.CoveredCallsFormat

  attr :book, :map,
    required: true,
    doc: "a covered-call market's open listings, best first, from `Book.read/1`"

  @doc "The calls for sale on a covered-call market, each opening its Buy panel."
  def call_list(assigns) do
    assigns =
      assign(assigns,
        open: assigns.book.listings,
        symbol: assigns.book.market.symbol,
        stock: Deployment.identity(assigns.book.market)
      )

    ~H"""
    <p id="home-calls-read" class="home-calls__read">
      Read {Calendar.strftime(@book.read_at, "%-d %b, %H:%M UTC")}
    </p>
    <div :if={@open != []} class="market-list__scroll">
      <table class="market-list__table home-calls">
        <caption class="visually-hidden">Calls for sale on {@symbol}</caption>
        <thead>
          <tr>
            <th scope="col">Call</th>
            <th scope="col">Premium</th>
            <th scope="col">Exercise</th>
            <th scope="col">Available</th>
            <th scope="col"><span class="visually-hidden">Buy</span></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={listing <- @open} id={"home-call-#{listing.id}"} class="market-list__row">
            <th scope="row">
              <.link navigate={"/stock/covered-call?listing=#{listing.id}"} class="market-list__token">
                <span class="market-list__label">
                  <span class="market-list__name">
                    <strong>{@symbol} call · {@stock.issuer} · {@stock.chain}</strong>
                    <small>Strike {CoveredCallsFormat.usd(listing.strike_per_token)}</small>
                  </span>
                </span>
              </.link>
            </th>
            <td data-label="Premium">
              {CoveredCallsFormat.usd(listing.premium_per_token)} <small>per {@symbol}</small>
            </td>
            <td data-label="Exercise">{CoveredCallsFormat.window(listing.expiry)}</td>
            <td data-label="Available">
              {CoveredCallsFormat.tokens(Terms.available(listing), @book.unit)} {@symbol}
            </td>
            <td class="market-list__action">
              <.link
                navigate={"/stock/covered-call?listing=#{listing.id}"}
                class="rg-button rg-button--secondary"
                aria-label={"Buy #{@symbol} calls at #{CoveredCallsFormat.usd(listing.strike_per_token)}"}
              >
                Buy
              </.link>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <p :if={@book.listings_total > length(@open)} id="home-calls-more" class="home-calls__read">
      The best {length(@open)} of {@book.listings_total} listings
    </p>
    <div :if={@open == []} class="home-empty" role="status">
      <h2>No listings</h2>
      <p>Calls for sale show here within a few minutes of being listed.</p>
      <.link navigate="/stock/covered-call" class="rg-button rg-button--secondary">Sell calls</.link>
    </div>
    """
  end
end
