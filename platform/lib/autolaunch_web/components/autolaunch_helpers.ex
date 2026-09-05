defmodule AutolaunchWeb.Components.AutolaunchHelpers do
  @moduledoc false
  use AutolaunchWeb, :html

  alias Autolaunch.Accounts.XOAuth
  alias Autolaunch.Actors.Human
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

  def empty_market, do: %{generation: 0, head: nil, degraded?: false, auctions: %{}}

  def page_record(%{ok?: true, result: %{record: record}}), do: record
  def page_record(_page), do: nil

  def page_status(%{ok?: true, result: %{status: status}}, _on_failed), do: status
  def page_status(%{failed: true}, on_failed), do: on_failed
  def page_status(_page, _on_failed), do: :loading

  def page_connections(%{ok?: true, result: %{creator_connections: connections}}),
    do: connections

  def page_connections(_page), do: %{}

  def page_list(%{ok?: true, result: result}, key), do: Map.get(result, key, [])
  def page_list(_page, _key), do: []

  def load_auction_page(id) do
    case Autolaunch.get_public_auction(id) do
      {:ok, nil} -> {:ok, %{page: empty_detail()}}
      {:ok, record} -> {:ok, %{page: ready_detail(record)}}
      {:error, _reason} -> {:ok, %{page: empty_detail()}}
    end
  end

  def load_token_page(id) do
    case Autolaunch.get_public_token(id) do
      {:ok, nil} -> {:ok, %{page: empty_detail()}}
      {:ok, record} -> {:ok, %{page: ready_detail(record)}}
      {:error, _reason} -> {:ok, %{page: empty_detail()}}
    end
  end

  def load_launch_page(id) do
    case Autolaunch.get_public_launch(id) do
      {:ok, nil} ->
        {:ok, %{page: empty_detail()}}

      {:ok, record} ->
        {:ok, %{page: ready_detail(record)}}

      {:error, _reason} ->
        {:ok, %{page: %{status: :error, record: nil, creator_connections: %{}}}}
    end
  end

  def load_subject_page(id) do
    case Autolaunch.get_public_subject(id) do
      {:ok, nil} ->
        {:ok, %{page: empty_subject()}}

      {:ok, subject} ->
        load_subject_details(subject)

      {:error, _reason} ->
        {:ok, %{page: error_subject()}}
    end
  end

  def load_holdings(%Human{} = actor) do
    with {:ok, positions} <- Autolaunch.list_my_bid_positions(actor: actor),
         {:ok, returnable} <- Autolaunch.list_my_returnable_bid_positions(actor: actor),
         {:ok, claimed} <- Autolaunch.list_my_claimed_token_positions(actor: actor) do
      {:ok,
       %{
         status: :ready,
         positions: positions,
         returnable_positions: returnable,
         claimed_token_positions: Enum.filter(claimed, & &1.token)
       }}
    else
      _error -> {:error, :unavailable}
    end
  end

  def human_actor(%{principal: {:human, account}}),
    do: %Human{human_account_id: account.id}

  def human_actor(_access_context), do: nil

  def current_human_id(%{principal: {:human, %{id: id}}}), do: id
  def current_human_id(_access_context), do: nil

  attr :actions, :list, required: true
  attr :empty_copy, :string, required: true
  attr :id_prefix, :string, required: true

  def subject_action_list(assigns) do
    ~H"""
    <p :if={@actions == []} class="autolaunch-empty">{@empty_copy}</p>
    <ol :if={@actions != []} class="autolaunch-record-list">
      <li :for={action <- @actions} id={"#{@id_prefix}-#{action.id}"}>
        <article>
          <h3>{display_action(action.action)}</h3>
          <dl>
            <div>
              <dt>Status</dt><dd>{display_text(action.status)}</dd>
            </div>
            <div>
              <dt>Owner</dt><dd>{display_text(action.owner_address)}</dd>
            </div>
            <div>
              <dt>Chain</dt><dd>{action.chain_id}</dd>
            </div>
            <div>
              <dt>Transaction</dt><dd>{display_text(action.tx_hash)}</dd>
            </div>
            <div>
              <dt>Amount</dt><dd>{display_text(action.amount)}</dd>
            </div>
            <div>
              <dt>Block</dt><dd>{display_text(action.block_number)}</dd>
            </div>
            <div>
              <dt>Time</dt><dd>{display_time(action.inserted_at)}</dd>
            </div>
          </dl>
        </article>
      </li>
    </ol>
    """
  end

  defp load_subject_details(subject) do
    with {:ok, tokens} <- Autolaunch.list_subject_tokens(subject.subject_id),
         {:ok, actions} <- Autolaunch.list_subject_actions(subject.subject_id),
         {:ok, settlements} <- Autolaunch.list_subject_settlements(subject.subject_id) do
      {:ok,
       %{
         page: %{
           status: :ready,
           record: subject,
           creator_connections: %{},
           tokens: tokens,
           actions: actions,
           settlements: settlements
         }
       }}
    else
      {:error, _reason} -> {:ok, %{page: error_subject()}}
    end
  end

  defp ready_detail(record),
    do: %{status: :ready, record: record, creator_connections: creator_connections(record)}

  defp empty_detail, do: %{status: :empty, record: nil, creator_connections: %{}}

  defp empty_subject,
    do: %{
      status: :empty,
      record: nil,
      creator_connections: %{},
      tokens: [],
      actions: [],
      settlements: []
    }

  defp error_subject,
    do: %{
      status: :error,
      record: nil,
      creator_connections: %{},
      tokens: [],
      actions: [],
      settlements: []
    }

  defp creator_connections(record) do
    case creator_id(record) do
      id when is_integer(id) ->
        case XOAuth.public_for_humans([id]) do
          {:ok, connections} ->
            connections
            |> group_x_connections()
            |> Map.get(id, %{})

          {:error, _reason} ->
            %{}
        end

      _missing ->
        %{}
    end
  end

  defp creator_id(%{creator_human_account_id: id}), do: id
  defp creator_id(%{auction: %{creator_human_account_id: id}}), do: id
  defp creator_id(_record), do: nil

  defp group_x_connections(connections) do
    Enum.reduce(connections, %{}, fn connection, grouped ->
      Map.update(
        grouped,
        connection.human_account_id,
        %{connection.role => connection},
        &Map.put(&1, connection.role, connection)
      )
    end)
  end
end
