defmodule AutolaunchWeb.Live.Session do
  @moduledoc false

  import Phoenix.LiveView,
    only: [attach_hook: 4, connected?: 1, get_connect_info: 2, redirect: 2]

  alias Autolaunch.AccessContext
  alias Autolaunch.Accounts.SessionAuthority
  alias AutolaunchWeb.Components.TopBar

  @public_root "/"

  @doc """
  What the render knew, signed into the static LiveView token.

  `Phoenix.LiveView.Static.sign_token/2` signs with `Phoenix.Token`, which is
  integrity-only and readable by anyone holding the markup, so this carries the
  lineage-stable topic rather than the lineage itself: a digest that names the
  browser session without being able to authenticate as it. The route travels
  with it because a connected mount cannot otherwise learn it — `connect_info`
  `:uri` is the transport's own `/live/websocket` address and `socket.host_uri`
  carries no path, so only `handle_params` sees the page route, and that is too
  late to refuse a mount.

  Phoenix LiveView 1.2.7 hands `mount/3` `Map.merge(handshake_session,
  static_token_session)`, so both keys are the render's own and can never stand
  in for the authority the socket connected with.
  """
  def render_context(conn) do
    conn.assigns.current_lineage
    |> rendered_topic()
    |> Map.put("render_route", local_route(conn.request_path, conn.query_string))
  end

  # The product shell needs a path and an account control on every LiveView,
  # including the public root, which stays outside :load_human so a refused
  # handshake can land there. :shell runs from the live_view macro first and
  # presents what the cookie already proves; :load_human then replaces that
  # control when the page is inside the product session.
  def on_mount(:shell, _params, session, socket) do
    {:cont,
     socket
     |> assign_shell_control(session)
     |> attach_hook(:shell_location, :handle_params, fn params, uri, socket ->
       {:cont,
        Phoenix.Component.assign(socket,
          current_path: path_of(uri),
          search_query: TopBar.normalize_query(params["q"])
        )}
     end)}
  end

  # The lease starts absent on every mount and is only ever granted by a
  # connected mount that proved its claim, so a disconnected render can read but
  # can never reach a protected write.
  def on_mount(:load_human, _params, session, socket) do
    socket = Phoenix.Component.assign(socket, :session_lease, nil)

    cond do
      Autolaunch.Prelaunch.read_only?() -> {:cont, assign_principal(socket, nil)}
      connected?(socket) -> connected(socket, session, get_connect_info(socket, :session))
      true -> {:cont, assign_principal(socket, disconnected_account(session))}
    end
  end

  # The cookie the socket connected with is the only authority, and a mount that
  # cannot honour it is refused there and then rather than left to a later hook.
  # An exactly current claim drives the socket when the page was rendered for its
  # lineage; when it was not, one full request for the same route realigns them.
  # Anything else — a claim-shaped handshake that will not parse, one the
  # authority refuses, or none at all under a page that named a lineage — lands
  # on the public root, which is outside the product shell and so cannot raise
  # the same rejection again.
  defp connected(socket, %{"render_topic" => rendered} = static, handshake),
    do: admit(socket, rendered, static["render_route"], SessionAuthority.claim(handshake))

  defp connected(socket, static, handshake) do
    if SessionAuthority.claim_shaped?(handshake),
      do: admit(socket, nil, static["render_route"], SessionAuthority.claim(handshake)),
      else: {:cont, assign_principal(socket, nil)}
  end

  defp admit(socket, _rendered, _route, nil), do: {:halt, redirect(socket, to: @public_root)}

  defp admit(socket, rendered, route, %{lineage: lineage, generation: generation} = claim) do
    with {^lineage, account} <- SessionAuthority.resolve(claim),
         ^rendered <- SessionAuthority.topic(lineage) do
      {:cont, hold(socket, lineage, generation, account)}
    else
      {nil, nil} -> {:halt, redirect(socket, to: @public_root)}
      _other_session -> {:halt, redirect(socket, to: route)}
    end
  end

  defp hold(socket, _lineage, _generation, nil), do: assign_principal(socket, nil)

  # The lease records the generation the mount proved, which later revalidation
  # deliberately does not re-require: a same-account refresh advances it beneath
  # a live socket. Lineage, account binding, revocation and the account's own
  # provider evidence are re-read every time, and the principal is rebuilt from
  # that read rather than from the struct the mount captured.
  defp hold(socket, lineage, generation, account) do
    lease = %{lineage: lineage, account_id: account.id, generation_at_mount: generation}

    socket
    |> assign_principal(account)
    |> Phoenix.Component.assign(:session_lease, lease)
    |> attach_hook(:session_authority_params, :handle_params, fn _params, _uri, socket ->
      case leased(lease) do
        nil -> {:halt, redirect(lapsed(socket), to: @public_root)}
        account -> {:cont, assign_principal(socket, account)}
      end
    end)
    |> attach_hook(:session_authority_event, :handle_event, fn _event, _params, socket ->
      case leased(lease) do
        nil -> {:halt, lapsed(socket)}
        account -> {:cont, assign_principal(socket, account)}
      end
    end)
  end

  # A lapsed lease is withdrawn along with the principal, so nothing downstream
  # can still present it as authority for a write.
  defp lapsed(socket),
    do: socket |> assign_principal(nil) |> Phoenix.Component.assign(:session_lease, nil)

  defp leased(%{lineage: lineage, account_id: account_id}),
    do: SessionAuthority.leased_account(lineage, account_id)

  defp rendered_topic(nil), do: %{}
  defp rendered_topic(lineage), do: %{"render_topic" => SessionAuthority.topic(lineage)}

  defp disconnected_account(session) do
    if Autolaunch.Prelaunch.read_only?() do
      nil
    else
      {_lineage, account} = session |> SessionAuthority.claim() |> SessionAuthority.resolve()
      account
    end
  end

  defp local_route(path, ""), do: path
  defp local_route(path, query), do: path <> "?" <> query

  defp assign_principal(socket, account) do
    access_context = access_context(account)

    Phoenix.Component.assign(socket,
      access_context: access_context,
      account_control: AccessContext.account_control(access_context)
    )
  end

  # Home is outside the product session, so this only presents what the cookie
  # can already prove. It never refuses a mount; :load_human still owns that.
  defp assign_shell_control(socket, session) do
    access_context = access_context(disconnected_account(session))

    Phoenix.Component.assign(socket,
      current_path: "/",
      search_query: "",
      account_control: AccessContext.account_control(access_context)
    )
  end

  defp path_of(uri) when is_binary(uri) do
    case URI.parse(uri).path do
      path when is_binary(path) and path != "" -> path
      _missing -> "/"
    end
  end

  defp access_context(nil), do: AccessContext.anonymous()
  defp access_context(account), do: AccessContext.human(account)
end
