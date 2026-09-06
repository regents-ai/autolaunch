defmodule AutolaunchWeb.Components.MarketCard do
  @moduledoc false
  use Phoenix.Component

  alias Autolaunch.Token

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

  attr :view, :map, required: true

  defp card_contents(assigns) do
    ~H"""
    <div class="launchpad-card__media">
      <img :if={present?(@view.image)} src={@view.image} alt={"#{@view.name} token"} />
      <span :if={!present?(@view.image)} aria-hidden="true">R</span>
      <small>{@view.status}</small>
    </div>
    <div class="launchpad-card__body">
      <div class="launchpad-card__title">
        <h3>{@view.name}</h3>
        <span :if={present?(@view.symbol)}>${@view.symbol}</span>
      </div>
      <p class="launchpad-card__metric">{present(@view.metric, "No price yet")}</p>
      <p :if={present?(@view.creator) or present?(@view.age)} class="launchpad-card__meta">
        <span :if={present?(@view.creator)}>{@view.creator}</span>
        <span :if={present?(@view.age)}>{@view.age}</span>
      </p>
      <p class="launchpad-card__summary">{@view.description}</p>
    </div>
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
      metric: suffix(values["required_regent_raised"], " REGENT"),
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
      metric: auction.current_clearing_price,
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
      metric: present(token.price_quote, "No price yet"),
      address: presentation.auction_address,
      path: "/tokens/#{token.id}",
      creator: creator_name(connections),
      age: relative_age(Map.get(token, :graduated_at) || Map.get(token, :inserted_at)),
      connections: connection_list(connections)
    }
  end

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
  defp suffix(value, suffix), do: if(present?(value), do: value <> suffix, else: nil)

  defp role_label(:profile), do: "Creator"
  defp role_label(:company), do: "Company"
end
