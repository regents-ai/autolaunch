defmodule AutolaunchWeb.Components.MarketCard do
  @moduledoc false
  use Phoenix.Component

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Token
  alias AutolaunchWeb.{BidComponent, SwapComponent, TokenDisplay}

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
        <div class="home-coin__metric">
          <TokenDisplay.price amount={@view.metric.amount} unit={@view.metric.unit} /><span>{@view.metric_label}</span>
        </div>
      </.link>
      <div class="home-coin__meta">
        <a
          :if={@view.connections != []}
          href={hd(@view.connections).url}
          target="_blank"
          rel="noopener noreferrer"
        >{@view.creator}</a>
        <span :if={@view.connections == []}>Creator unavailable</span>
        <span :if={@view.age} class="home-coin__age">{@view.age}</span>
        <span class={["home-coin__status", graduated(@view.status)]}>{@view.status}</span>
        <span :if={@view.chain == "Robinhood"} class="home-coin__status">Robinhood</span>
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

  attr :kind, :atom, required: true, values: [:auction]
  attr :record, :map, required: true
  attr :creator_connections, :map, default: %{}
  attr :trade_event, :string, default: nil

  attr :reading, :map,
    default: nil,
    doc: "the market feed's reading of the auction, which carries its amount raised"

  @doc "The large auction card of the auctions page: who, where, what state, and how to bid."
  def auction_card(assigns) do
    view =
      assigns.kind
      |> view(assigns.record, assigns.creator_connections)
      |> with_reading(assigns.reading)

    assigns = assign(assigns, view: view, minimum_reached: minimum_reached?(view))

    ~H"""
    <article
      class={["auction-card", @view.color && "auction-card--tinted"]}
      style={tint(@view.color)}
      data-state={@view.state}
    >
      <.link navigate={@view.path} class="auction-card__main">
        <header class="auction-card__head">
          <div class="auction-card__art">
            <img
              :if={present?(@view.image)}
              src={@view.image}
              alt={"#{@view.name} token"}
              loading="lazy"
              decoding="async"
              width="128"
              height="128"
            />
            <span :if={!present?(@view.image)} aria-label="No token image">{String.first(
              @view.name || "?"
            )}</span>
          </div>
          <div class="auction-card__title">
            <h2>{@view.name}</h2>
            <p>${@view.symbol}</p>
          </div>
          <span class={["auction-card__state", graduated(@view.status)]}>{@view.status}</span>
        </header>
        <p class="auction-card__tags">
          <span>{@view.chain}</span><span>{@view.launch}</span>
        </p>
        <p :if={present?(@view.description)} class="auction-card__description">
          {@view.description}
        </p>
      </.link>
      <dl class="auction-card__stats">
        <div>
          <dt>{@view.metric_label}</dt>
          <dd><TokenDisplay.price amount={@view.metric.amount} unit={@view.metric.unit} /></dd>
        </div>
        <div :if={@view.raised}>
          <dt>{if @view.state == :failed, do: "Bid before refunds", else: "Raised"}</dt>
          <dd>
            <TokenDisplay.price amount={@view.raised.amount} unit={@view.raised.unit} /><span
              :if={@minimum_reached}
              class="auction-card__met"
              title="Minimum reached"
            ><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 8.5l3 3 6-7" /></svg><span class="visually-hidden">Minimum reached</span></span>
          </dd>
        </div>
        <div :if={@view.quick}>
          <dt>Bids in</dt>
          <dd>{@view.quick.currency}</dd>
        </div>
        <div :if={@view.age}>
          <dt>Opened</dt>
          <dd>{@view.age} ago</dd>
        </div>
        <div :if={@view.connections != []}>
          <dt>Creator</dt>
          <dd>
            <a
              href={hd(@view.connections).url}
              target="_blank"
              rel="noopener noreferrer"
            >{@view.creator}</a>
          </dd>
        </div>
      </dl>
      <.quick_actions
        :if={@trade_event && @view.quick}
        event={@trade_event}
        record_id={@view.record_id}
        name={@view.name}
        quick={@view.quick}
      />
      <.card_socials connections={@view.connections} compact />
      <.link :if={!@view.quick} navigate={@view.path} class="auction-card__more">
        View auction <span aria-hidden="true">→</span>
      </.link>
    </article>
    """
  end

  attr :kind, :atom, required: true, values: [:auction, :token]
  attr :record, :map, required: true
  attr :creator_connections, :map, default: %{}
  attr :trade_event, :string, default: nil
  attr :quick_column, :boolean, default: false, doc: "the table has a quick-action column"

  def explore_row(assigns) do
    assigns =
      assign(assigns, :view, view(assigns.kind, assigns.record, assigns.creator_connections))

    ~H"""
    <tr>
      <td>
        <.link navigate={@view.path} class="home-table__coin">
          <img
            :if={present?(@view.image)}
            src={@view.image}
            alt=""
            width="48"
            height="48"
            loading="lazy"
          />
          <span :if={!present?(@view.image)} class="home-table__fallback" aria-hidden="true">{String.first(
            @view.name || "?"
          )}</span>
          <span><strong>{@view.name}</strong><small>${@view.symbol}{if @view.chain == "Robinhood",
            do: " · Robinhood"}</small></span>
        </.link>
      </td>
      <td><TokenDisplay.price amount={@view.metric.amount} unit={@view.metric.unit} /></td>
      <td data-label="Creator">
        <a
          :if={@view.connections != []}
          href={hd(@view.connections).url}
          target="_blank"
          rel="noopener noreferrer"
        >{@view.creator}</a><span :if={@view.connections == []}>—</span>
      </td>
      <td data-label="Age">{@view.age || "—"}</td>
      <td data-label={if @view.pair, do: "Pair", else: "Status"}>
        {@view.pair || @view.status}
      </td>
      <td :if={@quick_column}>
        <.quick_actions
          :if={@trade_event && @view.quick}
          event={@trade_event}
          record_id={@view.record_id}
          name={@view.name}
          quick={@view.quick}
        />
      </td>
    </tr>
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
          <span class={graduated(@status || @view.status)}>{@status || @view.status}</span>
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
        <.card_socials connections={@view.connections} website={@view.website} />
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
      address: nil,
      path: nil,
      creator: creator_name(connections),
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
      address: auction.auction_address,
      path:
        if(robinhood?,
          do: "/robinhood/auctions/#{auction.auction_address}",
          else: "/auctions/#{auction.id}"
        ),
      creator: creator_name(connections),
      age: relative_age(Map.get(auction, :inserted_at) || Map.get(auction, :opened_at)),
      connections: connection_list(connections),
      quick:
        auction_quick(
          auction,
          if(robinhood?, do: "USDG", else: BidComponent.bid_currency(auction))
        ),
      record_id: auction.id,
      state: auction.state,
      chain: if(robinhood?, do: "Robinhood", else: "Base"),
      launch: if(auction.kind == :stocks, do: "Memestake", else: "Revstake"),
      raised: nil,
      minimum:
        auction.required_currency_raised
        |> String.to_integer()
        |> Rpc.format_units(auction.quote_token_decimals),
      pair: nil
    }
  end

  # A graduated Robinhood launch's page is named by its token's address; it
  # trades on its own page, so its row offers no quick buy.
  defp view(:token, %{auction: %{chain_id: chain_id} = auction} = token, connections) do
    if RobinhoodLab.chain?(chain_id) do
      presentation = Token.presentation(token)

      %{
        base_token_view(token, connections)
        | metric: metric(token.price_quote, auction.quote_token_symbol),
          path: "/robinhood/tokens/#{auction.token_address}",
          quick: nil,
          chain: "Robinhood",
          pair: "#{presentation.symbol} / #{auction.quote_token_symbol}"
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
      metric: metric(token.price_quote, currency),
      address: presentation.auction_address,
      path: "/tokens/#{token.id}",
      creator: creator_name(connections),
      age: relative_age(Map.get(token, :graduated_at) || Map.get(token, :inserted_at)),
      connections: connection_list(connections),
      quick: %{
        verb: "Buy",
        currency: currency,
        unavailable: closed_before_deployment()
      },
      record_id: token.id,
      chain: "Base",
      pair: "#{presentation.symbol} / #{currency}"
    }
  end

  @doc "An auction state in the words the site uses: live means open for bidding."
  def state_label(:created), do: "Opening soon"
  def state_label(:active), do: "Live"
  def state_label(:ended), do: "Waiting to finish"
  def state_label(:graduated), do: "Graduated"
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

  # The stored figure travels untouched; only its on-screen form is shortened.
  # An auction's amount raised is read from its chain by its market feed.
  defp with_reading(view, nil), do: view

  defp with_reading(view, reading),
    do: %{view | raised: metric(reading.currency_raised, view.metric.unit)}

  # Both amounts are whole units, as plain decimals.
  defp minimum_reached?(%{raised: %{amount: raised}, minimum: minimum})
       when is_binary(raised),
       do: Decimal.compare(Decimal.new(raised), Decimal.new(minimum)) != :lt

  defp minimum_reached?(_view), do: false

  # A card whose image has a known colour carries it for its border, background
  # and graduated badge.
  defp tint(nil), do: nil
  defp tint(color), do: "--image-color: #{color}"

  defp graduated("Graduated"), do: "market-graduated"
  defp graduated(_status), do: nil

  defp metric(amount, unit), do: %{amount: present(amount, nil), unit: present(unit, nil)}

  defp connection_list(connections) when is_map(connections) do
    [:profile, :company, :x, :ens, :github]
    |> Enum.flat_map(fn key ->
      case Map.get(connections, key) do
        %{verified_at: %DateTime{}, username: name} when is_binary(name) and name != "" ->
          {label, base} =
            case key do
              :ens -> {"ENS", "https://app.ens.domains/"}
              :github -> {"GitHub", "https://github.com/"}
              :company -> {"Company X", "https://x.com/"}
              _ -> {"X", "https://x.com/"}
            end

          [%{username: name, label: label, url: base <> URI.encode_www_form(name)}]

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(& &1.url)
  end

  defp connection_list(_connections), do: []

  defp creator_name(connections) do
    connections
    |> connection_list()
    |> List.first()
    |> case do
      %{username: username} -> username
      _ -> nil
    end
  end

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
        %{url: URI.to_string(uri), label: website_label(uri)}

      _other ->
        nil
    end
  end

  defp web_link(_url), do: nil

  defp website_label(%URI{host: host, path: path}),
    do: String.trim_leading(host, "www.") <> String.trim_trailing(path || "", "/")

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp present(value, fallback), do: if(present?(value), do: value, else: fallback)
end
