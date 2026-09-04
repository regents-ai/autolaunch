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
      <p>{@view.description}</p>
      <dl>
        <div :if={present?(@view.metric)}>
          <dt>{@view.metric_label}</dt><dd>{@view.metric}</dd>
        </div>
        <div :if={present?(@view.address)}>
          <dt>Contract</dt><dd>{short_address(@view.address)}</dd>
        </div>
      </dl>
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
      metric: token.price_quote,
      address: presentation.auction_address,
      path: "/tokens/#{token.id}",
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

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp present(value, fallback), do: if(present?(value), do: value, else: fallback)
  defp suffix(value, suffix), do: if(present?(value), do: value <> suffix, else: nil)

  defp short_address(value) when is_binary(value) and byte_size(value) == 42,
    do: String.slice(value, 0, 6) <> "…" <> String.slice(value, -4, 4)

  defp short_address(value), do: value
  defp role_label(:profile), do: "Creator"
  defp role_label(:company), do: "Company"
end
