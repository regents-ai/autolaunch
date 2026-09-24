defmodule AutolaunchWeb.CreatorConnectionsComponent do
  @moduledoc false
  use AutolaunchWeb, :live_component
  import AutolaunchWeb.Components.XConnections
  alias Autolaunch.Accounts
  alias Autolaunch.Actors.Human

  def update(assigns, socket) do
    socket = assign_scope(socket, assigns)

    actor = %Human{human_account_id: assigns.current_human_id}

    identities =
      case Accounts.list_my_linked_identities(actor: actor) do
        {:ok, records} -> Map.new(records, &{&1.provider, &1})
        _ -> %{}
      end

    x =
      case Accounts.list_my_x_connections(actor: actor) do
        {:ok, records} -> records
        _ -> []
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       identities: identities,
       x_connections: x,
       x_enabled: Autolaunch.Accounts.XOAuth.enabled?()
     )
     |> assign_new(:notice, fn -> nil end)
     |> assign_new(:resolving, fn -> false end)
     |> assign_ens(identities[:ens])}
  end

  defp assign_scope(socket, assigns) do
    scope = {assigns.current_human_id, assigns.session_lease && assigns.session_lease.lineage}

    if socket.assigns[:scope] == scope do
      socket
    else
      socket
      |> cancel_async(:connect_ens)
      |> assign(scope: scope, notice: nil, resolving: false, ens_name: "", ens_address: nil)
    end
  end

  defp assign_ens(socket, identity) do
    name =
      if socket.assigns.ens_name != "",
        do: socket.assigns.ens_name,
        else: (identity && identity.username) || ""

    address = socket.assigns.ens_address || (identity && identity.metadata["wallet"])
    assign(socket, ens_name: name, ens_address: address)
  end

  def handle_event("connect_ens", %{"name" => name}, socket) when is_binary(name) do
    opts = [
      actor: %Human{human_account_id: socket.assigns.current_human_id},
      context: %{session_lease: socket.assigns.session_lease}
    ]

    {:noreply,
     socket
     |> assign(resolving: true, notice: nil, ens_address: nil, ens_name: name)
     |> start_async(:connect_ens, fn -> Accounts.connect_ens(name, opts) end)}
  end

  def handle_async(:connect_ens, {:ok, {:ok, result}}, socket) do
    {:noreply,
     assign(socket,
       resolving: false,
       ens_name: result.name,
       ens_address: result.address,
       notice: "ENS connected. This name appears on your auctions and tokens."
     )}
  end

  def handle_async(:connect_ens, _error, socket) do
    {:noreply,
     assign(socket,
       resolving: false,
       notice:
         "Could not verify ENS. The name must be controlled by your signed-in wallet and resolve to it. Check it and try again."
     )}
  end

  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class="creator-connections rg-panel rg-panel--surface"
      phx-hook="CreatorConnections"
    >
      <header>
        <h2>Creator connections</h2><p>
          Optional. These appear on your auctions and graduated tokens.
        </p>
      </header>
      <.x_connections id={"#{@id}-x"} connections={@x_connections} enabled={@x_enabled} compact />
      <div class="creator-connections__github">
        <span><strong>GitHub</strong><span :if={@identities[:github]}> · {@identities.github.username}</span></span>
        <Regent.Primitives.button
          type="button"
          variant="secondary"
          data-connect-github
          disabled={not is_nil(@identities[:github])}
        >
          {if @identities[:github], do: "Connected", else: "Connect GitHub"}
        </Regent.Primitives.button>
      </div>
      <form phx-submit="connect_ens" phx-target={@myself} class="creator-connections__ens">
        <label for={"#{@id}-ens"}>ENS name</label>
        <input
          id={"#{@id}-ens"}
          name="name"
          type="text"
          value={@ens_name}
          maxlength="253"
          placeholder="yourname.eth"
          autocomplete="off"
          required
        />
        <p>Use a name controlled by your signed-in wallet and resolving to it.</p>
        <p :if={@ens_address} class="creator-connections__address">
          Resolves to <code>{@ens_address}</code>
        </p>
        <Regent.Primitives.button type="submit" variant="secondary" disabled={@resolving}>
          {if @resolving, do: "Checking ENS…", else: "Verify and connect ENS"}
        </Regent.Primitives.button>
      </form>
      <p :if={@notice} role="status">{@notice}</p>
      <p data-creator-connection-status role="status"></p>
    </section>
    """
  end
end
