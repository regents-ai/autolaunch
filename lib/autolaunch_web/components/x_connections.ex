defmodule AutolaunchWeb.Components.XConnections do
  @moduledoc false
  use Phoenix.Component

  alias Autolaunch.Accounts.XOAuth

  attr :id, :string, required: true
  attr :connections, :list, default: []
  attr :enabled, :boolean, default: false
  attr :compact, :boolean, default: false
  attr :class, :string, default: nil

  def x_connections(assigns) do
    assigns = assign(assigns, :by_role, Map.new(assigns.connections, &{&1.role, &1}))

    ~H"""
    <section
      id={@id}
      class={["x-connections", @compact && "x-connections--compact", @class]}
      phx-hook="XConnections"
      data-x-oauth-origin={XOAuth.origin()}
      aria-labelledby={"#{@id}-title"}
    >
      <header>
        <h2 id={"#{@id}-title"}>X accounts</h2>
        <p>
          Add an optional creator profile and company account. These appear with the launch;
          neither one controls the auction.
        </p>
      </header>

      <p :if={!@enabled} class="x-connections__disabled">
        X connections are not configured for this environment.
      </p>

      <ul>
        <.x_role
          :for={role <- [:profile, :company]}
          id={@id}
          role={role}
          connection={@by_role[role]}
          enabled={@enabled}
        />
      </ul>

      <p data-x-connection-status role="status" aria-live="polite"></p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :role, :atom, required: true
  attr :connection, :map, default: nil
  attr :enabled, :boolean, required: true

  defp x_role(assigns) do
    ~H"""
    <li
      id={"#{@id}-#{@role}"}
      data-x-role={@role}
      data-x-intent-sequence={intent_sequence(@connection)}
    >
      <div class="x-connections__identity">
        <img
          :if={connected?(@connection) && @connection.avatar_url}
          src={@connection.avatar_url}
          alt=""
          width="40"
          height="40"
        />
        <span>
          <strong>{role_label(@role)}</strong>
          <a
            :if={connected?(@connection)}
            href={"https://x.com/#{URI.encode_www_form(@connection.username)}"}
            target="_blank"
            rel="noreferrer"
          >
            {@connection.display_name || "@#{@connection.username}"}
            <small>@{@connection.username}</small>
          </a>
          <small :if={!connected?(@connection)}>Optional · not connected</small>
        </span>
      </div>

      <div class="x-connections__actions">
        <button type="button" data-x-connect-role={@role} disabled={!@enabled}>
          {if connected?(@connection), do: "Change", else: "Connect"}
        </button>
        <button
          :if={connected?(@connection)}
          type="button"
          class="x-connections__disconnect"
          data-x-disconnect-role={@role}
        >
          Disconnect
        </button>
      </div>
    </li>
    """
  end

  defp connected?(%{verified_at: %DateTime{}, username: username}) when is_binary(username),
    do: true

  defp connected?(_connection), do: false
  defp intent_sequence(%{intent_sequence: sequence}) when is_integer(sequence), do: sequence
  defp intent_sequence(_connection), do: 0
  defp role_label(:profile), do: "Profile X"
  defp role_label(:company), do: "Company X"
end
