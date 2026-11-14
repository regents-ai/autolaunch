defmodule AutolaunchWeb.Plugs.ProfileOwner do
  @moduledoc """
  Puts the profile's owner on a profile API request (`RegentIdentity.HTTP`).

  An agent's signed request acts as the person its pairing names, checked as on
  every signed route (`AutolaunchWeb.Plugs.AgentAccess`). Any other request is
  the person's own sign-in on this site: the session cookie its pages hold, and
  on a change the session's forms token in x-csrf-token, as the site's pages
  send it. A change without that token counts as signed out, so another site's
  page can never act with the person's cookie. A signed-out request gets no
  owner, and the profile API refuses it with `authentication_required`.
  """

  @behaviour Plug

  import Plug.Conn

  alias AutolaunchWeb.Plugs.AgentAccess
  alias AutolaunchWeb.PrivySessionController

  @forms_token Plug.CSRFProtection.init(with: :clear_session)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if Siwa.AgentAuthPlug.signed_request?(conn),
      do: agent(conn),
      else: person(conn)
  end

  defp agent(conn) do
    case AgentAccess.call(conn, []) do
      %{halted: true} = conn -> conn
      conn -> owner(conn, conn.assigns.actor.privy_user_id)
    end
  end

  defp person(conn) do
    conn =
      conn
      |> fetch_session()
      |> Plug.CSRFProtection.call(@forms_token)
      |> PrivySessionController.enforce_authority()

    case conn.assigns.current_human_account do
      %{privy_user_id: privy_user_id} -> owner(conn, privy_user_id)
      nil -> conn
    end
  end

  defp owner(conn, privy_user_id) do
    RegentIdentity.HTTP.put_owner(conn, %RegentIdentity.Owner{
      app_id: Autolaunch.Privy.app_id(),
      privy_user_id: privy_user_id
    })
  end
end
