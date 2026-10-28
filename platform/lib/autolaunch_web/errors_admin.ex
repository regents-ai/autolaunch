defmodule AutolaunchWeb.ErrorsAdmin do
  @moduledoc """
  Keeps the saved errors at /admin/errors for Credits admins: a signed-in
  account the Credits `:admins` setting names (REGENT_CREDITS_ADMINS). Anyone
  else gets the site's ordinary not-found page, so the page's existence is not
  shown either.

  As a plug it checks the request and sends the page's own content security
  policy, with a nonce for the one script element the error dashboard writes
  into its page. As an `on_mount` hook it checks the socket the page connects
  with, then re-reads the sign-in on every navigation and press, so a sign-in
  that ends or lapses cannot keep acting on the page.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, get_connect_info: 2, redirect: 2]
  import Plug.Conn

  alias Autolaunch.Accounts.SessionAuthority
  alias AutolaunchWeb.ContentSecurityPolicy

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case conn |> get_session() |> admin() do
      nil ->
        raise Phoenix.Router.NoRouteError, conn: conn, router: AutolaunchWeb.Router

      _admin ->
        nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

        conn
        |> assign(:csp_nonce, nonce)
        |> put_resp_header("content-security-policy", ContentSecurityPolicy.errors(nonce))
    end
  end

  def on_mount(:default, _params, session, socket) do
    session = if connected?(socket), do: get_connect_info(socket, :session), else: session

    case admin(session) do
      nil ->
        {:halt, redirect(socket, to: "/")}

      {lineage, account} ->
        recheck = fn socket -> recheck(socket, lineage, account.id) end

        {:cont,
         socket
         |> attach_hook(:errors_admin_params, :handle_params, fn _params, _uri, socket ->
           recheck.(socket)
         end)
         |> attach_hook(:errors_admin_event, :handle_event, fn _event, _params, socket ->
           recheck.(socket)
         end)}
    end
  end

  defp admin(session) do
    case session |> SessionAuthority.claim() |> SessionAuthority.resolve() do
      {:ok, lineage, %{privy_user_id: id} = account} when is_binary(lineage) ->
        if admin_id?(id), do: {lineage, account}

      _signed_out ->
        nil
    end
  end

  defp recheck(socket, lineage, account_id) do
    case SessionAuthority.leased_account(lineage, account_id) do
      {:ok, %{privy_user_id: id}} -> if admin_id?(id), do: {:cont, socket}, else: leave(socket)
      _ended_or_unread -> leave(socket)
    end
  end

  defp leave(socket), do: {:halt, redirect(socket, to: "/")}

  defp admin_id?(id), do: id in Application.fetch_env!(:regent_credits, :admins)
end
