defmodule AutolaunchWeb.Components.XConnections do
  @moduledoc """
  A creator's connected accounts as one list of like rows: each row is the
  account's picture or mark, its kind, the account itself (or "Optional · not
  connected"), and its buttons on the right. The two X rows come from here;
  other rows are passed in and drawn with `connection/1`.
  """
  use Phoenix.Component

  import AutolaunchWeb.Components.LinkIcon

  alias Autolaunch.Accounts.XOAuth

  attr :id, :string, required: true
  attr :connections, :list, default: []
  attr :enabled, :boolean, default: false
  slot :inner_block, doc: "more `connection/1` rows after the X ones"

  def x_connections(assigns) do
    assigns = assign(assigns, :by_role, Map.new(assigns.connections, &{&1.role, &1}))

    ~H"""
    <div id={@id} class="connections" phx-hook="XConnections" data-x-oauth-origin={XOAuth.origin()}>
      <p :if={!@enabled} class="connections__note">X accounts can't be added right now.</p>
      <ul class="connections__list">
        <.x_role
          :for={role <- [:profile, :company]}
          id={@id}
          role={role}
          connection={@by_role[role]}
          enabled={@enabled}
        />
        {render_slot(@inner_block)}
      </ul>
      <p data-x-connection-status role="status" aria-live="polite"></p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :icon, :atom, required: true, values: [:x, :github, :ens]
  attr :avatar, :string, default: nil
  attr :name, :string, default: nil, doc: "the account's name, or nil while not connected"
  attr :href, :string, default: nil
  attr :detail, :string, default: nil, doc: "a second line under the name, such as a handle"
  attr :rest, :global
  slot :actions
  slot :below, doc: "a full-width part under the row, such as a form"

  @doc "One connected account in the list's shared layout."
  def connection(assigns) do
    ~H"""
    <li class="connection" {@rest}>
      <span class="connection__mark">
        <img :if={@avatar} src={@avatar} alt="" width="40" height="40" />
        <.link_icon :if={!@avatar} kind={@icon} />
      </span>
      <span class="connection__text">
        <strong>{@label}</strong>
        <a :if={@name && @href} href={@href} target="_blank" rel="noreferrer">{@name}</a>
        <span :if={@name && !@href}>{@name}</span>
        <small :if={@name && @detail}>{@detail}</small>
        <small :if={!@name}>Optional · not connected</small>
      </span>
      <span class="connection__actions">{render_slot(@actions)}</span>
      {render_slot(@below)}
    </li>
    """
  end

  attr :id, :string, required: true
  attr :role, :atom, required: true
  attr :connection, :map, default: nil
  attr :enabled, :boolean, required: true

  defp x_role(assigns) do
    assigns = assign(assigns, :connected, connected(assigns.connection))

    ~H"""
    <.connection
      id={"#{@id}-#{@role}"}
      label={role_label(@role)}
      icon={:x}
      avatar={@connected && @connected.avatar_url}
      name={@connected && (@connected.display_name || "@#{@connected.username}")}
      href={@connected && "https://x.com/#{URI.encode_www_form(@connected.username)}"}
      detail={@connected && "@#{@connected.username}"}
      data-x-role={@role}
      data-x-intent-sequence={intent_sequence(@connection)}
    >
      <:actions>
        <Regent.Primitives.button
          :if={!@connected}
          type="button"
          data-x-connect-role={@role}
          disabled={!@enabled}
          variant="secondary"
        >
          Connect
        </Regent.Primitives.button>
        <Regent.Primitives.button
          :if={@connected}
          type="button"
          data-x-disconnect-role={@role}
          variant="secondary"
        >
          Disconnect
        </Regent.Primitives.button>
      </:actions>
    </.connection>
    """
  end

  defp connected(%{verified_at: %DateTime{}, username: username} = connection)
       when is_binary(username),
       do: connection

  defp connected(_connection), do: nil

  defp intent_sequence(%{intent_sequence: sequence}) when is_integer(sequence), do: sequence
  defp intent_sequence(_connection), do: 0
  defp role_label(:profile), do: "Profile X"
  defp role_label(:company), do: "Company X"
end
