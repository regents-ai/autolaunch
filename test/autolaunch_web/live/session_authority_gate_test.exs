defmodule AutolaunchWeb.Live.SessionAuthorityGateTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.System

  @wallet "0x1111111111111111111111111111111111111111"

  test "CANONICAL_AUTHORITY_ROW: the signed static token carries no credential", %{conn: conn} do
    account = account!()
    signed_in = init_test_session(conn, %{human_account_id: account.id})
    %{"session_lineage" => lineage, "live_socket_id" => cookie_topic} = get_session(signed_in)

    markup = html_response(get(signed_in, "/"), 200)

    # Phoenix.LiveView.Static signs this token with Phoenix.Token, which is
    # integrity-only: anyone holding the markup can read what it carries.
    assert %{session: session} = static_session!(markup)

    assert session == %{
             "render_topic" => SessionAuthority.topic(lineage),
             "render_route" => "/"
           }

    refute markup =~ lineage
    refute markup =~ Base.encode64(lineage)
    refute markup =~ Base.encode16(:crypto.hash(:sha256, lineage))

    for credential <- ["session_lineage", "session_generation", "live_socket_id"] do
      refute Map.has_key?(session, credential)
    end

    # The topic it does carry is the one the cookie already names publicly.
    assert session["render_topic"] == cookie_topic
  end

  test "CANONICAL_AUTHORITY_ROW: an anonymous render signs only its route" do
    assert %{session: %{"render_route" => "/"} = session} =
             build_conn() |> get("/") |> html_response(200) |> static_session!()

    assert Map.keys(session) == ["render_route"]
  end

  # A LiveView outside the product shell, so what this characterizes is the
  # pinned library's own merge and not this application's authority hook. It
  # reports through the pid the render session carries, because the merged map
  # only ever exists inside the mounted process.
  defmodule PinnedMergeLive do
    use Phoenix.LiveView

    def mount(_params, session, socket) do
      if connected?(socket),
        do: send(session["reply_to"], {:merged, session, get_connect_info(socket, :session)})

      {:ok, socket}
    end

    def render(assigns), do: ~H|<div id="pinned-merge"></div>|
  end

  test "HANDSHAKE_IS_CONNECTED_AUTHORITY: pinned LiveView hands mount the render's value for a colliding key",
       %{conn: conn} do
    render_session = %{"reply_to" => self(), "collision" => "render", "render_only" => "static"}
    handshake_session = %{"collision" => "handshake", "handshake_only" => "socket"}

    {:ok, _view, _html} =
      conn
      |> connects_with(handshake_session)
      |> live_isolated(PinnedMergeLive, session: render_session)

    assert_receive {:merged, mounted, handshake}

    # Phoenix LiveView 1.2.7 mounts with Map.merge(handshake, render): the
    # render's signed value wins every collision, so no handshake can put a
    # render_topic or render_route under the authority hook, and the hook can
    # never read the socket's own claim from this argument.
    assert mounted == %{
             "reply_to" => self(),
             "collision" => "render",
             "render_only" => "static",
             "handshake_only" => "socket"
           }

    # The connected authority the hook does read is the unmerged handshake.
    assert handshake == handshake_session
  end

  test "HANDSHAKE_IS_CONNECTED_AUTHORITY: a colliding handshake route cannot steer the realigning reload",
       %{conn: conn} do
    page = init_test_session(conn, %{human_account_id: account!().id})
    browser = init_test_session(build_conn(), %{human_account_id: account!().id})

    # The socket's own session names a different lineage and a decoy route.
    handshake = Map.put(get_session(browser), "render_route", "/settings")

    assert {:error, {:redirect, %{to: "/"}}} =
             page |> connects_with(handshake) |> live("/")
  end

  test "HANDSHAKE_IS_CONNECTED_AUTHORITY: an already-sent static render loses to the current handshake",
       %{conn: conn} do
    account = account!()
    signed_in = init_test_session(conn, %{human_account_id: account.id})

    # The dead render happens under the exact claim of its own moment.
    static = get(signed_in, "/")
    assert %{session: %{"render_topic" => _topic}} = static_session!(html_response(static, 200))

    # Two refreshes land before that already-sent page connects its socket.
    assert {:ok, :refresh, current} = SessionAuthority.sign_in(claim(signed_in), account.id)
    assert {:ok, :refresh, later} = SessionAuthority.sign_in(current, account.id)

    {:ok, view, _html} = static |> connects_with(SessionAuthority.session(later)) |> live()

    assert render(view) =~ "Autolaunch"
  end

  test "HANDSHAKE_IS_CONNECTED_AUTHORITY: an invalid handshake is refused onto the public root",
       %{
         conn: conn
       } do
    account = account!()
    signed_in = init_test_session(conn, %{human_account_id: account.id})
    current = get_session(signed_in)

    for handshake <- [
          # stale, ahead of the row, malformed topic, malformed shape, and the
          # handshake a page that named a lineage must never mount without.
          %{current | "session_generation" => current["session_generation"] - 1},
          %{current | "session_generation" => current["session_generation"] + 1},
          %{current | "live_socket_id" => SessionAuthority.topic(other_lineage())},
          Map.delete(current, "live_socket_id"),
          %{}
        ] do
      assert {:error, {:redirect, %{to: "/"}}} =
               signed_in |> connects_with(handshake) |> live("/")
    end

    static = get(signed_in, "/")
    assert SessionAuthority.revoke(claim(signed_in))

    assert {:error, {:redirect, %{to: "/"}}} = static |> connects_with(current) |> live()
  end

  test "HANDSHAKE_IS_CONNECTED_AUTHORITY: a claim-shaped handshake under an anonymous render is refused" do
    signed_in = init_test_session(build_conn(), %{human_account_id: account!().id})
    current = get_session(signed_in)
    assert SessionAuthority.revoke(claim(signed_in))

    # The render names no lineage, but the handshake still asserts one.
    anonymous = get(build_conn(), "/")
    assert %{session: session} = static_session!(html_response(anonymous, 200))
    refute Map.has_key?(session, "render_topic")

    assert {:error, {:redirect, %{to: "/"}}} = anonymous |> connects_with(current) |> live()

    assert {:error, {:redirect, %{to: "/"}}} =
             anonymous |> connects_with(%{"session_lineage" => "not-a-lineage"}) |> live()
  end

  test "HANDSHAKE_IS_CONNECTED_AUTHORITY: a current handshake under an anonymous render reloads the route",
       %{conn: conn} do
    browser = init_test_session(conn, %{human_account_id: account!().id})

    # The page was fetched without the cookie the socket then connects with.
    anonymous = get(build_conn(), "/")

    assert {:error, {:redirect, %{to: "/"}}} =
             anonymous |> connects_with(get_session(browser)) |> live()

    # The realigned request names that lineage, so the next mount accepts it.
    {:ok, view, _html} = live(browser, "/")
    assert render(view) =~ "Autolaunch"
  end

  test "HANDSHAKE_IS_CONNECTED_AUTHORITY: a handshake and render with no claim mount anonymous" do
    {:ok, view, _html} = live(build_conn(), "/")

    assert render(view) =~ "Autolaunch"
  end

  test "HANDSHAKE_IS_CONNECTED_AUTHORITY: a different current lineage reloads the same route once",
       %{conn: conn} do
    page = init_test_session(conn, %{human_account_id: account!().id})
    browser = init_test_session(build_conn(), %{human_account_id: account!().id})

    assert {:error, {:redirect, %{to: "/"}}} =
             page |> connects_with(get_session(browser)) |> live("/")

    # The reloaded page is signed for the browser's own lineage and mounts.
    {:ok, view, _html} = live(browser, "/")
    assert render(view) =~ "Autolaunch"
  end

  test "MOUNTED_LEASE_POLICY_C: a mounted socket survives drift and dies on revocation", %{
    conn: conn
  } do
    account = account!()
    signed_in = init_test_session(conn, %{human_account_id: account.id})

    {:ok, view, _html} = live(signed_in, "/")

    # A live navigation over the same transport revalidates under the drift.
    assert {:ok, :refresh, _drifted} = SessionAuthority.sign_in(claim(signed_in), account.id)
    assert render_patch(view, "/") =~ "Autolaunch"

    # The revoked lease halts navigation at the authority hook itself.
    assert SessionAuthority.revoke(claim(signed_in))
    assert {:error, {:redirect, %{to: "/"}}} = render_patch(view, "/")
  end

  test "MOUNTED_LEASE_POLICY_C: a mounted socket dies when the account's provider evidence lapses",
       %{conn: conn} do
    account = account!()
    signed_in = init_test_session(conn, %{human_account_id: account.id})

    {:ok, view, _html} = live(signed_in, "/")

    assert {:ok, _lapsed} = Accounts.refresh_verified(account, nil, [], actor: %System{})

    # The root renders for anonymous visitors, so only the authority hook can be
    # refusing this navigation.
    assert {:error, {:redirect, %{to: "/"}}} = render_patch(view, "/")
  end

  test "MOUNTED_LEASE_POLICY_C: an invalid claim exposes no private dead render", %{conn: conn} do
    account = account!()
    signed_in = init_test_session(conn, %{human_account_id: account.id})
    current = get_session(signed_in)

    assert %{session: %{"render_topic" => _topic}} =
             static_session!(html_response(get(signed_in, "/"), 200))

    for session <- [
          %{current | "session_generation" => current["session_generation"] - 1},
          %{current | "session_generation" => current["session_generation"] + 1},
          %{current | "live_socket_id" => SessionAuthority.topic(other_lineage())},
          Map.delete(current, "live_socket_id"),
          %{}
        ] do
      dead =
        build_conn()
        |> Phoenix.ConnTest.init_test_session(session)
        |> get("/")
        |> html_response(200)

      assert %{session: signed} = static_session!(dead)
      refute Map.has_key?(signed, "render_topic")
    end
  end

  test "STALE_LOGOUT_REVOKES: logout disconnects the socket and a reconnect cannot restore it", %{
    conn: conn
  } do
    account = account!()
    signed_in = init_test_session(conn, %{human_account_id: account.id})
    topic = get_session(signed_in, :live_socket_id)
    AutolaunchWeb.Endpoint.subscribe(topic)

    {:ok, view, _html} = live(signed_in, "/")
    assert Process.alive?(view.pid)

    deleted =
      build_conn()
      |> init_test_session(get_session(signed_in))
      |> put_valid_csrf()
      |> delete("/auth/privy/session")

    assert %{"ok" => true} = json_response(deleted, 200)
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}

    # The browser still holds the revoked claim, so its reconnect is refused
    # rather than quietly downgraded.
    assert {:error, {:redirect, %{to: "/"}}} = live(signed_in, "/")
  end

  defp account! do
    Accounts.register_verified!(
      "did:privy:session-gate:#{Elixir.System.unique_integer([:positive])}",
      @wallet,
      [@wallet],
      actor: %System{}
    )
  end

  defp claim(conn), do: conn |> get_session() |> SessionAuthority.claim()

  # Verifies the token exactly as Phoenix.LiveView.Static does: Phoenix.Token
  # over the endpoint's live_view signing salt, wrapping {token_vsn, data}.
  defp static_session!(markup) do
    [_match, token] = Regex.run(~r/data-phx-session="([^"]+)"/, markup)
    salt = AutolaunchWeb.Endpoint.config(:live_view)[:signing_salt]

    {:ok, {_version, data}} =
      Phoenix.Token.verify(AutolaunchWeb.Endpoint, salt, token, max_age: 1_209_600)

    data
  end

  defp other_lineage, do: SessionAuthority.bootstrap().lineage

  defp put_valid_csrf(conn) do
    token = Plug.CSRFProtection.get_csrf_token()

    conn
    |> Map.update!(:private, &Map.delete(&1, :plug_skip_csrf_protection))
    |> put_session("_csrf_token", Plug.CSRFProtection.dump_state())
    |> put_req_header("x-csrf-token", token)
  end
end
