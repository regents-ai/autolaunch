defmodule AutolaunchWeb.Components.StockLists do
  @moduledoc """
  The home page's lists of stock products read from Base: the covered calls
  for sale, and the tokens of Isolated Exposure to After-hours Stocks, as a
  list and as gallery cards. Every row opens the product's own page, where
  every press goes to the wallet.
  """

  use Phoenix.Component

  import AutolaunchWeb.Components.MarketCard, only: [list_token: 1]

  alias Autolaunch.CoveredCalls.Terms
  alias AutolaunchWeb.Components.ChainIcon
  alias AutolaunchWeb.CoveredCallsFormat
  alias AutolaunchWeb.ExposureFormat

  attr :book, :map, required: true, doc: "a covered-call market's book, from `Book.read/1`"

  @doc "The calls for sale on a covered-call market, each opening its Buy panel."
  def call_list(assigns) do
    assigns =
      assign(assigns,
        open: Enum.filter(assigns.book.listings, &(Terms.stage(&1, assigns.book.now) == :open)),
        symbol: assigns.book.market.symbol
      )

    ~H"""
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
              <.link navigate={"/covered-calls?listing=#{listing.id}"} class="market-list__token">
                <span class="market-list__label">
                  <span class="market-list__name">
                    <strong>{@symbol} call</strong>
                    <small>Strike {CoveredCallsFormat.usd(listing.strike_per_token)}</small>
                  </span>
                </span>
              </.link>
            </th>
            <td data-label="Premium">
              {CoveredCallsFormat.usd(listing.premium_per_token)} <small>per {@symbol}</small>
            </td>
            <td data-label="Exercise">{CoveredCallsFormat.window_days(listing.expiry)}</td>
            <td data-label="Available">
              {CoveredCallsFormat.tokens(Terms.available(listing), @book.unit)} {@symbol}
            </td>
            <td class="market-list__action">
              <.link
                navigate={"/covered-calls?listing=#{listing.id}"}
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
    <div :if={@open == []} class="home-empty" role="status">
      <h2>No listings</h2>
      <p>Calls for sale show here as soon as a seller lists them.</p>
      <.link navigate="/covered-calls" class="rg-button rg-button--secondary">Sell calls</.link>
    </div>
    """
  end

  attr :tokens, :list, required: true, doc: "from `Autolaunch.Exposure.Listing.tokens/1`"

  attr :action, :boolean,
    default: false,
    doc: "the list has a Buy column, which these leave empty"

  @doc """
  Isolated Exposure tokens as rows of the tokens list: the token with its leg
  and term, its price and its market cap where its pool quotes a price. Each
  opens its series, where it is minted and returned.
  """
  def isolated_rows(assigns) do
    ~H"""
    <tr :for={token <- @tokens} id={"home-isolated-#{token.id}"} class="market-list__row">
      <.list_token
        name={token.name}
        symbol={token.symbol}
        chain="Base"
        path={series_path(token)}
        detail={"#{token.leg} · #{term(token)}"}
      />
      <td>{price(token)}</td>
      <td>{market_cap(token)}</td>
      <td :if={@action} class="market-list__action"></td>
    </tr>
    """
  end

  attr :tokens, :list, required: true, doc: "from `Autolaunch.Exposure.Listing.tokens/1`"

  @doc "Isolated Exposure tokens on their own: the list for the Isolated choice."
  def isolated_list(assigns) do
    ~H"""
    <div :if={@tokens != []} class="market-list__scroll">
      <table class="market-list__table market-list__table--tokens">
        <caption class="visually-hidden">Isolated tokens</caption>
        <thead>
          <tr>
            <th scope="col">Token</th>
            <th scope="col">Price</th>
            <th scope="col">Market cap</th>
          </tr>
        </thead>
        <tbody>
          <.isolated_rows tokens={@tokens} />
        </tbody>
      </table>
    </div>
    <div :if={@tokens == []} class="home-empty" role="status">
      <h2>No series</h2>
      <p>Each week's series shows here once it opens.</p>
      <.link navigate="/after-hour-stocks" class="rg-button rg-button--secondary">
        After-hours stocks
      </.link>
    </div>
    """
  end

  attr :token, :map, required: true, doc: "from `Autolaunch.Exposure.Listing.tokens/1`"

  @doc "One Isolated Exposure token as a gallery card, opening its series."
  def isolated_card(assigns) do
    ~H"""
    <article class="home-coin home-coin--isolated" id={"home-isolated-card-#{@token.id}"}>
      <.link navigate={series_path(@token)} class="home-coin__main">
        <div class="home-coin__art">
          <span class="home-coin__fallback" aria-hidden="true">{@token.stock}</span>
        </div>
        <p class="home-coin__pair">
          <span class="home-coin__ticker" title={@token.symbol}>{@token.symbol}</span>
          <ChainIcon.chain_chip chain="Base" label="Base" />
        </p>
        <h2 class="home-coin__name">{@token.name}</h2>
      </.link>
      <div class="home-coin__metric">
        <span>{price(@token)}</span><span>Price</span>
      </div>
      <p class="home-coin__figure">Market cap: <span>{market_cap(@token)}</span></p>
      <div class="home-coin__actions">
        <.link
          navigate={series_path(@token)}
          class="rg-button rg-button--secondary home-coin__action"
          aria-label={"Details for #{@token.name}"}
        >Details</.link>
      </div>
    </article>
    """
  end

  defp series_path(token), do: "/after-hour-stocks?series=#{token.series}"

  # A pool that holds nothing quotes no price, as one that is missing.
  defp price(%{usdc_per_token: quote}) when quote in [nil, 0], do: "No price yet"
  defp price(%{usdc_per_token: micro}), do: ExposureFormat.usdc(micro)

  # Every token in circulation at its pool's price, in USDC micro-units.
  defp market_cap(%{usdc_per_token: quote}) when quote in [nil, 0], do: "No price yet"

  defp market_cap(token),
    do:
      ExposureFormat.usdc(
        div(token.supply * token.usdc_per_token, Integer.pow(10, token.decimals))
      )

  defp term(token), do: "#{day(token.starts_at)} – #{day(token.ends_at)}"

  defp day(unix) do
    unix
    |> DateTime.from_unix!()
    |> DateTime.shift_zone!("America/New_York")
    |> Calendar.strftime("%a %-d %b")
  end
end
