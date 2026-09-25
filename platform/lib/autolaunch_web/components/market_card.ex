defmodule AutolaunchWeb.Components.MarketCard do
  @moduledoc false
  use Phoenix.Component

  import AutolaunchWeb.Components.LinkIcon

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.Lab
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Stocks.MarketData
  alias Autolaunch.Token
  alias AutolaunchWeb.Components.{BidPlaced, ChainIcon}
  import AutolaunchWeb.Components.InfoTip
  alias AutolaunchWeb.{SwapComponent, TokenDisplay, UsdValue}
  require Phoenix.LiveView

  @own_sites ["autolaunch.sh", "regents.sh"]

  # What each auction figure means, on the list's headings and the gallery's figures.
  @tips %{
    fdv:
      "What the whole token supply is worth at the price bidders pay right now. It rises as bids push the price up.",
    volume: "Everything bidders have put in so far, in dollars.",
    threshold:
      "What the auction must raise for the token to launch, set by its creator. If it ends short, every bid is returned."
  }

  attr :kind, :atom, required: true, values: [:draft, :auction, :token]
  attr :record, :map, required: true
  attr :creator_connections, :map, default: %{}
  attr :preview, :boolean, default: false
  attr :linked, :boolean, default: true
  attr :class, :string, default: nil

  def autolaunch_market_card(assigns) do
    view =
      assigns.kind
      |> view(assigns.record, assigns.creator_connections)
      |> Map.update!(:path, &if(assigns.linked, do: &1, else: nil))

    assigns = assign(assigns, :view, view)

    ~H"""
    <article class={["launchpad-card", @preview && "launchpad-card--preview", @class]}>
      <.link
        :if={@view.path}
        navigate={@view.path}
        class="launchpad-card__link"
        aria-label={@view.name}
      >
        <.card_contents view={@view} />
      </.link>
      <div :if={!@view.path} class="launchpad-card__link">
        <.card_contents view={@view} />
      </div>
      <.card_socials
        connections={@view.connections}
        website={@view.website}
        telegram={@view.telegram}
      />
    </article>
    """
  end

  attr :kind, :atom, required: true, values: [:auction, :token]
  attr :record, :map, required: true
  attr :creator_connections, :map, default: %{}
  attr :trade_event, :string, default: nil

  attr :rate, :any,
    default: nil,
    doc: "the USD price of one unit of the record's currency, for its figures"

  @doc """
  A gallery card. Every card reads, top to bottom: its ticker over its
  currency with its chain, its name, its price and one more figure, the
  creator's links.

  An auction's card shows only its clearing price up top, then has a
  figures row (the bid volume and launch threshold on hover or keyboard
  focus, the FDV always), Details and Bid, and two thin bars: how much of
  the launch threshold is met, while it is not yet met, over how much of
  the auction's time has passed. A token's card shows its price and market
  cap, then Details and Buy.
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
    <article
      class={["home-coin", @view.color && "home-coin--tinted"]}
      style={tint(@view.color)}
    >
      <.card_head view={@view} />
      <div class="home-coin__metric">
        <TokenDisplay.price amount={@view.metric.amount} unit={@view.metric.unit} fallback="-" /><span>Clearing price</span>
      </div>
      <.card_links view={@view} />
      <div class="home-coin__figures">
        <div class="home-coin__raise">
          <p>
            <span>Bid volume</span>
            <.info_tip id={"volume-#{@figures.id}"} text={tip(:volume)} icon={false}>
              {@figures.volume}
            </.info_tip>
            <span :if={@figures.met}> · {if @figures.met >= 100,
              do: "met",
              else: "#{@figures.met}% met"}</span>
          </p>
          <p>
            <span>Launch threshold</span>
            <.info_tip id={"threshold-#{@figures.id}"} text={tip(:threshold)} icon={false}>
              {@figures.threshold}
            </.info_tip>
          </p>
        </div>
        <p class="home-coin__floor">
          <span class="visually-hidden">FDV </span><.info_tip
            id={"fdv-#{@figures.id}"}
            text={tip(:fdv)}
            icon={false}
          >
            {@figures.fdv}
          </.info_tip>
        </p>
      </div>
      <div class="home-coin__actions">
        <.link
          navigate={@view.path}
          class="rg-button rg-button--secondary home-coin__action"
          aria-label={"Details for #{@view.name}"}
        >Details</.link>
        <Regent.Primitives.button
          :if={@trade_event && @view.bid}
          class="home-coin__action"
          phx-click={@trade_event}
          phx-value-id={@view.record_id}
          disabled={@view.bid.unavailable != nil}
          title={@view.bid.unavailable}
          aria-label={"Bid on #{@view.name}"}
        >Bid</Regent.Primitives.button>
      </div>
      <div class="home-coin__bars">
        <div
          :if={@figures.met && @figures.met < 100}
          class="home-coin__met"
          role="img"
          aria-label={"#{@figures.met}% of the launch threshold met"}
          title={"#{@figures.met}% of the launch threshold met"}
        >
          <span :if={@figures.met > 0} style={"width: max(#{@figures.met}%, 8px)"}></span>
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

  def explore_card(%{kind: :token} = assigns) do
    assigns =
      assign(assigns,
        view: view(:token, assigns.record, assigns.creator_connections),
        market_cap: dollars(assigns.record.market_cap, assigns.rate)
      )

    ~H"""
    <article
      class={["home-coin", @view.color && "home-coin--tinted"]}
      style={tint(@view.color)}
    >
      <.card_head view={@view} />
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

  attr :view, :map, required: true

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
      <.coin_art view={@view} />
      <p class="home-coin__pair">
        <span class="home-coin__ticker" title={@pair}>{@view.symbol}<span :if={@view.metric.unit}> /<wbr /> {@view.metric.unit}</span></span>
        <.chain_chip chain={@view.chain} label={chain_short(@view.chain)} />
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
      <.card_socials
        connections={@view.connections}
        website={@view.website}
        telegram={@view.telegram}
        wallet={@wallet}
      />
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

  defp coin_art(assigns) do
    ~H"""
    <div class="home-coin__art">
      <img
        :if={present?(@view.image)}
        src={@view.image}
        alt={"#{@view.name} token"}
        loading="lazy"
        decoding="async"
        width="400"
        height="400"
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
        <label>
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
        <label :if={@kind == "auctions"}>
          <span class="visually-hidden">Status</span>
          <select name="state" aria-label="Status">
            <option
              :for={
                {value, label} <- [
                  {"all", "Any status"},
                  {"created", "Opening soon"},
                  {"active", "Live"},
                  {"ended", "Waiting to finish"},
                  {"graduated", "Launched"},
                  {"failed", "Failed"}
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
          class={["market-list__verified-menu", @verified && "is-active"]}
          phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
        >
          <summary>Verified</summary>
          <fieldset>
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
            placeholder="Search name, ticker or address"
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
  attr :loading, :boolean, default: false

  @doc """
  The auctions list: the token, then the four auction figures. On a phone only
  the token, launch threshold and status show.
  """
  def auction_list(assigns) do
    ~H"""
    <div class="market-list__scroll">
      <table class="market-list__table market-list__table--auctions">
        <caption class="visually-hidden">Auctions</caption>
        <thead>
          <tr>
            <th scope="col">Token</th>
            <th scope="col">
              <.info_tip id="auctions-fdv" text={tip(:fdv)}>FDV</.info_tip>
            </th>
            <th scope="col">
              <.info_tip id="auctions-volume" text={tip(:volume)}>Bid volume</.info_tip>
            </th>
            <th scope="col">
              <.info_tip id="auctions-threshold" text={tip(:threshold)}>Launch threshold</.info_tip>
            </th>
            <th scope="col">Status</th>
          </tr>
        </thead>
        <tbody>
          <.auction_list_row
            :for={record <- @records}
            auction={record}
            rate={figure_rate(@rates, record)}
          />
          <tr
            :for={index <- 1..6}
            :if={@loading && @records == []}
            id={"auctions-loading-#{index}"}
            class="market-list__skeleton"
            aria-hidden="true"
          >
            <td colspan="5"></td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp tip(figure), do: Map.fetch!(@tips, figure)

  attr :auction, :map, required: true
  attr :rate, :any, default: nil

  defp auction_list_row(assigns) do
    assigns =
      assign(assigns,
        view: view(:auction, assigns.auction, %{}),
        figures: figures(assigns.auction, assigns.rate)
      )

    ~H"""
    <tr class="market-list__row">
      <.list_token view={@view} />
      <td>{@figures.fdv}</td>
      <td>{@figures.volume}</td>
      <td>
        {@figures.threshold}<small :if={@figures.met}>{@figures.met}% met</small>
      </td>
      <td>
        <.status_figure figures={@figures} chain={@view.chain} />
      </td>
    </tr>
    """
  end

  attr :records, :list, required: true, doc: "launched tokens with `market_cap` loaded"
  attr :rates, :any, required: true, doc: "the dollar prices from `assign_figure_rates/1`"
  attr :loading, :boolean, default: false

  @doc """
  The tokens list: the token, its price, its market cap and when it launched.
  On a phone the market cap is left out.
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
            <th scope="col">Launched</th>
          </tr>
        </thead>
        <tbody>
          <.token_list_row
            :for={token <- @records}
            token={token}
            rate={figure_rate(@rates, token.auction)}
          />
          <tr
            :for={index <- 1..6}
            :if={@loading && @records == []}
            id={"tokens-loading-#{index}"}
            class="market-list__skeleton"
            aria-hidden="true"
          >
            <td colspan="4"></td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :token, :map, required: true
  attr :rate, :any, default: nil

  defp token_list_row(assigns) do
    assigns =
      assign(assigns,
        view: view(:token, assigns.token, %{}),
        market_cap: dollars(assigns.token.market_cap, assigns.rate)
      )

    ~H"""
    <tr class="market-list__row">
      <.list_token view={@view} />
      <td>
        <.price_figure amount={@token.price_quote} unit={@view.metric.unit} rate={@rate} />
      </td>
      <td>{@market_cap}</td>
      <td>{if @view.age, do: "#{@view.age} ago", else: "-"}</td>
    </tr>
    """
  end

  attr :view, :map, required: true

  # The cell every list row starts with: the token's image with its chain's
  # badge, then its name and its ticker on one line.
  defp list_token(assigns) do
    ~H"""
    <th scope="row">
      <.link navigate={@view.path} class="market-list__token">
        <span class="market-list__art">
          <img
            :if={present?(@view.image)}
            src={@view.image}
            alt=""
            loading="lazy"
            decoding="async"
            width="40"
            height="40"
          />
          <span :if={!present?(@view.image)} aria-hidden="true">{String.first(@view.name || "?")}</span>
          <ChainIcon.chain_icon
            chain={if @view.chain == "Robinhood", do: :robinhood, else: :base}
            class="market-list__chain"
          />
        </span>
        <span class="market-list__name">
          <strong>{@view.name}</strong>
          <small>{@view.symbol}</small>
        </span>
      </.link>
    </th>
    """
  end

  attr :amount, :string, default: nil, doc: "a price per token in its currency"
  attr :unit, :string, default: nil, doc: "the currency the price is in"

  attr :rate, :any,
    default: nil,
    doc: "the USD price of one unit of that currency, nil while none is known"

  # A price per token in dollars where the currency's dollar price is known,
  # otherwise in the currency itself. A tiny price counts its zeros after the
  # point, as in `$0.0₄123`, with the plain figure kept for screen readers.
  defp price_figure(assigns) do
    price = decimal(assigns.amount)
    usd = if price && assigns.rate, do: dollars(price, assigns.rate)
    shown = if usd, do: TokenDisplay.zeros(usd)
    assigns = assign(assigns, usd: usd, shown: shown)

    ~H"""
    <span :if={@usd && @shown == @usd}>{@usd}</span>
    <span :if={@usd && @shown != @usd}>
      <span aria-hidden="true">{@shown}</span><span class="visually-hidden">{@usd}</span>
    </span>
    <TokenDisplay.price :if={!@usd} amount={@amount} unit={@unit} fallback="-" />
    """
  end

  @doc """
  Reads the dollar prices the auction figures use into `:rates`, in the
  background: REGENT's price and each chain's stock prices. A test network's
  coins carry no dollar value, so its prices stay unknown.
  """
  def assign_figure_rates(socket) do
    Phoenix.LiveView.assign_async(socket, :rates, fn ->
      {:ok,
       %{
         rates: %{
           regent: if(!Lab.test_chain?(), do: MarketData.regent_price()),
           base: if(!Lab.test_chain?(), do: MarketData.prices(:base)),
           robinhood: if(!RobinhoodLab.test_chain?(), do: MarketData.prices(:robinhood))
         }
       }}
    end)
  end

  @doc "The USD price of one unit of the auction's currency; nil while none is known."
  def figure_rate(%{ok?: true, result: rates}, auction) do
    cond do
      RobinhoodLab.chain?(auction.chain_id) ->
        UsdValue.stock_rate(rates.robinhood, auction.quote_token_symbol)

      auction.kind == :agent ->
        rates.regent

      true ->
        UsdValue.stock_rate(rates.base, auction.quote_token_symbol)
    end
  end

  def figure_rate(_rates, _auction), do: nil

  defp figures(auction, rate) do
    minimum =
      auction.required_currency_raised
      |> String.to_integer()
      |> Rpc.format_units(auction.quote_token_decimals)
      |> Decimal.new()

    %{
      fdv: dollars(auction.fdv, rate),
      volume: dollars(auction.bid_volume_usd, 1),
      threshold: dollars(minimum, rate),
      met: percent_met(auction.currency_raised, minimum),
      progress: time_progress(auction),
      opens_at: live_open(auction),
      ends_at: live_end(auction),
      status: figure_status(auction),
      id: auction.id
    }
  end

  # Dollar figures are shortened the way market lists write them, to three
  # significant digits: $0.0000123, $1.48, $296, $24.7K, $1.48M.
  defp dollars(%Decimal{} = amount, rate) when not is_nil(rate) do
    value = Decimal.mult(amount, rate)
    if Decimal.eq?(value, 0), do: "$0", else: "$" <> compact(value)
  end

  defp dollars(_amount, _rate), do: "-"

  @doc "An amount shortened to three significant digits: 0.0000123, 1.48, 24.7K, 1.48M."
  def compact(value) do
    # Rounded before the suffix is chosen, so 999,999 reads 1M, not 1000K.
    value = value |> significant() |> Decimal.new()

    [{1_000_000_000_000, "T"}, {1_000_000_000, "B"}, {1_000_000, "M"}, {1_000, "K"}]
    |> Enum.find(fn {size, _suffix} -> Decimal.gte?(value, size) end)
    |> case do
      {size, suffix} -> value |> Decimal.div(size) |> significant() |> Kernel.<>(suffix)
      nil -> significant(value)
    end
  end

  defp significant(%Decimal{coef: coef, exp: exp} = value) do
    digits = coef |> Integer.digits() |> length()

    value
    |> Decimal.round(3 - digits - exp)
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  # Stored prices can run past a hundred decimal places.
  defp decimal(value) when is_binary(value) do
    case Decimal.parse(String.trim(value), max_digits: :infinity) do
      {%Decimal{} = decimal, ""} -> decimal
      _unparsed -> nil
    end
  end

  defp decimal(_value), do: nil

  # A threshold met many times over still reads 100% met.
  defp percent_met(%Decimal{} = raised, minimum) do
    if Decimal.gt?(minimum, 0),
      do:
        raised
        |> Decimal.div(minimum)
        |> Decimal.mult(100)
        |> Decimal.round(0, :down)
        |> Decimal.to_integer()
        |> min(100)
  end

  defp percent_met(_raised, _minimum), do: nil

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

  defp figure_status(%{state: :graduated} = auction), do: ended("Launched", auction)
  defp figure_status(%{state: :failed} = auction), do: ended("Failed", auction)
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
    do: "#{label} #{relative_age(end_at)} ago"

  defp ended(label, _auction), do: label

  attr :figures, :map, required: true
  attr :chain, :string, required: true, values: ["Base", "Robinhood"]

  # A live auction's time bar in its chain's colour over its time left, both
  # kept moving in the browser; any other state's word and when it ended. A
  # live auction whose opening time is unknown shows an empty bar.
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
    <span :if={!@figures.ends_at}>{@figures.status}</span>
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
          src={@view.image}
          alt={"#{@view.name} token"}
          width="400"
          height="400"
          decoding="async"
        />
        <span :if={!present?(@view.image)} aria-label="No token image">{String.first(
          @view.name || "?"
        )}</span>
      </div>
      <div class="market-identity__body">
        <p class="market-identity__symbol">${@view.symbol}</p>
        <div class="market-identity__meta">
          <.chain_chip chain={@view.chain} label={@view.chain} />
          <span class={launched(@status || @view.status)}>{@status || @view.status}</span>
          <span :if={@view.age}>{@view.age} ago</span>
        </div>
        <div class="market-identity__price">
          <span>{@view.metric_label}</span><TokenDisplay.price
            amount={@view.metric.amount}
            unit={@view.metric.unit}
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
    </section>
    """
  end

  attr :chain, :string, required: true, values: ["Base", "Robinhood"]
  attr :label, :string, required: true

  defp chain_chip(assigns) do
    ~H"""
    <span class={["chain-chip", "chain-chip--#{String.downcase(@chain)}"]} title={@chain}>
      <span aria-hidden="true">{@label}</span><span class="visually-hidden">{@chain}</span>
    </span>
    """
  end

  defp chain_short("Robinhood"), do: "RH"
  defp chain_short("Base"), do: "Base"

  attr :view, :map, required: true

  defp card_contents(assigns) do
    ~H"""
    <Regent.Structure.capability_card
      title={@view.name}
      description={@view.description}
      index={Enum.join(Enum.filter([@view.status, present(@view.symbol, nil)], & &1), " · ")}
      image_src={present(@view.image, nil)}
      image_alt={"#{@view.name} token"}
      class="launchpad-card__feature"
    >
      <:media><span class="launchpad-card__placeholder" aria-hidden="true">R</span></:media>
      <:actions>
        <p class="launchpad-card__metric">
          <span class="autolaunch-micro">{@view.metric_label}</span>
          <TokenDisplay.price amount={@view.metric.amount} unit={@view.metric.unit} />
        </p>
        <p :if={present?(@view.creator) or present?(@view.age)} class="launchpad-card__meta">
          <span :if={present?(@view.creator)}>{@view.creator}</span>
          <span :if={present?(@view.age)}>{@view.age}</span>
        </p>
      </:actions>
    </Regent.Structure.capability_card>
    """
  end

  attr :connections, :list, required: true
  attr :website, :string, default: nil
  attr :telegram, :string, default: nil
  attr :wallet, :map, default: nil, doc: "the creator's wallet and its explorer page"

  # At most six links, each its kind's mark then its handle or site (the
  # wallet only its mark, with its address on hover), in this order: the
  # accounts, the website, Telegram, then the wallet; any past six are left to the
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

    telegram =
      case telegram_link(assigns.telegram) do
        nil ->
          []

        link ->
          [
            %{
              icon: :telegram,
              url: link.url,
              text: link.label,
              label: "Telegram #{link.label}",
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

    assigns =
      assign(assigns, :links, Enum.take(connections ++ website ++ telegram ++ wallet, 6))

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
      short: short_address(address),
      url: BidPlaced.address_url(if(chain == "Robinhood", do: :robinhood, else: :base), address)
    }

  defp view(:draft, values, connections) do
    %{
      name: present(values["name"], "Your token"),
      symbol: present(values["symbol"], "TICKER"),
      description: present(values["description"], "Your launch description will appear here."),
      image: values["image"],
      color: nil,
      website: values["website"],
      telegram: values["telegram"],
      status: "Preview",
      metric_label: present(values["preview_metric_label"], "Raise target"),
      metric:
        metric(
          values["required_regent_raised"],
          present(values["preview_metric_unit"], "REGENT")
        ),
      path: nil,
      creator: nil,
      creator_address: nil,
      age: nil,
      connections: connection_list(connections)
    }
  end

  # A stored auction on either chain. A Robinhood auction's page is named by
  # its address, and its bids are paid in USDG.
  defp view(:auction, auction, connections) do
    robinhood? = RobinhoodLab.chain?(auction.chain_id)

    %{
      name: auction.title,
      symbol: auction.token_symbol,
      description: present(auction.summary, "Auction details are recorded onchain."),
      image: auction.image,
      color: auction.image_color,
      website: auction.website,
      telegram: auction.telegram,
      status: state_label(auction.state),
      metric_label: "Clearing price",
      metric: metric(auction.current_clearing_price, auction.quote_token_symbol),
      path:
        if(robinhood?,
          do: "/robinhood/auctions/#{auction.auction_address}",
          else: "/auctions/#{auction.id}"
        ),
      creator: short_address(auction.creator_address),
      creator_address: auction.creator_address,
      age: relative_age(Map.get(auction, :inserted_at) || Map.get(auction, :opened_at)),
      connections: connection_list(connections),
      bid: auction_bid(auction),
      record_id: auction.id,
      chain: if(robinhood?, do: "Robinhood", else: "Base")
    }
  end

  # A launched Robinhood token's page is named by its token's address; it
  # trades on its own page, so its card offers no Buy.
  defp view(:token, %{auction: %{chain_id: chain_id} = auction} = token, connections) do
    if RobinhoodLab.chain?(chain_id) do
      %{
        base_token_view(token, connections)
        | metric: metric(token.price_quote, auction.quote_token_symbol),
          path: "/robinhood/tokens/#{auction.token_address}",
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
      description: present(presentation.summary, "Launched token"),
      image: presentation.image,
      color: presentation.image_color,
      website: presentation.website,
      telegram: presentation.telegram,
      status: "Launched",
      metric_label: "Price",
      metric: metric(token.price_quote, currency),
      path: "/tokens/#{token.id}",
      creator: short_address(token.auction.creator_address),
      creator_address: token.auction.creator_address,
      age: relative_age(Map.get(token, :graduated_at) || Map.get(token, :inserted_at)),
      connections: connection_list(connections),
      buy: %{unavailable: closed_before_deployment()},
      record_id: token.id,
      chain: "Base"
    }
  end

  @doc "An auction state in the words the site uses: live means open for bidding."
  def state_label(:created), do: "Opening soon"
  def state_label(:active), do: "Live"
  def state_label(:ended), do: "Waiting to finish"
  def state_label(:graduated), do: "Launched"
  def state_label(:failed), do: "Failed"

  # An auction past its end block takes no bids, so its card offers none.
  defp auction_bid(%{state: state}) when state in [:ended, :graduated, :failed], do: nil
  defp auction_bid(_auction), do: %{unavailable: closed_before_deployment()}

  # Until the contracts are deployed no bid or buy button opens anything.
  defp closed_before_deployment,
    do:
      if(Autolaunch.Prelaunch.read_only?(), do: "Opens #{Autolaunch.Prelaunch.opens_at_label()}")

  # A card whose image has a known colour carries it for its border, background
  # and launched badge.
  defp tint(nil), do: nil
  defp tint(color), do: "--image-color: #{color}"

  defp launched("Launched"), do: "market-graduated"
  defp launched(_status), do: nil

  defp metric(amount, unit), do: %{amount: present(amount, nil), unit: present(unit, nil)}

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

  defp short_address(<<"0x", _::binary-size(40)>> = address),
    do: "#{String.slice(address, 0, 6)}…#{String.slice(address, -4, 4)}"

  defp short_address(nil), do: nil

  defp relative_age(%DateTime{} = at) do
    seconds = DateTime.diff(DateTime.utc_now(), at, :second) |> max(0)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3_600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  defp relative_age(_at), do: nil

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

  @doc "A creator's Telegram community as a link and its t.me label, or nil without one."
  def telegram_link("https://" <> label = url), do: %{url: url, label: label}
  def telegram_link(_url), do: nil

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
