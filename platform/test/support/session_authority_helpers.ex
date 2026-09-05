defmodule AutolaunchWeb.SessionAuthorityHelpers do
  @moduledoc """
  Mints the durable session authority every test connection carries.

  Shadowing `Phoenix.ConnTest.init_test_session/2` keeps the authority the only
  thing that decides what a session proves: a test names an account and gets the
  real bound claim for it, and no test hand-writes a session shape the gate would
  otherwise have to accept on trust.
  """

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.Human

  @doc "A test connection that reaches a connected mount the way a browser does."
  def build_conn, do: connects_with_own_cookie(Phoenix.ConnTest.build_conn())

  @doc """
  Puts `session` and the durable authority it names onto `conn`.

  A test still names the account it wants signed in, but the canonical cookie
  never carries one: the name is spent on a real bind and only the claim fields
  it produced reach the session.
  """
  def init_test_session(conn, session) do
    conn
    |> Phoenix.ConnTest.init_test_session(session |> Map.new(&stringify/1) |> claim())
    |> connects_with_own_cookie()
  end

  @doc "The claim fields a browser holds after `account_id` signs in on a fresh lineage."
  def signed_in_session(account_id) do
    {:ok, :bind, claim} = SessionAuthority.sign_in(SessionAuthority.bootstrap(), account_id)
    SessionAuthority.session(claim)
  end

  @doc """
  The mounted lease a connected socket for `account_id` proves.

  Every protected write runs inside this lease, so a test that
  drives those flows directly mints the same authority a connected mount would
  rather than writing without one.
  """
  def current_lease(account_id) do
    {:ok, :bind, claim} = SessionAuthority.sign_in(SessionAuthority.bootstrap(), account_id)
    %{lineage: claim.lineage, account_id: account_id}
  end

  @doc "Action options carrying the Human actor and that account's current lease."
  def leased(account_id),
    do: [
      actor: %Human{human_account_id: account_id},
      context: %{session_lease: current_lease(account_id)}
    ]

  # The websocket transport hands a connected mount a plain map of connect info,
  # while the test transport defaults to the whole `Plug.Conn`. The map shape lets
  # a mount read the cookie the socket connected with, exactly as a browser makes
  # it, instead of trusting the page's static session token.
  def connects_with_own_cookie(conn),
    do: Plug.Conn.put_private(conn, :live_view_connect_info, %{})

  @doc "Connects a socket with `session` while the page was signed for another one."
  def connects_with(conn, session),
    do:
      Plug.Conn.put_private(conn, :live_view_connect_info, %{
        session: Map.new(session, &stringify/1)
      })

  defp claim(%{"session_lineage" => _named} = session), do: session

  defp claim(%{"human_account_id" => account_id} = session) when is_integer(account_id) do
    session
    |> Map.delete("human_account_id")
    |> Map.merge(signed_in_session(account_id))
  end

  defp claim(session),
    do: Map.merge(session, SessionAuthority.session(SessionAuthority.bootstrap()))

  defp stringify({key, value}), do: {to_string(key), value}
end
