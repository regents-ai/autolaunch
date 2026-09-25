defmodule AutolaunchWeb.Components.AutolaunchHelpers do
  @moduledoc false
  use AutolaunchWeb, :html

  alias Autolaunch.Accounts.XOAuth
  alias Autolaunch.Actors.Human
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Token
  alias Autolaunch.TreasurySecurity

  def read_index(reader) do
    case reader.() do
      {:ok, records} ->
        {:ok, %{records: records, creators: creator_connections_for(records)}}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  def creator_connections_for(records) when is_list(records) do
    ids =
      records
      |> Enum.map(&creator_id/1)
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    x =
      case XOAuth.public_for_humans(ids) do
        {:ok, connections} -> group_x_connections(connections)
        {:error, _reason} -> %{}
      end

    case Autolaunch.Accounts.list_public_linked_identities(ids, actor: nil) do
      {:ok, identities} ->
        Enum.reduce(identities, x, fn identity, grouped ->
          Map.update(
            grouped,
            identity.human_account_id,
            %{identity.provider => identity},
            &Map.put(&1, identity.provider, identity)
          )
        end)

      {:error, _reason} ->
        x
    end
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
    </aside>
    """
  end

  attr :surface, :string, required: true

  # A local-fork site has no treasury evidence to show: the fixture the lab
  # runs on is not a chain observation, so the page says so instead.
  def lab_treasury_unavailable(assigns) do
    ~H"""
    <aside id={"treasury-security-#{@surface}"} class="treasury-security" role="status">
      <h3>Treasury security</h3>
      <p class="treasury-security--warning">
        Treasury verification is not available on this Base fork. Custody is unverified here.
      </p>
    </aside>
    """
  end

  attr :id, :string, required: true
  attr :summary, :string, required: true
  attr :amount, :string, default: nil
  attr :unit, :string, default: nil

  # The stored figure, unshortened, for anyone who needs every digit.
  def exact_price(assigns) do
    ~H"""
    <Regent.Primitives.disclosure :if={present?(@amount)} id={@id} summary={@summary}>
      <p class="autolaunch-exact-value">{@amount}{if present?(@unit), do: " #{@unit}"}</p>
    </Regent.Primitives.disclosure>
    """
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  attr :copy, :string, required: true

  def empty_state(assigns) do
    ~H"""
    <div class="autolaunch-empty">
      <p>{@copy}</p>
    </div>
    """
  end

  def record_label(:auction, record), do: record.title

  def record_label(:token, record) do
    presentation = Token.presentation(record)
    "#{presentation.name} · #{presentation.symbol}"
  end

  def connections_for(%{creator_human_account_id: id}, grouped) when is_integer(id),
    do: Map.get(grouped, id, %{})

  def connections_for(%{auction: %{creator_human_account_id: id}}, grouped)
      when is_integer(id),
      do: Map.get(grouped, id, %{})

  def connections_for(_record, _grouped), do: %{}

  def auction_market_snapshot(%{auctions: auctions}, %{auction_address: address})
      when is_binary(address),
      do: Map.get(auctions, String.downcase(address))

  def auction_market_snapshot(_market, _record), do: nil

  @doc "Whether a listed auction, or a listed token's auction, is on Robinhood."
  def robinhood?(%Token{auction: auction}), do: robinhood?(auction)
  def robinhood?(%{chain_id: chain_id}), do: RobinhoodLab.chain?(chain_id)

  def report(%{treasury_security_report: %Ash.NotLoaded{}}), do: nil
  def report(%{treasury_security_report: report}), do: report
  def report(_record), do: nil

  def subject_label(%{subject_id: subject_id}), do: subject_id

  def launch_label(%{token_name: token_name, token_symbol: token_symbol}),
    do: "#{token_name} · #{token_symbol}"

  def launch_agent(%{agent_name: value}) when is_binary(value) and value != "", do: value
  def launch_agent(%{agent_id: value}), do: value

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

  def empty_market,
    do: %{generation: 0, head: nil, degraded?: false, robinhood_stale?: false, auctions: %{}}

  def page_record(%{ok?: true, result: %{record: record}}), do: record
  def page_record(_page), do: nil

  def page_status(%{ok?: true, result: %{status: status}}, _on_failed), do: status

  # A failed async carries its `{:error, reason}` or `{:exit, reason}` tag; it is never `true`.
  def page_status(%{failed: failed}, on_failed) when not is_nil(failed), do: on_failed
  def page_status(_page, _on_failed), do: :loading

  def page_connections(%{ok?: true, result: %{creator_connections: connections}}),
    do: connections

  def page_connections(_page), do: %{}

  def page_list(%{ok?: true, result: result}, key), do: Map.get(result, key, [])
  def page_list(_page, _key), do: []

  def load_auction_page(id), do: load_detail(id, &Autolaunch.get_public_auction/1)

  def load_token_page(id), do: load_detail(id, &Autolaunch.get_public_token/1)

  # An identifier that is not a UUID can never name a record, so it is missing rather
  # than unavailable; only a failed read of a well-formed identifier is an outage.
  defp load_detail(id, read) do
    with {:ok, uuid} <- Ash.Type.UUID.cast_input(id, []),
         {:ok, record} <- read.(uuid) do
      {:ok, %{page: if(record, do: ready_detail(record), else: empty_detail())}}
    else
      :error -> {:ok, %{page: empty_detail()}}
      {:error, _reason} -> {:error, :unavailable}
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

  defp creator_connections(record),
    do: connections_for(record, creator_connections_for(List.wrap(record)))

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
