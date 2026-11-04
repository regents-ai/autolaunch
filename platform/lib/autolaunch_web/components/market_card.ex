defmodule AutolaunchWeb.Components.MarketCard do
  @moduledoc false
  use Phoenix.Component

  import AutolaunchWeb.Components.LinkIcon

  alias Autolaunch.AuctionFigures
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.StoredImage
  alias Autolaunch.Token
  alias AutolaunchWeb.Components.{BidPlaced, ChainIcon, CreatorLabel}
  import AutolaunchWeb.Components.MinimumWarning
  alias AutolaunchWeb.{Paths, SwapComponent, TokenDisplay, UsdValue}
  require Phoenix.LiveView

  @own_sites ["autolaunch.sh", "regents.sh"]

  # What each auction figure means, on the list's headings and the gallery's figures.
  @tips %{
    fdv:
      "What the whole token supply is worth at the price bidders pay right now. It rises as bids push the price up.",
    volume: "Everything bidders have put in so far."
  }

  attr :kind, :atom, required: true, values: [:auction, :token]
  attr :record, :map, required: true
  attr :creator_connections, :map, default: %{}
  attr :trade_event, :string, default: nil

  attr :settle, :string,
    default: nil,
    doc: "the viewer's own Claim or Refund press, when they have one"

  attr :rate, :any,
    default: nil,
    doc: "the USD price of one unit of the record's currency, for its figures"

  attr :lead, :boolean, default: false, doc: "the page's first picture, which loads first"

  @doc """
  A gallery card. Every card reads, top to bottom: its ticker over its
  currency with its chain, its name, its price and one more figure, the
  creator's links.

  An auction's card shows only its clearing price up top, then its figures
  (on a Revstake auction the bid volume on hover or keyboard focus; the FDV
  always), Details and Bid, and a thin bar of how much of the auction's time
  has passed. The minimum is named only in an auction's last 30 minutes, and
  only while its bids are short of it. A token's card shows its price and
  market cap, then Details and Buy.
  """
  def explore_card(%{kind: :auction} = assigns) do
    figures = figures(assigns.record, assigns.rate)

    assigns =
      assign(assigns,
        view: view(:auction, assigns.record, assigns.creator_connections),
        figures: figures,
        bar: time_bar(assigns.record, figures)
      )

    ~H"""
    <.auction_card
      view={@view}
      figures={@figures}
      bar={@bar}
      lead={@lead}
      raise?={@record.kind == :agent}
      trade_event={@trade_event}
      settle={@settle}
    />
    """
  end

  def explore_card(%{kind: :token} = assigns) do
    view = view(:token, assigns.record, assigns.creator_connections)

    assigns =
      assign(assigns,
        view: view,
        market_cap:
          money(assigns.record.market_cap, assigns.rate, view.metric.unit) || "No price yet"
      )

    ~H"""
    <article
      class={["home-coin", @view.color && "home-coin--tinted"]}
      style={tint(@view.color)}
    >
      <.card_head view={@view} lead={@lead} />
      <div class="home-coin__metric">
        <.price_figure amount={@view.metric.amount} unit={@view.metric.unit} rate={@rate} /><span>Price</span>
      </div>
      <p class="home-coin__figure">Market cap: <span>{@market_cap}</span></p>
      <.card_links view={@view} />
      <div class="home-coin__actions">
        <.link
          navigate={@view.path}
          class="rg-button rg-button--secondary home-coin__action"
          aria-label={"Details for #{@view.name}"}
        >Details</.link>
        <Regent.Primitives.button
          :if={@trade_event && @view.buy}
          class="home-coin__action"
          phx-click={@trade_event}
          phx-value-id={@view.record_id}
          disabled={@view.buy.unavailable != nil}
          title={@view.buy.unavailable}
          aria-label={"Buy #{@view.name}"}
        >Buy</Regent.Primitives.button>
      </div>
    </article>
    """
  end

  attr :name, :string, required: true
  attr :symbol, :string, required: true
  attr :image, :string, default: nil
  attr :color, :string, default: nil, doc: "the image's colour, which tints the card"
  attr :website, :string, default: nil
  attr :chain, :string, required: true, values: ["Base", "Robinhood"]

  attr :unit, :string,
    default: nil,
    doc: "the currency bids are paid in: REGENT, or the paired stock, nil before one is chosen"

  attr :price, :string, default: nil, doc: "the auction's starting price, in the unit"
  attr :fdv, :any, default: nil, doc: "the whole supply at the starting price, in the unit"
  attr :rate, :any, default: nil, doc: "the USD price of one unit"

  attr :raise?, :boolean, default: false, doc: "a Revstake draft, which shows its bid volume"

  attr :creator_connections, :map, default: %{}

  @doc """
  A draft as the gallery will show its auction when it is listed: the same
  card as `explore_card/1`, at the starting price, with no bids and none of
  its time passed. Nothing on it can be pressed or followed. The creator's wallet is
  not among the links: which wallet launches is not known until it signs.
  """
  def draft_card(assigns) do
    assigns =
      assign(assigns,
        view: %{
          name: present(assigns.name, "Your token"),
          symbol: present(assigns.symbol, "TICKER"),
          image: assigns.image,
          color: assigns.color,
          website: assigns.website,
          metric: metric(assigns.price, assigns.unit, "No price yet"),
          path: nil,
          creator_address: nil,
          connections: connection_list(assigns.creator_connections),
          bid: %{unavailable: nil},
          record_id: nil,
          chain: assigns.chain
        },
        figures: %{
          fdv: money(assigns.fdv, assigns.rate, assigns.unit) || "No price yet",
          volume: money(Decimal.new(0), assigns.rate, assigns.unit),
          unpriced: if(is_nil(assigns.rate), do: assigns.unit),
          short_from: nil,
          ends_at: nil,
          id: "draft"
        },
        bar: %{progress: 0, opens_at: nil, label: state_label(:created)}
      )

    ~H"""
    <.auction_card view={@view} figures={@figures} bar={@bar} raise?={@raise?} preview />
    """
  end

  attr :view, :map, required: true
  attr :figures, :map, required: true
  attr :bar, :map, required: true
  attr :raise?, :boolean, default: false, doc: "a Revstake auction, which shows its bid volume"
  attr :trade_event, :string, default: nil
  attr :settle, :string, default: nil, doc: "the card's half-width button shows its first word"
  attr :preview, :boolean, default: false, doc: "a draft's card: shown whole, and inert"
  attr :lead, :boolean, default: false

  defp auction_card(assigns) do
    ~H"""
    <article
      class={["home-coin", @view.color && "home-coin--tinted"]}
      style={tint(@view.color)}
      inert={@preview}
    >
      <.card_head view={@view} lead={@lead} />
      <div class="home-coin__metric">
        <TokenDisplay.price amount={@view.metric.amount} unit={@view.metric.unit} /><span>Clearing price</span>
      </div>
      <.card_links view={@view} />
      <div class="home-coin__figures">
        <div :if={@raise?} class="home-coin__raise">
          <p>
            <span>Bid volume</span>
            <Regent.Primitives.tip id={"volume-#{@figures.id}"}>
              <:figure>{@figures.volume}</:figure>
              {tip(:volume)}
            </Regent.Primitives.tip>
            <.minimum_warning id={"short-#{@figures.id}"} from={@figures.short_from}>
              · below minimum
            </.minimum_warning>
          </p>
        </div>
        <p class="home-coin__floor">
          <span class="visually-hidden">FDV </span><Regent.Primitives.tip id={"fdv-#{@figures.id}"}>
            <:figure>{@figures.fdv}</:figure>
            {tip(:fdv, @figures.unpriced)}
          </Regent.Primitives.tip>
        </p>
      </div>
      <div class="home-coin__actions">
        <.link
          navigate={@view.path}
          class="rg-button rg-button--secondary home-coin__action"
          aria-label={"Details for #{@view.name}"}
        >Details</.link>
        <Regent.Primitives.button
          :if={(@trade_event || @preview) && @view.bid}
          class="home-coin__action"
          phx-click={@trade_event}
          phx-value-id={@view.record_id}
          disabled={@view.bid.unavailable != nil}
          title={@view.bid.unavailable}
          aria-label={"Bid on #{@view.name}"}
        >Bid</Regent.Primitives.button>
        <Regent.Primitives.button
          :if={@settle}
          class="home-coin__action"
          phx-click="open_settlement"
          phx-value-id={@view.record_id}
          aria-label={@settle}
          title={@settle}
        >{@settle |> String.split() |> hd()}</Regent.Primitives.button>
      </div>
      <div
        id={"time-bar-#{@figures.id}"}
        class={["home-coin__time", "home-coin__time--#{String.downcase(@view.chain)}"]}
        role="img"
        aria-label={@bar.label}
        title={@bar.label}
        phx-hook=".AuctionTimeBar"
        data-opens-at={@bar.opens_at && DateTime.to_iso8601(@bar.opens_at)}
        data-ends-at={@figures.ends_at && DateTime.to_iso8601(@figures.ends_at)}
      >
        <span :if={@bar.progress} style={"width: #{@bar.progress}%"}></span>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".AuctionTimeBar">
        export default {
          mounted() { this.tick() },
          updated() { this.tick() },
          destroyed() { clearTimeout(this.timer) },
          tick() {
            clearTimeout(this.timer)
            if (!this.el.dataset.endsAt) return
            const end = Date.parse(this.el.dataset.endsAt)
            const open = Date.parse(this.el.dataset.opensAt)
            const minutes = Math.max(Math.floor((end - Date.now()) / 60000), 0)
            const d = Math.floor(minutes / 1440)
            const rest = `${Math.floor((minutes % 1440) / 60)}h ${minutes % 60}m`
            const label = minutes === 0 ? "Live, ending" : `Live, ${d > 0 ? `${d}d ${rest}` : rest} left`
            this.el.setAttribute("aria-label", label)
            this.el.title = label
            const fill = this.el.firstElementChild
            if (fill && open < end) {
              fill.style.width = `${Math.min(Math.max((Date.now() - open) / (end - open), 0), 1) * 100}%`
            }
            this.timer = setTimeout(() => this.tick(), 1000 - (Date.now() % 1000))
          }
        }
      </script>
    </article>
    """
  end

  attr :auction, :map, required: true
  attr :rank, :integer, required: true
  attr :rate, :any, default: nil, doc: "the USD price of one unit of the auction's currency"

  @doc """
  One square in the home page's "Bid volume" row: the token's picture with its
  rank, its name and ticker, what bidders have put in and its state in words.
  It opens the auction's page.
  """
  def backed_card(assigns) do
    assigns =
      assign(assigns,
        view: view(:auction, assigns.auction, %{}),
        figures: figures(assigns.auction, assigns.rate)
      )

    ~H"""
    <.link navigate={@view.path} class="home-backed__card">
      <span class="home-backed__art">
        <img
          :if={present?(@view.image)}
          src={StoredImage.sized(@view.image, 640)}
          srcset={StoredImage.choices(@view.image)}
          sizes="(max-width: 42rem) calc(40vw - 32px), 320px"
          alt=""
          loading={@rank > 1 && "lazy"}
          fetchpriority={@rank == 1 && "high"}
          decoding="async"
          width="320"
          height="320"
        />
        <span :if={!present?(@view.image)} aria-hidden="true">{String.first(@view.name || "?")}</span>
        <span class="home-backed__rank"><span class="visually-hidden">Rank </span>{@rank}</span>
      </span>
      <span class="home-backed__name">
        <strong>{@view.name}</strong>
        <small>{@view.symbol}</small>
      </span>
      <span class="home-backed__figures">
        <span>{@figures.volume} raised</span>
        <span>{@view.status}</span>
      </span>
    </.link>
    """
  end

  attr :view, :map, required: true
  attr :lead, :boolean, required: true

  # The card's top, which opens its page: the image, the ticker over its
  # currency with the chain's box, and the name.
  defp card_head(assigns) do
    assigns =
      assign(
        assigns,
        :pair,
        Enum.join([assigns.view.symbol | List.wrap(assigns.view.metric.unit)], " / ")
      )

    ~H"""
    <.link navigate={@view.path} class="home-coin__main">
      <.coin_art view={@view} lead={@lead} />
      <p class="home-coin__pair">
        <span class="home-coin__ticker" title={@pair}>{@view.symbol}<span :if={@view.metric.unit}> /<wbr /> {@view.metric.unit}</span></span>
        <ChainIcon.chain_chip chain={@view.chain} label={chain_short(@view.chain)} />
      </p>
      <h2 class="home-coin__name">{@view.name}</h2>
    </.link>
    """
  end

  attr :view, :map, required: true

  defp card_links(assigns) do
    assigns =
      assign(assigns, :wallet, assigns.view.creator_address && wallet_link(assigns.view))

    ~H"""
    <div class="home-coin__links">
      <.card_socials connections={@view.connections} website={@view.website} wallet={@wallet} />
    </div>
    """
  end

  # The time bar is empty before an auction opens and full once it has
  # ended. A live auction whose opening time is unknown shows no fill.
  defp time_bar(%{state: :created}, figures),
    do: %{progress: 0, opens_at: nil, label: figures.status}

  defp time_bar(%{state: :active} = auction, %{ends_at: %DateTime{}} = figures) do
    label =
      if figures.status == "Ending", do: "Live, ending", else: "Live, #{figures.status} left"

    %{progress: figures.progress, opens_at: auction.opened_at, label: label}
  end

  defp time_bar(%{state: :active}, figures),
    do: %{progress: nil, opens_at: nil, label: figures.status}

  defp time_bar(_auction, figures), do: %{progress: 100, opens_at: nil, label: figures.status}

  attr :view, :map, required: true
  attr :lead, :boolean, required: true

  defp coin_art(assigns) do
    ~H"""
    <div class="home-coin__art">
      <img
        :if={present?(@view.image)}
        src={StoredImage.sized(@view.image, 640)}
        srcset={StoredImage.choices(@view.image)}
        sizes="(max-width: 22rem) calc(100vw - 76px), (max-width: 42rem) calc(50vw - 47px), 320px"
        alt={"#{@view.name} token"}
        loading={!@lead && "lazy"}
        fetchpriority={@lead && "high"}
        decoding="async"
        width="320"
        height="320"
      />
      <span :if={!present?(@view.image)} class="home-coin__fallback" aria-label="No token image">{String.first(
        @view.name || "?"
      )}</span>
    </div>
    """
  end

  attr :kind, :string, required: true, values: ["auctions", "tokens"]
  attr :options, :map, required: true, doc: "the list's `Autolaunch.HomeMarket` options"

  @doc """
  The filters above a list page's table: chain, status (auctions only), the
  creator's verified connections, and search. They send "filter" and "search".
  """
  def list_tools(assigns) do
    assigns =
      assign(
        assigns,
        :verified,
        assigns.options.x or assigns.options.ens or assigns.options.github
      )

    ~H"""
    <div class="market-list__tools">
      <form
        id={"#{@kind}-filter-form"}
        class="market-list__filters"
        phx-change="filter"
        phx-submit="filter"
      >
        <label class="rg-pill-select">
          <span class="visually-hidden">Chain</span>
          <select name="chain" aria-label="Chain">
            <option
              :for={
                {value, label} <- [
                  {"all", "All chains"},
                  {"base", "Base"},
                  {"robinhood", "Robinhood"}
                ]
              }
              value={value}
              selected={@options.chain == value}
            >
              {label}
            </option>
          </select>
        </label>
        <label :if={@kind == "auctions"} class="rg-pill-select">
          <span class="visually-hidden">Status</span>
          <select name="state" aria-label="Status">
            <option
              :for={
                {value, label} <- [
                  {"all", "Any status"},
                  {"created", "Opening soon"},
                  {"active", "Live"},
                  {"ended", "Waiting to finish"},
                  {"graduated", "Graduated"},
                  {"failed", "Minimum not met"}
                ]
              }
              value={value}
              selected={@options.state == value}
            >
              {label}
            </option>
          </select>
        </label>
        <details
          id={"#{@kind}-verified"}
          class={["rg-pill-select market-list__verified-menu", @verified && "is-active"]}
          phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
        >
          <summary>Verified</summary>
          <fieldset {AutolaunchWeb.Motion.panel("menu")}>
            <legend>Creator has verified</legend>
            <label :for={{key, label} <- [x: "X", ens: "ENS", github: "GitHub"]}>
              <input type="hidden" name={key} value="false" />
              <input type="checkbox" name={key} value="true" checked={Map.fetch!(@options, key)} />
              {label}
            </label>
            <small>Shows {@kind} whose creator has every one you tick.</small>
          </fieldset>
        </details>
      </form>
      <form id={"#{@kind}-search"} class="market-list__search" phx-submit="search" phx-change="search">
        <label>
          <span class="visually-hidden">Search {@kind}</span>
          <input
            type="search"
            name="q"
            value={@options.q}
            placeholder="Search name, ticker, stock, creator or address"
            phx-debounce="300"
            autocomplete="off"
          />
        </label>
      </form>
    </div>
    """
  end

  attr :records, :list, required: true, doc: "auctions with `fdv` loaded"
  attr :rates, :any, required: true, doc: "the dollar prices from `assign_figure_rates/1`"

  attr :creators, :map,
    required: true,
    doc: "the creators' connected accounts, from `creator_connections_for/1`"

  attr :loading, :boolean, default: false

  attr :trade_event, :string,
    default: nil,
    doc: "the event a row's Bid button sends with the auction's id; no Bid column without it"

  attr :settle, :map,
    default: %{},
    doc:
      "the viewer's own Claim or Refund press on each finished auction they bid in, by auction id"

  @doc """
  The auctions list: the token with its creator and age, then its price, what
  bidders have put in, its market cap and its status, and a Bid button on a
  live auction when the page takes bids. Between the token and its price, a
  graduated auction shows a Buy link to its token's page while the row is
  pointed at, and a finished auction the viewer has money or tokens to take
  from shows that press. On a phone each row shows one figure instead of the
  price, raise and market cap: what bidders have put in while the auction can
  still take bids, its price once it has finished.
  """
  def auction_list(assigns) do
    ~H"""
    <div class="market-list__scroll">
      <table class="market-list__table market-list__table--auctions">
        <caption class="visually-hidden">Auctions</caption>
        <thead>
          <tr>
            <th scope="col">Token</th>
            <th scope="col"><span class="visually-hidden">Buy or take your bid</span></th>
            <th scope="col">Price</th>
            <th scope="col">
              Raised
              <Regent.Primitives.tip id="auctions-volume" label="About raised">
                {tip(:volume)}
              </Regent.Primitives.tip>
            </th>
            <th scope="col">
              Market cap
              <Regent.Primitives.tip id="auctions-fdv" label="About market cap">
                {tip(:fdv)}
              </Regent.Primitives.tip>
            </th>
            <th scope="col">Status</th>
            <th :if={@trade_event} scope="col"><span class="visually-hidden">Bid</span></th>
            <th scope="col" class="market-list__key">
              <span class="visually-hidden">Raised so far, or the price once finished</span>
            </th>
          </tr>
        </thead>
        <tbody>
          <.auction_list_row
            :for={record <- @records}
            view={view(:auction, record, connections_for(record, @creators))}
            figures={figures(record, figure_rate(@rates, record))}
            rate={figure_rate(@rates, record)}
            trade_event={@trade_event}
            settle={@settle[record.id]}
          />
          <tr
            :for={index <- 1..6}
            :if={@loading && @records == []}
            id={"auctions-loading-#{index}"}
            class="market-list__skeleton"
            aria-hidden="true"
          >
            <td colspan={if @trade_event, do: "8", else: "7"}><span class="loading-block"></span></td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp tip(figure), do: Map.fetch!(@tips, figure)

  # A figure shown in its own currency says why it is not in dollars.
  defp tip(figure, nil), do: tip(figure)

  defp tip(figure, unit),
    do:
      "#{tip(figure)} There is no dollar price for #{unit} right now, so it is shown in #{unit}."

  # A row is handed only what it shows, so a reread that changes nothing shown,
  # such as the site's own note of when it last checked an auction, sends the
  # page nothing for that row.
  attr :view, :map, required: true
  attr :figures, :map, required: true
  attr :rate, :any, default: nil
  attr :trade_event, :string, default: nil
  attr :settle, :string, default: nil

  defp auction_list_row(assigns) do
    ~H"""
    <tr class="market-list__row">
      <.list_token
        name={@view.name}
        symbol={@view.symbol}
        unit={@view.metric.unit}
        image={@view.image}
        chain={@view.chain}
        path={@view.path}
        detail={byline(@view)}
      />
      <td class="market-list__quick">
        <.link
          :if={@view.token_path}
          navigate={@view.token_path}
          class="rg-button rg-button--secondary market-list__buy"
          aria-label={"Buy #{@view.name}"}
        ><span class="rg-button__label">Buy</span></.link>
        <Regent.Primitives.button
          :if={@settle}
          phx-click="open_settlement"
          phx-value-id={@view.record_id}
          aria-label={@settle}
        >{settle_word(@settle)}<span class="market-list__rest">{settle_rest(@settle)}</span></Regent.Primitives.button>
      </td>
      <td>
        <.price_figure amount={@view.metric.amount} unit={@view.metric.unit} rate={@rate} />
      </td>
      <td>
        {@figures.volume}
        <.minimum_warning
          id={"short-#{@figures.id}"}
          from={@figures.short_from}
          tag="small"
        >
          Below minimum
        </.minimum_warning>
      </td>
      <td>{@figures.fdv}</td>
      <td class="market-list__status">
        <.status_figure figures={@figures} chain={@view.chain} />
      </td>
      <td :if={@trade_event} class="market-list__action">
        <Regent.Primitives.button
          :if={@view.bid}
          variant="secondary"
          phx-click={@trade_event}
          phx-value-id={@view.record_id}
          disabled={@view.bid.unavailable != nil}
          title={@view.bid.unavailable}
          aria-label={"Bid on #{@view.name}"}
        >Bid</Regent.Primitives.button>
      </td>
      <td class="market-list__key">
        <span :if={@figures.state in [:graduated, :failed]}>
          <small>Price</small>
          <.price_figure amount={@view.metric.amount} unit={@view.metric.unit} rate={@rate} />
        </span>
        <span :if={@figures.state not in [:graduated, :failed]}>
          <small>Raised</small> {@figures.volume}
        </span>
      </td>
    </tr>
    """
  end

  # A phone shows the press's first word; the amount is in the card it opens.
  defp settle_word(settle), do: settle |> String.split(" ", parts: 2) |> hd()

  defp settle_rest(settle) do
    case String.split(settle, " ", parts: 2) do
      [_word, rest] -> " " <> rest
      [_word] -> nil
    end
  end

  # Who made it and how long ago, under a list row's name.
  defp byline(view),
    do:
      [view.creator && "by #{view.creator}", view.age]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

  attr :records, :list, required: true, doc: "launched tokens with `market_cap` loaded"
  attr :rates, :any, required: true, doc: "the dollar prices from `assign_figure_rates/1`"

  attr :creators, :map,
    required: true,
    doc: "the creators' connected accounts, from `creator_connections_for/1`"

  attr :loading, :boolean, default: false

  attr :trade_event, :string,
    default: nil,
    doc: "the event a row's Buy button sends with the token's id; no Buy column without it"

  @doc """
  The tokens list: the token with its creator and when it launched, then its
  price and market cap, and a Buy button when the page trades. On a phone the
  market cap is left out.
  """
  def token_list(assigns) do
    ~H"""
    <div class="market-list__scroll">
      <table class="market-list__table market-list__table--tokens">
        <caption class="visually-hidden">Tokens</caption>
        <thead>
          <tr>
            <th scope="col">Token</th>
            <th scope="col">Price</th>
            <th scope="col">Market cap</th>
            <th :if={@trade_event} scope="col"><span class="visually-hidden">Buy</span></th>
          </tr>
        </thead>
        <tbody>
          <.token_list_row
            :for={token <- @records}
            token={token}
            connections={connections_for(token, @creators)}
            rate={figure_rate(@rates, token.auction)}
            trade_event={@trade_event}
          />
          <tr
            :for={index <- 1..6}
            :if={@loading && @records == []}
            id={"tokens-loading-#{index}"}
            class="market-list__skeleton"
            aria-hidden="true"
          >
            <td colspan={if @trade_event, do: "4", else: "3"}><span class="loading-block"></span></td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :token, :map, required: true
  attr :connections, :map, required: true
  attr :rate, :any, default: nil
  attr :trade_event, :string, default: nil

  defp token_list_row(assigns) do
    view = view(:token, assigns.token, assigns.connections)

    assigns =
      assign(assigns,
        view: view,
        market_cap:
          money(assigns.token.market_cap, assigns.rate, view.metric.unit) || "No price yet"
      )

    ~H"""
    <tr class="market-list__row">
      <.list_token
        name={@view.name}
        symbol={@view.symbol}
        unit={@view.metric.unit}
        image={@view.image}
        chain={@view.chain}
        path={@view.path}
        detail={byline(@view)}
      />
      <td>
        <.price_figure amount={@token.price_quote} unit={@view.metric.unit} rate={@rate} />
      </td>
      <td>{@market_cap}</td>
      <td :if={@trade_event} class="market-list__action">
        <Regent.Primitives.button
          :if={@view.buy}
          variant="secondary"
          phx-click={@trade_event}
          phx-value-id={@view.record_id}
          disabled={@view.buy.unavailable != nil}
          title={@view.buy.unavailable}
          aria-label={"Buy #{@view.name}"}
        >Buy</Regent.Primitives.button>
      </td>
    </tr>
    """
  end

  attr :kind, :atom, required: true, values: [:auction, :token]
  attr :record, :map, required: true, doc: "an auction with `fdv` or a token with `market_cap`"
  attr :rates, :any, required: true, doc: "the dollar prices from `assign_figure_rates/1`"

  @doc """
  One search result: the token cell as the lists show it, then an auction's
  value over its time left, or its outcome bar once finished, or a token's
  price and market cap. It opens the record's page.
  """
  def search_result(%{kind: :auction, record: auction} = assigns) do
    assigns =
      assign(assigns,
        view: view(:auction, auction, %{}),
        figures: figures(auction, figure_rate(assigns.rates, auction))
      )

    ~H"""
    <.link navigate={@view.path} class="search-result" data-search-result>
      <span class="market-list__token">
        <.list_token_contents
          name={@view.name}
          symbol={@view.symbol}
          unit={nil}
          image={@view.image}
          chain={@view.chain}
        />
      </span>
      <span class="search-result__figures">
        <strong>{@figures.fdv}</strong>
        <.outcome_figure :if={@figures.outcome} figures={@figures} />
        <small :if={!@figures.outcome}>{@figures.status}</small>
      </span>
    </.link>
    """
  end

  def search_result(%{kind: :token, record: token} = assigns) do
    view = view(:token, token, %{})
    rate = figure_rate(assigns.rates, token.auction)

    assigns =
      assign(assigns,
        view: view,
        rate: rate,
        market_cap: money(token.market_cap, rate, view.metric.unit)
      )

    ~H"""
    <.link navigate={@view.path} class="search-result" data-search-result>
      <span class="market-list__token">
        <.list_token_contents
          name={@view.name}
          symbol={@view.symbol}
          unit={nil}
          image={@view.image}
          chain={@view.chain}
        />
      </span>
      <span class="search-result__figures">
        <strong>
          <.price_figure amount={@record.price_quote} unit={@view.metric.unit} rate={@rate} />
        </strong>
        <small :if={@market_cap}>{@market_cap} market cap</small>
      </span>
    </.link>
    """
  end

  attr :name, :string, required: true
  attr :symbol, :string, required: true

  attr :unit, :string,
    default: nil,
    doc: "the currency the token is paired with, after its ticker"

  attr :image, :string, default: nil
  attr :chain, :string, required: true, values: ["Base", "Robinhood"]
  attr :path, :string, default: nil, doc: "the token's or auction's page; nil when it has none"
  attr :detail, :string, default: nil, doc: "a short line under the name, such as its creator"

  @doc """
  The cell every list row starts with: the token's image with its chain's
  badge, then its name and its ticker on one line, the ticker followed by its
  paired currency when one is given, and `detail` under them when given. It
  opens `path` when there is one.
  """
  def list_token(assigns) do
    ~H"""
    <th scope="row">
      <.link :if={@path} navigate={@path} class="market-list__token">
        <.list_token_contents {assigns} />
      </.link>
      <span :if={!@path} class="market-list__token">
        <.list_token_contents {assigns} />
      </span>
    </th>
    """
  end

  defp list_token_contents(assigns) do
    assigns = assign_new(assigns, :detail, fn -> nil end)

    ~H"""
    <span class="market-list__art">
      <img
        :if={present?(@image)}
        src={StoredImage.sized(@image, 96)}
        alt=""
        loading="lazy"
        decoding="async"
        width="40"
        height="40"
      />
      <span :if={!present?(@image)} aria-hidden="true">{String.first(@name || "?")}</span>
      <ChainIcon.chain_icon
        chain={if @chain == "Robinhood", do: :robinhood, else: :base}
        class="market-list__chain"
      />
    </span>
    <span class="market-list__label">
      <span class="market-list__name">
        <strong>{@name}</strong>
        <small><.token_pair symbol={@symbol} unit={@unit} /></small>
      </span>
      <small :if={present?(@detail)} class="market-list__detail">{@detail}</small>
    </span>
    """
  end

  attr :symbol, :string, required: true
  attr :unit, :string, default: nil, doc: "the currency the token is paired with"

  # A token's ticker and the currency it trades against, as `BITE / AAPLc`.
  defp token_pair(assigns) do
    ~H"""
    {@symbol}<span :if={@unit} class="token-pair__unit"> / {@unit}</span>
    """
  end

  attr :amount, :string, default: nil, doc: "a price per token in its currency"
  attr :unit, :string, default: nil, doc: "the currency the price is in"

  attr :rate, :any,
    default: nil,
    doc: "the USD price of one unit of that currency, nil while none is known"

  @doc """
  A price per token in dollars where the currency's dollar price is known,
  otherwise in the currency itself.
  """
  def price_figure(assigns) do
    price = decimal(assigns.amount)

    assigns =
      assign(
        assigns,
        :usd,
        price && assigns.rate && UsdValue.dollars(Decimal.mult(price, assigns.rate))
      )

    ~H"""
    <span :if={@usd}>{@usd}</span>
    <TokenDisplay.price :if={!@usd} amount={@amount} unit={@unit} />
    """
  end

  @doc """
  Reads the dollar prices the auction figures use into `:rates`, in the
  background: REGENT's price and each chain's stock prices. A test network's
  coins carry no dollar value, so its prices stay unknown.
  """
  def assign_figure_rates(socket),
    do: Phoenix.LiveView.assign_async(socket, :rates, fn -> {:ok, %{rates: UsdValue.rates()}} end)

  @doc "The USD price of one unit of the auction's currency; nil while none is known."
  def figure_rate(%{ok?: true, result: rates}, auction), do: UsdValue.auction_rate(rates, auction)

  def figure_rate(_rates, _auction), do: nil

  defp figures(auction, rate) do
    unit = auction.quote_token_symbol

    %{
      fdv: money(auction.fdv, rate, unit) || "No price yet",
      volume: volume(auction),
      unpriced: if(is_nil(rate), do: unit),
      short_from: AuctionFigures.minimum_warning_from(auction),
      progress: time_progress(auction),
      opens_at: live_open(auction),
      ends_at: live_end(auction),
      status: figure_status(auction),
      outcome: outcome(auction),
      state: auction.state,
      id: auction.id
    }
  end

  # Everything bidders put in: in dollars when the site has priced it, else in
  # the auction's currency.
  defp volume(auction) do
    money(auction.bid_volume_usd, Decimal.new(1)) ||
      money(auction.bid_volume, nil, auction.quote_token_symbol) || "Not counted yet"
  end

  @doc """
  An amount in dollars where its currency's dollar price is known, otherwise
  in the currency itself; nil while the amount is not known.
  """
  def money(amount, rate, unit \\ nil)
  def money(nil, _rate, _unit), do: nil

  def money(%Decimal{} = amount, nil, unit),
    do: String.trim("#{TokenDisplay.short(amount)} #{unit}")

  def money(%Decimal{} = amount, rate, _unit), do: UsdValue.dollars(Decimal.mult(amount, rate))

  # Stored prices can run past a hundred decimal places.
  defp decimal(value) when is_binary(value) do
    case Decimal.parse(String.trim(value), max_digits: :infinity) do
      {%Decimal{} = decimal, ""} -> decimal
      _unparsed -> nil
    end
  end

  defp decimal(_value), do: nil

  # How much of a live auction's time has passed, from its opening to its
  # estimated end, as a whole percent.
  defp time_progress(%{
         state: :active,
         opened_at: %DateTime{} = opened_at,
         estimated_end_at: %DateTime{} = end_at
       }) do
    total = DateTime.diff(end_at, opened_at)

    if total > 0,
      do:
        DateTime.utc_now()
        |> DateTime.diff(opened_at)
        |> Kernel.*(100)
        |> div(total)
        |> min(100)
        |> max(0)
  end

  defp time_progress(_auction), do: nil

  defp live_open(%{state: :active, opened_at: %DateTime{} = opened_at}), do: opened_at
  defp live_open(_auction), do: nil

  defp live_end(%{state: :active, estimated_end_at: %DateTime{} = end_at}), do: end_at
  defp live_end(_auction), do: nil

  defp figure_status(%{state: :active, estimated_end_at: %DateTime{} = end_at}),
    do: time_left(max(DateTime.diff(end_at, DateTime.utc_now()), 0))

  defp figure_status(%{state: :graduated} = auction), do: ended("Graduated", auction)
  defp figure_status(%{state: :failed} = auction), do: ended("Minimum not met", auction)
  defp figure_status(%{state: state}), do: state_label(state)

  # Days, hours and minutes, never seconds; the last minute reads "Ending".
  # The page's tickers write the same wording as the time runs down.
  defp time_left(seconds) when seconds < 60, do: "Ending"

  defp time_left(seconds) do
    days = div(seconds, 86_400)
    rest = "#{div(rem(seconds, 86_400), 3600)}h #{div(rem(seconds, 3600), 60)}m"
    if days > 0, do: "#{days}d #{rest}", else: rest
  end

  defp ended(label, %{estimated_end_at: %DateTime{} = end_at}),
    do: "#{label} #{ended_ago(end_at)}"

  defp ended(label, _auction), do: label

  # How a finished auction came out, as its bar's fill and the few words under
  # it: a full bar once graduated; no bar, only the words, when the minimum
  # was not met.
  defp outcome(%{state: :graduated}), do: %{fill: 100, label: "Graduated"}
  defp outcome(%{state: :failed}), do: %{fill: nil, label: "Minimum not met"}

  defp outcome(_auction), do: nil

  attr :id, :string, required: true, doc: "unique on the page, for the ticking time left"
  attr :auction, :map, required: true

  @doc "The auctions list's status figure for one stored auction, outside the list."
  def auction_status(assigns) do
    auction = assigns.auction

    assigns =
      assign(assigns,
        figures: %{
          id: assigns.id,
          progress: time_progress(auction),
          opens_at: live_open(auction),
          ends_at: live_end(auction),
          status: figure_status(auction),
          outcome: outcome(auction),
          state: auction.state
        },
        chain: if(RobinhoodLab.chain?(auction.chain_id), do: "Robinhood", else: "Base")
      )

    ~H"""
    <.status_figure figures={@figures} chain={@chain} />
    """
  end

  attr :figures, :map, required: true
  attr :chain, :string, required: true, values: ["Base", "Robinhood"]

  # A live auction's time bar in its chain's colour over its time left, both
  # kept moving in the browser. A finished auction's outcome bar: full and
  # ticked once graduated, else filled as far as the minimum was met, with when
  # it ended on hover. Any other state's word. A live auction whose opening
  # time is unknown shows an empty bar.
  defp status_figure(assigns) do
    ~H"""
    <span
      :if={@figures.ends_at}
      id={"time-left-#{@figures.id}"}
      phx-hook=".AuctionTimeLeft"
      data-opens-at={@figures.opens_at && DateTime.to_iso8601(@figures.opens_at)}
      data-ends-at={DateTime.to_iso8601(@figures.ends_at)}
    >
      <span
        class={["auction-figures__time", "auction-figures__time--#{String.downcase(@chain)}"]}
        aria-hidden="true"
      >
        <span :if={@figures.progress} style={"width: #{@figures.progress}%"}></span>
      </span>
      <small>{@figures.status}</small>
    </span>
    <.outcome_figure :if={@figures.outcome} figures={@figures} />
    <span
      :if={!@figures.ends_at && !@figures.outcome}
      class="auction-state"
      data-state={@figures.state}
    >
      {@figures.status}
    </span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".AuctionTimeLeft">
      export default {
        mounted() { this.tick() },
        updated() { this.tick() },
        destroyed() { clearTimeout(this.timer) },
        tick() {
          clearTimeout(this.timer)
          const end = Date.parse(this.el.dataset.endsAt)
          const open = Date.parse(this.el.dataset.opensAt)
          const minutes = Math.max(Math.floor((end - Date.now()) / 60000), 0)
          const d = Math.floor(minutes / 1440)
          const rest = `${Math.floor((minutes % 1440) / 60)}h ${minutes % 60}m`
          this.el.querySelector("small").textContent = minutes === 0 ? "Ending" : d > 0 ? `${d}d ${rest}` : rest
          const fill = this.el.querySelector(".auction-figures__time > span")
          if (fill && open < end) {
            fill.style.width = `${Math.min(Math.max((Date.now() - open) / (end - open), 0), 1) * 100}%`
          }
          this.timer = setTimeout(() => this.tick(), 1000 - (Date.now() % 1000))
        }
      }
    </script>
    """
  end

  attr :figures, :map, required: true

  # A finished auction's outcome bar over its few words, with when it ended on
  # hover.
  defp outcome_figure(assigns) do
    ~H"""
    <span class="auction-outcome" data-state={@figures.state} title={@figures.status}>
      <span class="auction-figures__time" aria-hidden="true">
        <span :if={@figures.outcome.fill} style={"width: #{@figures.outcome.fill}%"}></span>
      </span>
      <small>
        <svg :if={@figures.state == :graduated} viewBox="0 0 16 16" aria-hidden="true">
          <path d="m3 8.5 3.2 3L13 4.5" />
        </svg>{@figures.outcome.label}
      </small>
    </span>
    """
  end

  attr :kind, :atom,
    required: true,
    values: [:auction, :token]

  attr :record, :map, required: true

  attr :trade_path, :string,
    default: nil,
    doc: "set once the coin trades; takes the description's place"

  attr :status, :string,
    default: nil,
    doc: "the page's own reading of the state, when the record's state label lags the chain"

  slot :price_note, doc: "shown after the price, such as its dollar value"

  slot :figures,
    doc:
      "a token page's own figures, in the price's place (`AutolaunchWeb.Components.TokenFigures`)"

  slot :chart, doc: "the price chart, across the card under the image and the price"

  def detail_card(assigns) do
    assigns =
      assign(assigns, :view, view(assigns.kind, assigns.record, %{}))

    ~H"""
    <section
      id="coin-overview"
      class={["market-identity", @view.color && "market-identity--tinted"]}
      style={tint(@view.color)}
      phx-hook={@view.color && "ImageGradient"}
      aria-label="Coin overview"
    >
      <canvas
        :if={@view.color}
        id="coin-overview-gradient"
        class="market-identity__gradient"
        phx-update="ignore"
        aria-hidden="true"
      ></canvas>
      <div class="market-identity__image">
        <img
          :if={present?(@view.image)}
          src={StoredImage.sized(@view.image, 640)}
          srcset={StoredImage.choices(@view.image)}
          sizes="(max-width: 42rem) 220px, 240px"
          alt={"#{@view.name} token"}
          width="240"
          height="240"
          fetchpriority="high"
          decoding="async"
        />
        <span :if={!present?(@view.image)} aria-label="No token image">{String.first(
          @view.name || "?"
        )}</span>
      </div>
      <div class="market-identity__body">
        <p class="market-identity__symbol">
          <.token_pair symbol={@view.symbol} unit={@view.metric.unit} />
        </p>
        <div class="market-identity__meta">
          <ChainIcon.chain_chip chain={@view.chain} label={@view.chain} />
          <Regent.Primitives.status
            :if={@kind == :auction}
            tone={state_tone(@status || @view.status)}
            class={graduated(@status || @view.status)}
          >
            {@status || @view.status}
          </Regent.Primitives.status>
          <span :if={@kind == :auction && @view.age}>{@view.age}</span>
        </div>
        {render_slot(@figures)}
        <div :if={@figures == []} class="market-identity__price">
          <span>{@view.metric_label}</span><TokenDisplay.price
            amount={@view.metric.amount}
            unit={@view.metric.unit}
            fallback={@view.metric.empty}
          />
          {render_slot(@price_note)}
        </div>
        <.link
          :if={@trade_path}
          navigate={@trade_path}
          class="rg-button rg-button--primary market-identity__trade"
        ><span class="rg-button__label">Trade {@view.symbol}
        <span class="market-identity__trade-arrow" aria-hidden="true">→</span></span></.link>
        <p
          :if={!@trade_path && present?(@view.description)}
          class="market-identity__description"
        >
          {@view.description}
        </p>
      </div>
      <div :if={@chart != []} class="market-identity__chart">{render_slot(@chart)}</div>
    </section>
    """
  end

  attr :auction, :map, required: true, doc: "a graduated auction, with `fdv` loaded"

  attr :market_cap, :any,
    required: true,
    doc: "its token's market cap now, in the auction's currency; nil while it has no price"

  attr :connections, :map, default: nil, doc: "the creator's connected accounts"

  attr :rate, :any,
    default: nil,
    doc:
      "the USD price of one unit of the auction's currency, nil while none is known, or :test_network"

  @doc """
  The first thing on a graduated auction's page: that the auction is over and
  the way on to its token's page, beside the token, who made it and their
  links, what bidders put in, and its market cap at the auction's final price
  and now.
  """
  def finished_auction(assigns) do
    %{auction: auction} = assigns
    view = view(:auction, auction, assigns.connections)
    # A test network's coins carry no dollar value, so its figures stay in the currency.
    rate = if assigns.rate == :test_network, do: nil, else: assigns.rate

    assigns =
      assign(assigns,
        view: view,
        volume: volume(auction),
        starting: money(auction.fdv, rate, auction.quote_token_symbol) || "No price yet",
        current: money(assigns.market_cap, rate, auction.quote_token_symbol) || "No price yet"
      )

    ~H"""
    <section
      id="auction-finished"
      class={["auction-finished", @view.color && "auction-finished--tinted"]}
      style={tint(@view.color)}
      aria-labelledby="auction-finished-title"
    >
      <div class="auction-finished__next">
        <h2 id="auction-finished-title">Auction is Finished</h2>
        <.link navigate={@view.token_path} class="rg-button rg-button--primary auction-finished__go">
          <span class="rg-button__label">Buy, claim or sell {@view.symbol}</span>
        </.link>
      </div>
      <div class="auction-finished__token">
        <span class="auction-finished__art">
          <img
            :if={present?(@view.image)}
            src={StoredImage.sized(@view.image, 160)}
            alt={"#{@view.name} token"}
            width="72"
            height="72"
            decoding="async"
          />
          <span :if={!present?(@view.image)} aria-label="No token image">{String.first(
            @view.name || "?"
          )}</span>
        </span>
        <div class="auction-finished__who">
          <p class="auction-finished__name">
            <strong>{@view.name}</strong>
            <span class="auction-finished__pair">
              <.token_pair symbol={@view.symbol} unit={@view.metric.unit} />
            </span>
          </p>
          <CreatorLabel.creator
            auction={@auction}
            connections={@connections}
            class="auction-finished__creator"
          />
          <.card_socials connections={@view.connections} website={@view.website} />
        </div>
      </div>
      <dl class="auction-finished__figures">
        <div>
          <dt>Total bid volume</dt>
          <dd>{@volume}</dd>
        </div>
        <div>
          <dt>
            Starting market cap
            <Regent.Primitives.tip id="auction-finished-starting" label="About starting market cap">
              The auction's final price times the token's whole supply.
            </Regent.Primitives.tip>
          </dt>
          <dd>{@starting}</dd>
        </div>
        <div>
          <dt>Current market cap</dt>
          <dd>{@current}</dd>
        </div>
      </dl>
    </section>
    """
  end

  defp chain_short("Robinhood"), do: "RH"
  defp chain_short("Base"), do: "Base"

  attr :connections, :list, required: true
  attr :website, :string, default: nil
  attr :wallet, :map, default: nil, doc: "the creator's wallet and its explorer page"

  # At most six links, each its kind's mark then its handle or site (the
  # wallet only its mark, with its address on hover), in this order: the
  # accounts, the website, then the wallet; any past six are left to the
  # coin's page. A website shows only as an ordinary web link; anything else
  # a launch recorded there is left off the card.
  defp card_socials(assigns) do
    connections =
      Enum.map(assigns.connections, fn connection ->
        %{
          icon: connection.kind,
          url: connection.url,
          text: connection.handle,
          label: "#{connection.label} #{connection.handle}",
          title: connection.handle,
          rel: "noopener noreferrer"
        }
      end)

    website =
      case web_link(assigns.website) do
        nil ->
          []

        link ->
          [
            %{
              icon: :web,
              url: link.url,
              text: link.label,
              label: nil,
              title: link.label,
              rel: "noopener noreferrer nofollow"
            }
          ]
      end

    wallet =
      case assigns.wallet do
        nil ->
          []

        wallet ->
          [
            %{
              icon: :wallet,
              url: wallet.url,
              text: nil,
              label: "Creator wallet #{wallet.short}",
              title: wallet.address,
              rel: "noopener noreferrer"
            }
          ]
      end

    assigns = assign(assigns, :links, Enum.take(connections ++ website ++ wallet, 6))

    ~H"""
    <div :if={@links != []} class="launchpad-card__socials" aria-label="Creator links">
      <a
        :for={link <- @links}
        href={link.url}
        title={link.title}
        aria-label={link.label}
        target="_blank"
        rel={link.rel}
      ><.link_icon kind={link.icon} /><span :if={link.text}>{link.text}</span></a>
    </div>
    """
  end

  defp wallet_link(%{creator_address: address, chain: chain}),
    do: %{
      address: address,
      short: RegentFormat.short_address(address),
      url: BidPlaced.address_url(if(chain == "Robinhood", do: :robinhood, else: :base), address)
    }

  # A stored auction on either chain. A Robinhood auction's bids are paid in
  # USDG.
  defp view(:auction, auction, connections) do
    robinhood? = RobinhoodLab.chain?(auction.chain_id)

    %{
      name: auction.title,
      symbol: auction.token_symbol,
      description: present(auction.summary, "Auction details are recorded onchain."),
      image: auction.image,
      color: auction.image_color,
      website: auction.website,
      status: state_label(auction.state),
      metric_label: "Clearing price",
      metric: metric(auction.current_clearing_price, auction.quote_token_symbol, "No price yet"),
      path: Paths.auction(auction),
      token_path: if(auction.state == :graduated, do: Paths.token(auction)),
      creator: creator_text(auction, connections),
      creator_address: auction.creator_address,
      age: auction_age(auction),
      connections: connection_list(connections),
      bid: auction_bid(auction),
      record_id: auction.id,
      chain: if(robinhood?, do: "Robinhood", else: "Base")
    }
  end

  # A launched Robinhood token trades on its own page, so its card offers no
  # Buy.
  defp view(:token, %{auction: %{chain_id: chain_id} = auction} = token, connections) do
    if RobinhoodLab.chain?(chain_id) do
      %{
        base_token_view(token, connections)
        | metric: metric(token.price_quote, auction.quote_token_symbol, "No price yet"),
          buy: nil,
          chain: "Robinhood"
      }
    else
      base_token_view(token, connections)
    end
  end

  defp base_token_view(token, connections) do
    presentation = Token.presentation(token)
    currency = SwapComponent.entry_symbol(token.auction)

    %{
      name: presentation.name,
      symbol: presentation.symbol,
      description: present(presentation.summary, "Graduated token"),
      image: presentation.image,
      color: presentation.image_color,
      website: presentation.website,
      status: "Graduated",
      metric_label: "Price",
      metric: metric(token.price_quote, currency, "No price yet"),
      path: Paths.token(token.auction),
      creator: creator_text(token.auction, connections),
      creator_address: token.auction.creator_address,
      age: ago(Map.get(token, :graduated_at) || Map.get(token, :inserted_at)),
      connections: connection_list(connections),
      buy: %{unavailable: closed_before_deployment()},
      record_id: token.id,
      chain: "Base"
    }
  end

  defp creator_text(auction, connections) do
    case CreatorLabel.name(auction, connections) do
      %{text: text} -> text
      nil -> nil
    end
  end

  # The connected accounts of the creator of a list's auction or token.
  defp connections_for(record, creators),
    do: AutolaunchWeb.Components.AutolaunchHelpers.connections_for(record, creators)

  @doc "An auction state in the words the site uses: live means open for bidding."
  def state_label(:created), do: "Opening soon"
  def state_label(:active), do: "Live"
  def state_label(:ended), do: "Waiting to finish"
  def state_label(:graduated), do: "Graduated"
  def state_label(:failed), do: "Minimum not met"

  # An auction past its end block takes no bids, so its card offers none.
  defp auction_bid(%{state: state}) when state in [:ended, :graduated, :failed], do: nil
  defp auction_bid(_auction), do: %{unavailable: closed_before_deployment()}

  # Until the contracts are deployed no bid or buy button opens anything.
  defp closed_before_deployment,
    do: if(Autolaunch.Prelaunch.read_only?(), do: "Opens soon")

  # A card whose image has a known colour carries it for its border, background
  # and graduated badge.
  defp tint(nil), do: nil
  defp tint(color), do: "--image-color: #{color}"

  defp graduated("Graduated"), do: "market-graduated"
  defp graduated(_status), do: nil

  # A coin's state as a chip: live bidding and a graduation stand out, a
  # failure reads as an error, every other state stays plain.
  defp state_tone("Live"), do: "info"
  defp state_tone("Graduated"), do: "success"
  defp state_tone("Minimum not met"), do: "error"
  defp state_tone(_status), do: "neutral"

  # `empty` is what the card shows while there is no figure.
  defp metric(amount, unit, empty),
    do: %{amount: present(amount, nil), unit: present(unit, nil), empty: empty}

  @doc """
  The accounts a creator connected and proved they own, each with its kind,
  label, handle and link, in the order X, Company X, ENS, GitHub.
  """
  def connection_list(connections) when is_map(connections) do
    [:profile, :x, :company, :ens, :github]
    |> Enum.flat_map(&connection(&1, Map.get(connections, &1)))
    |> Enum.uniq_by(& &1.url)
  end

  def connection_list(_connections), do: []

  defp connection(key, %{verified_at: %DateTime{}, username: name})
       when is_binary(name) and name != "" do
    {kind, label, base, handle} =
      case key do
        :ens -> {:ens, "ENS", "https://app.ens.domains/", name}
        :github -> {:github, "GitHub", "https://github.com/", name}
        :company -> {:x, "Company X", "https://x.com/", "@" <> name}
        _ -> {:x, "X", "https://x.com/", "@" <> name}
      end

    [
      %{
        kind: kind,
        username: name,
        label: label,
        handle: handle,
        url: base <> URI.encode_www_form(name)
      }
    ]
  end

  defp connection(_key, _value), do: []

  # An auction the chain says has ended may have an estimated end a moment
  # ahead; it still reads as past.
  defp ended_ago(end_at) do
    now = DateTime.utc_now()
    RegentFormat.relative_time(Enum.min([end_at, now], DateTime), now)
  end

  defp ago(nil), do: nil
  defp ago(at), do: RegentFormat.relative_time(at, DateTime.utc_now())

  # Once its lifecycle says bidding is over an auction counts from its end;
  # before that, from when it was listed.
  defp auction_age(%{state: state, estimated_end_at: %DateTime{} = end_at})
       when state in [:ended, :graduated, :failed],
       do: "Ended #{ended_ago(end_at)}"

  defp auction_age(auction), do: listed_age(auction)

  defp listed_age(auction),
    do: ago(Map.get(auction, :inserted_at) || Map.get(auction, :opened_at))

  @doc """
  A creator's website as a link and a short label, or nil when it is not an
  ordinary web address or names this site or Regents.
  """
  def web_link(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        if own_site?(host), do: nil, else: %{url: URI.to_string(uri), label: website_label(uri)}

      _other ->
        nil
    end
  end

  def web_link(_url), do: nil

  # A creator who names this site or Regents as their website has named no
  # website of their own.
  defp own_site?(host) do
    host = String.downcase(host)
    Enum.any?(@own_sites, &(host == &1 or String.ends_with?(host, "." <> &1)))
  end

  defp website_label(%URI{host: host, path: path}),
    do: String.trim_leading(host, "www.") <> String.trim_trailing(path || "", "/")

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp present(value, fallback), do: if(present?(value), do: value, else: fallback)
end
