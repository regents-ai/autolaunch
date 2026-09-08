defmodule AutolaunchWeb.Components.MarketCard do
  @moduledoc false
  use Phoenix.Component

  alias Autolaunch.Token
  alias AutolaunchWeb.TokenDisplay

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

  attr :kind, :atom, required: true, values: [:auction, :token]
  attr :record, :map, required: true
  attr :creator_connections, :map, default: %{}

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
      </div>
      <p :if={present?(@view.description)} class="home-coin__description">{@view.description}</p>
    </article>
    """
  end

  attr :kind, :atom, required: true, values: [:auction, :token]
  attr :record, :map, required: true
  attr :creator_connections, :map, default: %{}

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
          <span><strong>{@view.name}</strong><small>${@view.symbol}</small></span>
        </.link>
      </td>
      <td><TokenDisplay.price amount={@view.metric.amount} unit={@view.metric.unit} /></td>
      <td>
        <a
          :if={@view.connections != []}
          href={"https://x.com/#{URI.encode_www_form(hd(@view.connections).username)}"}
          target="_blank"
          rel="noopener noreferrer"
        >{@view.creator}</a><span :if={@view.connections == []}>—</span>
      </td>
      <td>{@view.age || "—"}</td><td>{@view.status}</td>
    </tr>
    """
  end

  attr :kind, :atom, required: true, values: [:auction, :token]
  attr :record, :map, required: true
  attr :creator_connections, :map, default: %{}

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
        <p :if={present?(@view.description)} class="market-identity__description">
          {@view.description}
        </p>
        <.card_socials connections={@view.connections} />
      </div>
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
      metric_label: "Raise target",
      metric: metric(values["required_regent_raised"], "REGENT"),
      address: nil,
      path: nil,
      creator: creator_name(connections),
      age: nil,
      connections: connection_list(connections)
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
      connections: connection_list(connections)
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
      connections: connection_list(connections)
    }
  end

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
