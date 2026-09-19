defmodule AutolaunchWeb.Components.MarketCard do
  @moduledoc false
  use Phoenix.Component

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
      <.card_socials connections={@view.connections} />
    </article>
    """
  end

  attr :kind, :atom, required: true, values: [:auction, :robinhood_auction, :token]
  attr :record, :map, required: true
  attr :creator_connections, :map, default: %{}
  attr :trade_event, :string, default: nil

  def explore_card(assigns) do
    assigns =
      assign(assigns, :view, view(assigns.kind, assigns.record, assigns.creator_connections))

    ~H"""
    <article class="home-coin">
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
          href={"https://x.com/#{URI.encode_www_form(hd(@view.connections).username)}"}
          target="_blank"
          rel="noopener noreferrer"
        >{@view.creator}</a>
        <span :if={@view.connections == []}>Creator unavailable</span>
        <span :if={@view.age} class="home-coin__age">{@view.age}</span>
        <span class="home-coin__status">{@view.status}</span>
        <span :if={@kind == :robinhood_auction} class="home-coin__status">Robinhood</span>
      </div>
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

  attr :kind, :atom, required: true, values: [:auction, :robinhood_auction]
  attr :record, :map, required: true
  attr :creator_connections, :map, default: %{}
  attr :trade_event, :string, default: nil

  @doc "The large auction card of the auctions page: who, where, what state, and how to bid."
  def auction_card(assigns) do
    assigns =
      assign(assigns, :view, view(assigns.kind, assigns.record, assigns.creator_connections))

    ~H"""
    <article class="auction-card" data-state={@view.state}>
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
          <span class="auction-card__state">{@view.status}</span>
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
          <dt>Raised</dt>
          <dd><TokenDisplay.price amount={@view.raised.amount} unit={@view.raised.unit} /></dd>
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
              href={"https://x.com/#{URI.encode_www_form(hd(@view.connections).username)}"}
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
      <.link :if={!@view.quick} navigate={@view.path} class="auction-card__more">
        View auction <span aria-hidden="true">→</span>
      </.link>
    </article>
    """
  end

  attr :kind, :atom, required: true, values: [:auction, :robinhood_auction, :token]
  attr :record, :map, required: true
  attr :creator_connections, :map, default: %{}
  attr :trade_event, :string, default: nil

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
          <span><strong>{@view.name}</strong><small>${@view.symbol}{if @kind == :robinhood_auction,
            do: " · Robinhood"}</small></span>
        </.link>
      </td>
      <td><TokenDisplay.price amount={@view.metric.amount} unit={@view.metric.unit} /></td>
      <td data-label="Creator">
        <a
          :if={@view.connections != []}
          href={"https://x.com/#{URI.encode_www_form(hd(@view.connections).username)}"}
          target="_blank"
          rel="noopener noreferrer"
        >{@view.creator}</a><span :if={@view.connections == []}>—</span>
      </td>
      <td data-label="Age">{@view.age || "—"}</td>
      <td data-label={if @kind == :token, do: "Pair", else: "Status"}>
        {if @kind == :token, do: "#{@view.symbol} / #{@view.quick.currency}", else: @view.status}
      </td>
      <td :if={@trade_event}>
        <.quick_actions
          :if={@view.quick}
          event={@trade_event}
          record_id={@view.record_id}
          name={@view.name}
          quick={@view.quick}
        />
      </td>
    </tr>
    """
  end

  attr :kind, :atom, required: true, values: [:auction, :token]
  attr :record, :map, required: true
  attr :creator_connections, :map, default: %{}

  attr :trade_path, :string,
    default: nil,
    doc: "set once the coin trades; takes the description's place"

  def detail_card(assigns) do
    assigns =
      assign(assigns, :view, view(assigns.kind, assigns.record, assigns.creator_connections))

    ~H"""
    <section class="market-identity" aria-label="Coin overview">
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
          <span>{@view.status}</span><span :if={@view.age}>{@view.age} ago</span>
        </div>
        <div class="market-identity__price">
          <span>{@view.metric_label}</span><TokenDisplay.price
            amount={@view.metric.amount}
            unit={@view.metric.unit}
          />
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
        <.card_socials connections={@view.connections} />
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

  defp card_socials(assigns) do
    ~H"""
    <div :if={@connections != []} class="launchpad-card__socials" aria-label="Creator accounts">
      <a
        :for={connection <- @connections}
        href={"https://x.com/#{URI.encode_www_form(connection.username)}"}
        target="_blank"
        rel="noreferrer"
      >
        <span>{role_label(connection.role)}</span> @{connection.username}
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

  defp view(:auction, auction, connections) do
    %{
      name: auction.title,
      symbol: auction.token_symbol,
      description: present(auction.summary, "Auction details are recorded onchain."),
      image: auction.image,
      status: auction.state |> to_string() |> String.capitalize(),
      metric_label: "Clearing price",
      metric: metric(auction.current_clearing_price, auction.quote_token_symbol),
      address: auction.auction_address,
      path: "/auctions/#{auction.id}",
      creator: creator_name(connections),
      age: relative_age(Map.get(auction, :inserted_at) || Map.get(auction, :opened_at)),
      connections: connection_list(connections),
      quick: auction_quick(auction),
      record_id: auction.id,
      state: auction.state,
      chain: "Base",
      launch: if(auction.kind == :stocks, do: "Memestock", else: "Revstake"),
      raised: nil
    }
  end

  # A Robinhood auction is read from its chain, which records no image,
  # description, creator or opening time, so the card shows none.
  defp view(:robinhood_auction, auction, _connections) do
    %{
      name: auction.name,
      symbol: auction.symbol,
      description: nil,
      image: nil,
      status: auction.state |> to_string() |> String.capitalize(),
      metric_label: "Clearing price",
      metric: metric(auction.clearing_price, auction.stock_symbol),
      address: auction.auction,
      path: "/robinhood/auctions/#{auction.auction}",
      creator: nil,
      age: nil,
      connections: [],
      quick: auction_quick(auction, "USDG"),
      record_id: auction.auction,
      state: auction.state,
      chain: "Robinhood",
      launch: "Memestock",
      raised: metric(auction.raised, auction.stock_symbol)
    }
  end

  defp view(:token, token, connections) do
    presentation = Token.presentation(token)

    %{
      name: presentation.name,
      symbol: presentation.symbol,
      description: present(presentation.summary, "Graduated token"),
      image: presentation.image,
      status: "Graduated",
      metric_label: "Price",
      metric: metric(token.price_quote, nil),
      address: presentation.auction_address,
      path: "/tokens/#{token.id}",
      creator: creator_name(connections),
      age: relative_age(Map.get(token, :graduated_at) || Map.get(token, :inserted_at)),
      connections: connection_list(connections),
      quick: %{
        verb: "Buy",
        currency: SwapComponent.entry_symbol(token.auction),
        unavailable: closed_before_deployment()
      },
      record_id: token.id
    }
  end

  # An auction that has ended takes no bids, so its row offers none.
  defp auction_quick(auction), do: auction_quick(auction, BidComponent.bid_currency(auction))

  defp auction_quick(%{state: state}, _currency) when state in [:graduated, :failed], do: nil

  defp auction_quick(_auction, currency) do
    %{
      verb: "Bid",
      currency: currency,
      unavailable: closed_before_deployment()
    }
  end

  # Until the contracts are deployed no quick button opens anything.
  defp closed_before_deployment,
    do: if(Autolaunch.Prelaunch.read_only?(), do: "Available after contract deployment")

  # The stored figure travels untouched; only its on-screen form is shortened.
  defp metric(amount, unit), do: %{amount: present(amount, nil), unit: present(unit, nil)}

  defp connection_list(connections) when is_map(connections) do
    [:profile, :company]
    |> Enum.map(&Map.get(connections, &1))
    |> Enum.filter(&verified?/1)
    |> Enum.uniq_by(& &1.x_user_id)
  end

  defp connection_list(_connections), do: []

  defp verified?(%{verified_at: %DateTime{}, username: username}) when is_binary(username),
    do: true

  defp verified?(_connection), do: false

  defp creator_name(connections) do
    connections
    |> connection_list()
    |> List.first()
    |> case do
      %{username: username} -> "@" <> username
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

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp present(value, fallback), do: if(present?(value), do: value, else: fallback)

  defp role_label(:profile), do: "Creator"
  defp role_label(:company), do: "Company"
end
