defmodule AutolaunchWeb.Components.MarketCard do
  @moduledoc false
  use Phoenix.Component

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.Lab
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Stocks.MarketData
  alias Autolaunch.Token
  alias AutolaunchWeb.{BidComponent, SwapComponent, TokenDisplay, UsdValue}
  alias AutolaunchWeb.Components.ChainIcon
  require Phoenix.LiveView

  @own_sites ["autolaunch.sh", "regents.sh"]

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
      <.card_socials connections={@view.connections} website={@view.website} />
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

  def explore_card(assigns) do
    assigns =
      assign(assigns, :view, view(assigns.kind, assigns.record, assigns.creator_connections))

    ~H"""
    <article
      class={["home-coin", @view.color && "home-coin--tinted"]}
      style={tint(@view.color)}
    >
      <.link navigate={@view.path} class="home-coin__main">
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
        <h2 class="home-coin__name">{@view.name}</h2>
        <p class="home-coin__symbol">${@view.symbol}</p>
        <div :if={@kind == :token} class="home-coin__metric">
          <.price_figure amount={@view.metric.amount} unit={@view.metric.unit} rate={@rate} /><span>{@view.metric_label}</span>
        </div>
      </.link>
      <.auction_figures :if={@kind == :auction} auction={@record} rate={@rate} />
      <div class="home-coin__meta">
        <span :if={@view.creator} title={@view.creator_address}>{@view.creator}</span>
        <span :if={@view.age} class="home-coin__age">{@view.age}</span>
        <span class={["home-coin__status", launched(@view.status)]}>{@view.status}</span>
        <.chain_chip chain={@view.chain} />
      </div>
      <.card_socials connections={@view.connections} compact />
      <p :if={present?(@view.description)} class="home-coin__description">{@view.description}</p>
      <.quick_actions
        :if={@trade_event && @view.quick}
        event={@trade_event}
        record_id={@view.record_id}
        name={@view.name}
        quick={@view.quick}
      />
    </article>
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
  attr :creators, :map, required: true, doc: "creator connections grouped by human account"
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
            <th scope="col">FDV</th>
            <th scope="col">Bid volume</th>
            <th scope="col">Launch threshold</th>
            <th scope="col">Status</th>
          </tr>
        </thead>
        <tbody>
          <.auction_list_row
            :for={record <- @records}
            auction={record}
            creator_connections={Map.get(@creators, record.creator_human_account_id, %{})}
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

  attr :auction, :map, required: true
  attr :creator_connections, :map, default: %{}
  attr :rate, :any, default: nil

  defp auction_list_row(assigns) do
    assigns =
      assign(assigns,
        view: view(:auction, assigns.auction, assigns.creator_connections),
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
        <.status_figure figures={@figures} />
      </td>
    </tr>
    """
  end

  attr :records, :list, required: true, doc: "launched tokens with `market_cap` loaded"
  attr :creators, :map, required: true, doc: "creator connections grouped by human account"
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
            creator_connections={Map.get(@creators, token.auction.creator_human_account_id, %{})}
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
  attr :creator_connections, :map, default: %{}
  attr :rate, :any, default: nil

  defp token_list_row(assigns) do
    assigns =
      assign(assigns,
        view: view(:token, assigns.token, assigns.creator_connections),
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
  # badge, its name with the creator's verified mark, and its ticker.
  defp list_token(assigns) do
    assigns =
      assign(assigns, :verified, Enum.map_join(assigns.view.connections, ", ", & &1.label))

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
          <span
            :if={@verified != ""}
            class="market-list__verified"
            title={"Creator verified: #{@verified}"}
          ><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 8.5l3 3 6-7" /></svg><span class="visually-hidden">Creator verified: {@verified}</span></span>
          <small>${@view.symbol}</small>
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

  attr :auction, :map, required: true, doc: "an auction with `fdv` loaded"

  attr :rate, :any,
    default: nil,
    doc: "the USD price of one unit of the auction's currency, nil while none is known"

  @doc """
  The four figures an auction's card shows: the current price per token, FDV
  at that price, the launch threshold with how much of it is met, and the
  status. A figure the site does not know shows as a dash, never as zero.
  """
  def auction_figures(assigns) do
    assigns = assign(assigns, :figures, figures(assigns.auction, assigns.rate))

    ~H"""
    <dl class="auction-figures">
      <div>
        <dt>Price</dt>
        <dd>
          <.price_figure
            amount={@auction.current_clearing_price}
            unit={@auction.quote_token_symbol}
            rate={@rate}
          />
        </dd>
      </div>
      <div>
        <dt>FDV</dt>
        <dd>{@figures.fdv}</dd>
      </div>
      <div>
        <dt>Launch threshold</dt>
        <dd>
          {@figures.threshold}<small :if={@figures.met}>{@figures.met}% met</small>
        </dd>
      </div>
      <div>
        <dt>Status</dt>
        <dd>
          <.status_figure figures={@figures} />
        </dd>
      </div>
    </dl>
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

  defp compact(value) do
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

  defp percent_met(%Decimal{} = raised, minimum) do
    if Decimal.gt?(minimum, 0),
      do:
        raised
        |> Decimal.div(minimum)
        |> Decimal.mult(100)
        |> Decimal.round(0, :down)
        |> Decimal.to_integer()
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

  defp live_end(%{state: :active, estimated_end_at: %DateTime{} = end_at}), do: end_at
  defp live_end(_auction), do: nil

  defp figure_status(%{state: :active, estimated_end_at: %DateTime{} = end_at}),
    do: time_left(max(DateTime.diff(end_at, DateTime.utc_now()), 0))

  defp figure_status(%{state: :graduated} = auction), do: ended("Launched", auction)
  defp figure_status(%{state: :failed} = auction), do: ended("Failed", auction)
  defp figure_status(%{state: state}), do: state_label(state)

  # The same wording the page's ticker writes each second.
  defp time_left(0), do: "Ending"

  defp time_left(seconds) do
    days = div(seconds, 86_400)

    rest =
      "#{div(rem(seconds, 86_400), 3600)}h #{div(rem(seconds, 3600), 60)}m #{rem(seconds, 60)}s"

    if days > 0, do: "#{days}d #{rest}", else: rest
  end

  defp ended(label, %{estimated_end_at: %DateTime{} = end_at}),
    do: "#{label} #{relative_age(end_at)} ago"

  defp ended(label, _auction), do: label

  attr :figures, :map, required: true

  # A live auction's time bar and time left, which tick in the browser each
  # second; any other state's word and when it ended.
  defp status_figure(assigns) do
    ~H"""
    <span
      :if={@figures.progress}
      class="auction-figures__progress"
      style={"--progress: #{@figures.progress}%"}
      aria-hidden="true"
    ></span>
    <span
      :if={@figures.ends_at}
      id={"time-left-#{@figures.id}"}
      phx-hook=".AuctionTimeLeft"
      data-ends-at={DateTime.to_iso8601(@figures.ends_at)}
    >{@figures.status}</span>
    <span :if={!@figures.ends_at}>{@figures.status}</span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".AuctionTimeLeft">
      export default {
        mounted() { this.tick() },
        updated() { this.tick() },
        destroyed() { clearTimeout(this.timer) },
        tick() {
          clearTimeout(this.timer)
          const seconds = Math.max(Math.floor((Date.parse(this.el.dataset.endsAt) - Date.now()) / 1000), 0)
          const d = Math.floor(seconds / 86400)
          const rest = `${Math.floor((seconds % 86400) / 3600)}h ${Math.floor((seconds % 3600) / 60)}m ${seconds % 60}s`
          this.el.textContent = seconds === 0 ? "Ending" : d > 0 ? `${d}d ${rest}` : rest
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
  attr :creator_connections, :map, default: %{}

  attr :trade_path, :string,
    default: nil,
    doc: "set once the coin trades; takes the description's place"

  attr :status, :string,
    default: nil,
    doc: "the page's own reading of the state, when the record's state label lags the chain"

  slot :price_note, doc: "shown after the price, such as its dollar value"

  def detail_card(assigns) do
    assigns =
      assign(assigns, :view, view(assigns.kind, assigns.record, assigns.creator_connections))

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
          <.chain_chip chain={@view.chain} />
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
        <.creator_block view={@view} />
      </div>
    </section>
    """
  end

  attr :event, :string, required: true
  attr :record_id, :string, required: true
  attr :name, :string, required: true
  attr :quick, :map, required: true

  # Two set amounts and an open-ended button. All three open the same panel;
  # the amount buttons open it with that amount already entered.
  defp quick_actions(assigns) do
    ~H"""
    <div class="market-quick" role="group" aria-label={"#{@quick.verb} #{@name}"}>
      <Regent.Primitives.button
        :for={amount <- if(@quick.currency, do: ["25", "100"], else: [])}
        variant="secondary"
        phx-click={@event}
        phx-value-id={@record_id}
        phx-value-amount={amount}
        disabled={@quick.unavailable != nil}
        title={@quick.unavailable}
        aria-label={"#{@quick.verb} #{@name} with #{amount} #{@quick.currency}"}
      >{amount} <small>{@quick.currency}</small></Regent.Primitives.button>
      <Regent.Primitives.button
        phx-click={@event}
        phx-value-id={@record_id}
        disabled={@quick.unavailable != nil}
        title={@quick.unavailable}
        aria-label={"#{@quick.verb} #{@name}"}
      >{@quick.verb}</Regent.Primitives.button>
    </div>
    """
  end

  attr :chain, :string, required: true

  defp chain_chip(assigns) do
    ~H"""
    <span class={["chain-chip", "chain-chip--#{String.downcase(@chain)}"]}>{@chain}</span>
    """
  end

  attr :view, :map, required: true

  # Who launched it: the launching wallet in full, then each account the
  # creator could connect, marked when it is not connected.
  defp creator_block(assigns) do
    connected = Map.new(assigns.view.connections, &{&1.label, &1})

    assigns =
      assign(assigns,
        website: web_link(assigns.view.website),
        rows:
          Enum.map(["X", "Company X", "ENS", "GitHub"], &{&1, Map.get(connected, &1)})
          |> Enum.reject(fn {label, connection} ->
            label == "Company X" and is_nil(connection)
          end)
      )

    ~H"""
    <section class="market-creator" aria-label="Creator">
      <h2 class="autolaunch-micro">Created by</h2>
      <p :if={@view.creator_address} class="autolaunch-exact-value">{@view.creator_address}</p>
      <dl class="market-creator__accounts">
        <div :for={{label, connection} <- @rows}>
          <dt>{label}</dt>
          <dd :if={connection}>
            <a href={connection.url} target="_blank" rel="noopener noreferrer">
              {connection.username}
            </a>
          </dd>
          <dd :if={!connection} class="market-creator__missing">Not connected</dd>
        </div>
        <div :if={@website}>
          <dt>Website</dt>
          <dd>
            <a href={@website.url} target="_blank" rel="noopener noreferrer nofollow">
              {@website.label}
            </a>
          </dd>
        </div>
      </dl>
    </section>
    """
  end

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
  attr :compact, :boolean, default: false

  # A website shows only as an ordinary web link; anything else a launch
  # recorded there is left off the page.
  defp card_socials(assigns) do
    assigns = assign(assigns, :website, web_link(assigns.website))

    ~H"""
    <div
      :if={@connections != [] || @website}
      class="launchpad-card__socials"
      aria-label="Creator links"
    >
      <a :if={@website} href={@website.url} target="_blank" rel="noopener noreferrer nofollow">
        <span>Website</span> {@website.label}
      </a>
      <a
        :for={connection <- @connections}
        href={connection.url}
        title={connection.username}
        aria-label={"#{connection.label}: #{connection.username}"}
        target="_blank"
        rel="noopener noreferrer"
      >
        <span>{connection.label}</span><span :if={!@compact}>{connection.username}</span>
      </a>
    </div>
    """
  end

  defp view(:draft, values, connections) do
    %{
      name: present(values["name"], "Your token"),
      symbol: present(values["symbol"], "TICKER"),
      description: present(values["description"], "Your launch description will appear here."),
      image: values["image"],
      color: nil,
      website: values["website"],
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
      connections: connection_list(connections),
      quick: nil
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
      quick:
        auction_quick(
          auction,
          if(robinhood?, do: "USDG", else: BidComponent.bid_currency(auction))
        ),
      record_id: auction.id,
      chain: if(robinhood?, do: "Robinhood", else: "Base")
    }
  end

  # A launched Robinhood token's page is named by its token's address; it
  # trades on its own page, so its row offers no quick buy.
  defp view(:token, %{auction: %{chain_id: chain_id} = auction} = token, connections) do
    if RobinhoodLab.chain?(chain_id) do
      %{
        base_token_view(token, connections)
        | metric: metric(token.price_quote, auction.quote_token_symbol),
          path: "/robinhood/tokens/#{auction.token_address}",
          quick: nil,
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
      status: "Launched",
      metric_label: "Price",
      metric: metric(token.price_quote, currency),
      path: "/tokens/#{token.id}",
      creator: short_address(token.auction.creator_address),
      creator_address: token.auction.creator_address,
      age: relative_age(Map.get(token, :graduated_at) || Map.get(token, :inserted_at)),
      connections: connection_list(connections),
      quick: %{
        verb: "Buy",
        currency: currency,
        unavailable: closed_before_deployment()
      },
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

  # An auction past its end block takes no bids, so its row offers none.
  defp auction_quick(%{state: state}, _currency) when state in [:ended, :graduated, :failed],
    do: nil

  defp auction_quick(_auction, currency) do
    %{
      verb: "Bid",
      currency: currency,
      unavailable: closed_before_deployment()
    }
  end

  # Until the contracts are deployed no quick button opens anything.
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

  defp connection_list(connections) when is_map(connections) do
    [:profile, :company, :x, :ens, :github]
    |> Enum.flat_map(&connection(&1, Map.get(connections, &1)))
    |> Enum.uniq_by(& &1.url)
  end

  defp connection_list(_connections), do: []

  defp connection(key, %{verified_at: %DateTime{}, username: name})
       when is_binary(name) and name != "" do
    {label, base} =
      case key do
        :ens -> {"ENS", "https://app.ens.domains/"}
        :github -> {"GitHub", "https://github.com/"}
        :company -> {"Company X", "https://x.com/"}
        _ -> {"X", "https://x.com/"}
      end

    [%{username: name, label: label, url: base <> URI.encode_www_form(name)}]
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

  defp web_link(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        if own_site?(host), do: nil, else: %{url: URI.to_string(uri), label: website_label(uri)}

      _other ->
        nil
    end
  end

  defp web_link(_url), do: nil

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
