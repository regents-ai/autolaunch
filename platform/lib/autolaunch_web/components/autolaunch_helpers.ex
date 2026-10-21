defmodule AutolaunchWeb.Components.AutolaunchHelpers do
  @moduledoc false
  use AutolaunchWeb, :html

  alias Autolaunch.Accounts.XOAuth
  alias Autolaunch.Actors.Human
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Token
  alias Autolaunch.TreasurySecurity
  alias RegentChain.Address

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

  def record_label(:auction, record), do: record.title

  @doc "Whether a token's ticker only repeats its name, as SANDY's does, so the name is shown once."
  def same_name?(name, ticker), do: String.downcase(name) == String.downcase(ticker || "")

  def connections_for(%{creator_human_account_id: id}, grouped) when is_integer(id),
    do: Map.get(grouped, id, %{})

  def connections_for(%{auction: %{creator_human_account_id: id}}, grouped)
      when is_integer(id),
      do: Map.get(grouped, id, %{})

  def connections_for(_record, _grouped), do: %{}

  @doc "Whether a listed auction, or a listed token's auction, is on Robinhood."
  def robinhood?(%Token{auction: auction}), do: robinhood?(auction)
  def robinhood?(%{chain_id: chain_id}), do: RobinhoodLab.chain?(chain_id)

  def report(%{treasury_security_report: %Ash.NotLoaded{}}), do: nil
  def report(%{treasury_security_report: report}), do: report
  def report(_record), do: nil

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

  def display_action(value) do
    value
    |> display_text()
    |> String.replace("_", " ")
  end

  def display_time(%DateTime{} = value),
    do: Calendar.strftime(value, "%b %-d, %Y at %H:%M UTC")

  def display_time(_value), do: "Not available"

  def page_record(%{ok?: true, result: %{record: record}}), do: record
  def page_record(_page), do: nil

  def page_status(%{ok?: true, result: %{status: status}}, _on_failed), do: status

  # A failed async carries its `{:error, reason}` or `{:exit, reason}` tag; it is never `true`.
  def page_status(%{failed: failed}, on_failed) when not is_nil(failed), do: on_failed
  def page_status(_page, _on_failed), do: :loading

  def page_connections(%{ok?: true, result: %{creator_connections: connections}}),
    do: connections

  def page_connections(_page), do: %{}

  def load_auction_page(id), do: load_detail(id, &Autolaunch.get_public_auction/1)

  def load_token_page(id),
    do: load_detail(id, &Autolaunch.get_public_token(&1, load: [:market_cap]))

  # A record gone since its page address was read is missing; a failed read is
  # an outage.
  defp load_detail(id, read) do
    case read.(id) do
      {:ok, record} -> {:ok, %{page: if(record, do: ready_detail(record), else: empty_detail())}}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  def human_actor(%{principal: {:human, account}}),
    do: %Human{human_account_id: account.id}

  def human_actor(_access_context), do: nil

  @doc "The wallet the verified session signed in with, lowercase, or nil when signed out; its account's other wallets are never read."
  def signed_in_wallet(%{principal: {:human, %{wallet_address: wallet}}}) do
    {:ok, address} = Address.normalize(wallet)
    address
  end

  def signed_in_wallet(_access_context), do: nil

  def current_human_id(%{principal: {:human, %{id: id}}}), do: id
  def current_human_id(_access_context), do: nil

  defp ready_detail(record),
    do: %{status: :ready, record: record, creator_connections: creator_connections(record)}

  defp empty_detail, do: %{status: :empty, record: nil, creator_connections: %{}}

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
