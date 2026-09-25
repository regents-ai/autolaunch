defmodule AutolaunchWeb.CreatorConnectionsComponent do
  @moduledoc false
  use AutolaunchWeb, :live_component
  import AutolaunchWeb.Components.XConnections
  alias Autolaunch.Accounts
  alias Autolaunch.Actors.Human
  alias Phoenix.LiveView.JS

  def update(assigns, socket) do
    socket = assign_scope(socket, assigns)
    actor = %Human{human_account_id: assigns.current_human_id}

    x =
      case Accounts.list_my_x_connections(actor: actor) do
        {:ok, records} -> records
        _ -> []
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       identities: identities(actor),
       x_connections: x,
       x_enabled: Autolaunch.Accounts.XOAuth.enabled?()
     )
     |> assign_new(:notify, fn -> false end)
     |> assign_new(:optional, fn -> false end)
     |> assign_new(:notice, fn -> nil end)
     |> assign_new(:resolving, fn -> false end)
     |> assign_ens()}
  end

  @doc "The accounts other than X that a person has linked, by provider."
  def identities(actor) do
    case Accounts.list_my_linked_identities(actor: actor) do
      {:ok, records} -> Map.new(records, &{&1.provider, &1})
      _ -> %{}
    end
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

  defp assign_ens(socket) do
    identity = socket.assigns.identities[:ens]

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
    if socket.assigns.notify, do: send(self(), {:creator_connections, :changed})

    {:noreply,
     assign(socket,
       identities: identities(%Human{human_account_id: socket.assigns.current_human_id}),
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
    assigns = assign(assigns, :rows, row_assigns(assigns))

    ~H"""
    <section
      id={@id}
      class={[
        "creator-connections launchpad-form-section rg-panel rg-panel--surface",
        @optional && "creator-connections--optional"
      ]}
      phx-hook="CreatorConnections"
    >
      <header :if={!@optional}>
        <div>
          <p class="autolaunch-kicker">Start Here</p>
          <Regent.Structure.section_bar>
            <h2 class="rg-section-bar__label">Creator connections</h2>
          </Regent.Structure.section_bar>
        </div>
      </header>
      <p :if={!@optional}>
        Gain credibility by connecting reputation to your stablecoin / agent business
      </p>
      <Regent.Primitives.disclosure
        :if={@optional}
        id={"#{@id}-more"}
        summary="Socials (optional)"
        phx-mounted={JS.ignore_attributes(["open"])}
      >
        <p>These appear on your auction and token. You can launch without them.</p>
        <.rows id={@id} myself={@myself} {@rows} />
      </Regent.Primitives.disclosure>
      <.rows :if={!@optional} id={@id} myself={@myself} {@rows} />
      <p :if={@notice} role="status">{@notice}</p>
      <p data-creator-connection-status role="status"></p>
    </section>
    """
  end

  defp row_assigns(assigns) do
    assigns
    |> Map.take([:x_connections, :x_enabled, :ens_name, :ens_address, :resolving])
    |> Map.merge(%{github: assigns.identities[:github], ens: assigns.identities[:ens]})
  end

  defp rows(assigns) do
    ~H"""
    <.x_connections id={"#{@id}-x"} connections={@x_connections} enabled={@x_enabled}>
      <.connection
        label="GitHub"
        icon={:github}
        name={@github && @github.username}
        href={@github && "https://github.com/#{URI.encode_www_form(@github.username)}"}
      >
        <:actions>
          <Regent.Primitives.button
            :if={!@github}
            type="button"
            variant="secondary"
            data-connect-github
          >
            Connect
          </Regent.Primitives.button>
          <Regent.Primitives.button
            :if={@github}
            type="button"
            variant="secondary"
            data-disconnect-github
            data-github-subject={@github.subject}
          >
            Disconnect
          </Regent.Primitives.button>
        </:actions>
      </.connection>
      <.connection
        label="ENS"
        icon={:ens}
        name={@ens && @ens.username}
        href={@ens && "https://app.ens.domains/#{URI.encode_www_form(@ens.username)}"}
        detail={@ens && @ens_address && "Resolves to #{short_address(@ens_address)}"}
      >
        <:actions>
          <Regent.Primitives.button
            type="button"
            variant="secondary"
            aria-expanded="false"
            aria-controls={"#{@id}-ens-form"}
            phx-mounted={JS.ignore_attributes(["aria-expanded"])}
            phx-click={
              JS.toggle_attribute({"hidden", "hidden"}, to: "##{@id}-ens-form")
              |> JS.toggle_attribute({"aria-expanded", "true", "false"})
              |> JS.focus(to: "##{@id}-ens")
            }
          >
            {if @ens, do: "Change", else: "Connect"}
          </Regent.Primitives.button>
        </:actions>
        <:below>
          <form
            id={"#{@id}-ens-form"}
            phx-submit="connect_ens"
            phx-target={@myself}
            phx-mounted={JS.ignore_attributes(["hidden"])}
            class="connection__form rg-field"
            hidden
          >
            <label for={"#{@id}-ens"}>ENS name</label>
            <div class="connection__form-row">
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
              <Regent.Primitives.button type="submit" variant="secondary" disabled={@resolving}>
                {if @resolving, do: "Checking…", else: "Verify"}
              </Regent.Primitives.button>
            </div>
            <small>Use a name controlled by your signed-in wallet and resolving to it.</small>
          </form>
        </:below>
      </.connection>
    </.x_connections>
    """
  end

  defp short_address(<<"0x", _::binary-size(40)>> = address),
    do: "#{String.slice(address, 0, 6)}…#{String.slice(address, -4, 4)}"

  defp short_address(address), do: address
end
