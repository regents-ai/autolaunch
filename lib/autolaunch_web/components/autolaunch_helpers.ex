defmodule AutolaunchWeb.Components.AutolaunchHelpers do
  @moduledoc false
  use AutolaunchWeb, :html

  alias Autolaunch.Lab
  alias Autolaunch.Token
  alias Autolaunch.TreasurySecurity

  def read_index(reader) do
    case reader.() do
      {:ok, records} -> {:ok, %{records: records}}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  attr :kind, :atom, required: true, values: [:auctions, :tokens]
  attr :records, :map, required: true

  def collection(assigns) do
    assigns =
      assign(assigns,
        title: if(assigns.kind == :auctions, do: "Auctions", else: "Tokens"),
        copy:
          if(
            assigns.kind == :auctions,
            do: "Discover live raises, compare auction state, and open one to place a bid.",
            else: "Explore tokens that completed an auction and graduated to liquidity."
          ),
        empty_title: if(assigns.kind == :auctions, do: "No auctions yet", else: "No tokens yet"),
        empty_copy:
          if(
            assigns.kind == :auctions,
            do: "Start the first launch and it will appear here for bidders.",
            else: "Tokens appear here after their auction graduates."
          ),
        empty_action:
          if(assigns.kind == :auctions, do: "Create a launch", else: "Browse auctions"),
        empty_path: if(assigns.kind == :auctions, do: "/create", else: "/auctions")
      )

    ~H"""
    <section id={"autolaunch-#{@kind}"} class="autolaunch-page">
      <header class="autolaunch-heading">
        <p class="autolaunch-kicker">Browse the market</p>
        <h1>{@title}</h1>
        <p>{@copy}</p>
      </header>
      <section
        :if={@records.ok? && @records.result == []}
        class="autolaunch-empty autolaunch-market-empty"
      >
        <p class="autolaunch-kicker">Be first</p>
        <h2>{@empty_title}</h2>
        <p>{@empty_copy}</p>
        <.link href={@empty_path}>{@empty_action} <span aria-hidden="true">→</span></.link>
      </section>
      <.empty_state :if={@records.failed} copy="Public records are unavailable right now." />
      <.market_feed
        :if={@records.ok? && @records.result != []}
        title={@title}
        kind={collection_record_kind(@kind)}
        records={@records.result}
        empty_copy=""
      />
    </section>
    """
  end

  attr :title, :string, required: true
  attr :kind, :atom, required: true
  attr :records, :list, required: true
  attr :empty_copy, :string, required: true

  def market_feed(assigns) do
    ~H"""
    <section class="autolaunch-feed" aria-label={@title}>
      <header>
        <h3>{@title}</h3>
        <span>{length(@records)} shown</span>
      </header>
      <p :if={@records == []} class="autolaunch-feed__empty">{@empty_copy}</p>
      <ol :if={@records != []}>
        <li :for={record <- @records}>
          <.link navigate={record_path(@kind, record.id)}>
            <span class="autolaunch-feed__status">{market_status(@kind, record)}</span>
            <strong>{record_label(@kind, record)}</strong>
            <span class="autolaunch-feed__summary">
              {record_summary(@kind, record) || record_fallback(@kind)}
            </span>
            <span class="autolaunch-feed__metric">{market_metric(@kind, record)}</span>
            <span class="autolaunch-feed__action">{market_action(@kind)}
            <span aria-hidden="true">→</span></span>
          </.link>
          <.treasury_security
            :if={!Lab.enabled?()}
            report={report(record)}
            surface={"overview-#{@kind}-#{record.id}"}
          />
        </li>
      </ol>
    </section>
    """
  end

  attr :report, :any, default: nil
  attr :surface, :string, required: true

  def treasury_security(assigns) do
    assigns = assign(assigns, :view, TreasurySecurity.public_view(assigns.report))

    ~H"""
    <aside id={"treasury-security-#{@surface}"} class="treasury-security" role="status">
      <h3>Treasury security</h3>
      <p :if={is_nil(@view)} class="treasury-security--warning">
        No current treasury report is available. Custody is unverified.
      </p>
      <dl :if={@view}>
        <div>
          <dt>Immutable recipient</dt><dd>{@view.address}</dd>
        </div>
        <div>
          <dt>Type</dt><dd>{display_action(@view.classification)}</dd>
        </div>
        <div>
          <dt>Verification</dt><dd>Awaiting current chain confirmation</dd>
        </div>
        <div :if={@view.downgrade_state != "none"}>
          <dt>Downgrade</dt><dd>Configuration changed after a verified observation</dd>
        </div>
      </dl>
      <p :if={@view} class="treasury-security--warning">
        Verification remains fail-closed until canonical projector refresh is integrated.
      </p>
    </aside>
    """
  end

  attr :copy, :string, required: true

  def empty_state(assigns) do
    ~H"""
    <div class="autolaunch-empty">
      <p>{@copy}</p>
    </div>
    """
  end

  def record_path(:auction, id), do: "/auctions/#{id}"
  def record_path(:token, id), do: "/tokens/#{id}"
  def record_path(:launch, id), do: "/launches/#{id}"
  def record_path(:subject, id), do: "/subjects/#{id}"
  def record_path(:portfolio, _id), do: "/portfolio"

  def record_label(:auction, record), do: record.title

  def record_label(:token, record) do
    presentation = Token.presentation(record)
    "#{presentation.name} · #{presentation.symbol}"
  end

  def record_summary(:auction, record), do: record.summary
  def record_summary(:token, record), do: Token.presentation(record).summary

  def record_fallback(:auction), do: "No public summary yet."
  def record_fallback(:token), do: "No public token summary yet."

  def empty_market_copy("", fallback), do: fallback
  def empty_market_copy(_query, _fallback), do: "No matching auctions or tokens."

  def connections_for(%{creator_human_account_id: id}, grouped) when is_integer(id),
    do: Map.get(grouped, id, %{})

  def connections_for(%{auction: %{creator_human_account_id: id}}, grouped)
      when is_integer(id),
      do: Map.get(grouped, id, %{})

  def connections_for(_record, _grouped), do: %{}

  def market_status(:auction, record), do: display_status(record.state)
  def market_status(:token, _record), do: "Graduated"

  def market_metric(:auction, %{current_clearing_price: price})
      when is_binary(price) and price != "",
      do: "Clearing price #{price}"

  def market_metric(:auction, _record), do: "Price forming"

  def market_metric(:token, %{price_quote: price}) when is_binary(price) and price != "",
    do: "Price #{price}"

  def market_metric(:token, _record), do: "Market price pending"

  def market_action(:auction), do: "View auction"
  def market_action(:token), do: "View token"

  def auction_market_snapshot(%{auctions: auctions}, %{auction_address: address})
      when is_binary(address),
      do: Map.get(auctions, String.downcase(address))

  def auction_market_snapshot(_market, _record), do: nil

  def collection_record_kind(:auctions), do: :auction
  def collection_record_kind(:tokens), do: :token

  def report(%{treasury_security_report: %Ash.NotLoaded{}}), do: nil
  def report(%{treasury_security_report: report}), do: report
  def report(_record), do: nil

  def subject_label(%{subject_id: subject_id}), do: subject_id

  def launch_label(%{token_name: token_name, token_symbol: token_symbol}),
    do: "#{token_name} · #{token_symbol}"

  def launch_agent(%{agent_name: value}) when is_binary(value) and value != "", do: value
  def launch_agent(%{agent_id: value}), do: value

  def bid_title(%{token: %Token{}} = position) do
    presentation = position_token_presentation(position)
    "#{presentation.name} · #{presentation.symbol}"
  end

  def bid_title(%{auction: %{title: title}}), do: title
  def bid_title(%{bid_id: bid_id}), do: "Bid #{bid_id}"

  def position_token_presentation(%{token: %Token{} = token, auction: %{title: _} = auction}),
    do: token |> Map.put(:auction, auction) |> Token.presentation()

  def position_token_presentation(%{token: %Token{} = token}), do: Token.presentation(token)

  def display_status(value) do
    value
    |> display_action()
    |> String.capitalize()
  end

  def display_text(nil), do: "Not available"
  def display_text(value) when is_atom(value), do: Atom.to_string(value)
  def display_text(value) when is_integer(value), do: Integer.to_string(value)

  def display_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "Not available"
      text -> text
    end
  end

  def display_bps(nil), do: "Not available"
  def display_bps(value), do: "#{value} bps"

  def display_action(value) do
    value
    |> display_text()
    |> String.replace("_", " ")
  end

  def display_time(%DateTime{} = value),
    do: Calendar.strftime(value, "%b %-d, %Y at %H:%M UTC")

  def display_time(_value), do: "Not available"
end
