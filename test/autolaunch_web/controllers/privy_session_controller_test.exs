defmodule AutolaunchWeb.PrivySessionControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.BootstrapRateLimiter
  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.System

  @canonical_session_keys [
    "_csrf_token",
    "live_socket_id",
    "session_generation",
    "session_lineage"
  ]

  @release_budget [limit: 30, window_seconds: 300]
  @limit @release_budget[:limit]
  @peer {203, 0, 113, 7}
  @other_peer {203, 0, 113, 8}
  @denial_event [:autolaunch, :session_bootstrap, :rate_limited]

  test "CANONICAL_AUTHORITY_ROW: a signed-in cookie carries a claim and never an account", %{
    conn: conn
  } do
    visitor = conn |> init_test_session(%{visitor: "discard-me"}) |> csrf_bootstrap()
    visitor_cookie = session_cookie(visitor)
    csrf = json_response(visitor, 200)["csrf_token"]

    signed_in =
      visitor
      |> recycled()
      |> enforce_csrf()
      |> put_privy_pair("valid")
      |> put_req_header("x-csrf-token", csrf)
      |> post("/auth/privy/session", %{
        privy_user_id: "did:privy:forged",
        wallet_address: "0x2222222222222222222222222222222222222222",
        display_name: "Forged",
        role: "admin"
      })

    payload = json_response(signed_in, 200)
    assert payload["authenticated"] == true
    assert Map.keys(payload) |> Enum.sort() == ["account_control", "authenticated"]

    assert Map.keys(payload["account_control"]) |> Enum.sort() ==
             ["avatar_data_uri", "kind", "label", "profile_path", "settings_path"]

    refute Map.has_key?(payload["account_control"], "wallet_address")
    assert get_resp_header(signed_in, "x-autolaunch-session-changed") == ["true"]
    assert payload["account_control"]["profile_path"] == nil
    assert payload["account_control"]["avatar_data_uri"] =~ "data:image/svg+xml;base64,"

    assert signed_in.private[:plug_session_info] == :renew
    assert session_cookie(signed_in) != visitor_cookie

    assert get_session(signed_in) |> Map.keys() |> Enum.sort() == @canonical_session_keys
    refute get_session(signed_in, :human_account_id)

    assert get_session(signed_in, :session_lineage) == get_session(visitor, :session_lineage)
    assert get_session(signed_in, :session_generation) == 1

    assert get_session(signed_in, :live_socket_id) ==
             SessionAuthority.topic(get_session(signed_in, :session_lineage))

    assert {:ok, account} = Accounts.get_by_privy_did("did:privy:verified", actor: %System{})
    assert account.wallet_address == "0x1111111111111111111111111111111111111111"
    assert account.display_name == nil
  end

  test "EXACT_CSRF_MATRIX: a cookie-less request bootstraps and an exact claim only observes" do
    bootstrapped = csrf_bootstrap(build_conn())

    assert %{"csrf_token" => token} = json_response(bootstrapped, 200)
    assert String.length(token) > 0
    assert bootstrapped.private[:plug_session_info] == :renew
    assert get_session(bootstrapped) |> Map.keys() |> Enum.sort() == @canonical_session_keys
    lineage = get_session(bootstrapped, :session_lineage)
    assert get_session(bootstrapped, :session_generation) == 0
    assert SessionAuthority.exact(claim(bootstrapped)) == {:ok, nil}

    observed = bootstrapped |> recycled() |> csrf_bootstrap()

    assert json_response(observed, 200)["csrf_token"]
    assert get_session(observed, :session_lineage) == lineage
    assert get_session(observed, :session_generation) == 0
    refute observed.private[:plug_session_info]
    refute session_cookie(observed)
  end

  test "EXACT_CSRF_MATRIX: an exact bound claim is observed without touching the cookie" do
    {browser, signed_in} = signed_in_browser()
    {:ok, account_id} = SessionAuthority.exact(claim(signed_in))

    observed = csrf_bootstrap(browser)

    assert json_response(observed, 200)["csrf_token"]
    refute observed.private[:plug_session_info]
    refute session_cookie(observed)
    assert get_session(observed) == get_session(signed_in)
    assert SessionAuthority.exact(claim(signed_in)) == {:ok, account_id}
  end

  test "EXACT_CSRF_MATRIX: a held exact response cannot put an older generation back" do
    {browser, signed_in} = signed_in_browser()
    {:ok, account_id} = SessionAuthority.exact(claim(signed_in))

    # Computed while the claim is still exact, then held in flight.
    held = csrf_bootstrap(browser)
    assert json_response(held, 200)["csrf_token"]

    # Another tab wins the lineage and hands this browser its only new cookie.
    assert {:ok, :refresh, winner} = SessionAuthority.sign_in(claim(signed_in), account_id)

    # Delivered late, the held response carries nothing to apply over the winner.
    refute session_cookie(held)
    assert SessionAuthority.exact(winner) == {:ok, account_id}
    assert SessionAuthority.exact(claim(signed_in)) == {:error, :superseded}
  end

  test "EXACT_CSRF_MATRIX: a superseded claim is refused without touching the cookie" do
    {browser, signed_in} = signed_in_browser()
    {:ok, account_id} = SessionAuthority.exact(claim(signed_in))

    # Another tab refreshes the same lineage, stranding this browser's cookie.
    assert {:ok, :refresh, current} = SessionAuthority.sign_in(claim(signed_in), account_id)

    refused = csrf_bootstrap(browser)

    assert json_response(refused, 409) == %{"error" => "session_superseded"}
    refute session_cookie(refused)
    assert SessionAuthority.exact(current) == {:ok, account_id}
  end

  test "EXACT_CSRF_MATRIX: a revoked claim drops the cookie and only a later request mints" do
    {browser, signed_in} = signed_in_browser()
    assert SessionAuthority.revoke(claim(signed_in))

    refused = csrf_bootstrap(browser)

    assert json_response(refused, 409) == %{"error" => "session_reset_required"}
    assert refused.private[:plug_session_info] == :drop

    minted = csrf_bootstrap(build_conn())

    assert json_response(minted, 200)["csrf_token"]
    refute get_session(minted, :session_lineage) == get_session(signed_in, :session_lineage)
  end

  test "BUDGET_BEFORE_INSERT: the budget commits its lineages and the request past it commits none" do
    release_budget()
    before = authority_count()

    admitted = for _ <- 1..@limit, do: bootstrap_from(@peer)

    assert Enum.all?(admitted, &json_response(&1, 200)["csrf_token"])

    assert admitted |> Enum.map(&get_session(&1, :session_lineage)) |> Enum.uniq() |> length() ==
             @limit

    assert Enum.all?(admitted, &(SessionAuthority.exact(claim(&1)) == {:ok, nil}))
    assert authority_count() - before == @limit

    denied = bootstrap_from(@peer)

    assert json_response(denied, 429) == %{"error" => "rate_limited"}
    assert get_resp_header(denied, "retry-after") == ["300"]
    assert get_resp_header(denied, "cache-control") == ["no-store"]
    refute session_cookie(denied)
    assert authority_count() - before == @limit
  end

  test "BUDGET_BEFORE_INSERT: concurrent cookie-less requests commit exactly the budget" do
    release_budget()
    before = authority_count()

    statuses =
      1..(2 * @limit)
      |> Task.async_stream(fn _ -> bootstrap_from(@peer).status end, ordered: false)
      |> Enum.map(fn {:ok, status} -> status end)

    assert Enum.frequencies(statuses) == %{200 => @limit, 429 => @limit}
    assert authority_count() - before == @limit
  end

  test "REAL_CLIENT_KEY: distinct normalized client addresses hold independent budgets" do
    release_budget()
    before = authority_count()

    assert exhaust(fn -> bootstrap_from(@peer) end).status == 429
    assert bootstrap_from(@other_peer) |> json_response(200) |> Map.has_key?("csrf_token")
    assert authority_count() - before == @limit + 1
  end

  test "CURRENT_CLAIMS_ARE_OBSERVATIONAL: an exact claim is observed through an exhausted bucket" do
    release_budget()
    admitted = for _ <- 1..@limit, do: bootstrap_from(@peer)
    assert bootstrap_from(@peer).status == 429

    before = authority_count()
    browser = %{recycled(List.first(admitted)) | remote_ip: @peer}
    observed = csrf_bootstrap(browser)

    assert json_response(observed, 200)["csrf_token"]
    refute observed.private[:plug_session_info]
    refute session_cookie(observed)
    assert authority_count() == before
  end

  test "REAL_CLIENT_KEY: only one syntactically valid Fly address escapes the peer bucket" do
    release_budget()
    assert exhaust(fn -> bootstrap_from(@peer) end).status == 429

    assert bootstrap_from(@peer, [{"fly-client-ip", "not-an-ip"}]).status == 429
    assert bootstrap_from(@peer, [{"fly-client-ip", "203.0.113.9:80"}]).status == 429

    assert bootstrap_from(@peer, [
             {"fly-client-ip", "198.51.100.1"},
             {"fly-client-ip", "198.51.100.2"}
           ]).status == 429

    # The proxy sets `Fly-Client-IP` itself; `X-Forwarded-For` is a client-supplied
    # header and buys nobody a budget of their own.
    assert bootstrap_from(@peer, [{"x-forwarded-for", "198.51.100.3"}]).status == 429
    assert bootstrap_from(@peer, [{"fly-client-ip", "198.51.100.1"}]).status == 200
  end

  test "REAL_CLIENT_KEY: the IPv6 spellings of one IPv4 address share its bucket" do
    release_budget()
    spellings = ["198.51.100.4", "::ffff:198.51.100.4", "::198.51.100.4"]

    admitted =
      spellings
      |> Stream.cycle()
      |> Enum.take(@limit)
      |> Enum.map(&bootstrap_from(@peer, [{"fly-client-ip", &1}]))

    assert Enum.all?(admitted, &(&1.status == 200))

    for spelling <- spellings do
      assert bootstrap_from(@peer, [{"fly-client-ip", spelling}]).status == 429
    end
  end

  test "REAL_CLIENT_KEY: genuine IPv6 clients share one budget per /64" do
    release_budget()

    admitted =
      for host <- 1..@limit,
          do: bootstrap_from(@peer, [{"fly-client-ip", "2001:db8:1:2::#{host}"}])

    assert Enum.all?(admitted, &(&1.status == 200))
    assert bootstrap_from(@peer, [{"fly-client-ip", "2001:db8:1:2:ffff::1"}]).status == 429
    assert bootstrap_from(@peer, [{"fly-client-ip", "2001:db8:1:3::1"}]).status == 200
  end

  test "STABLE_DENIAL: a denial counts once and names only where the client key came from" do
    release_budget()
    handler = attach_denial_telemetry()
    on_exit(fn -> :telemetry.detach(handler) end)

    assert exhaust(fn -> bootstrap_from(@peer) end).status == 429
    assert_receive {:denial, %{count: 1}, peer_metadata}
    assert peer_metadata == %{source: :peer_fallback}

    header = [{"fly-client-ip", "198.51.100.6"}]
    assert exhaust(fn -> bootstrap_from(@peer, header) end).status == 429
    assert_receive {:denial, %{count: 1}, header_metadata}
    assert header_metadata == %{source: :client_header}
  end

  test "FIRST_BIND_AND_REFRESH_ROTATE: a same-account refresh advances, renews and keeps the socket",
       %{conn: conn} do
    signed_in =
      conn
      |> init_test_session(%{})
      |> put_valid_csrf()
      |> put_privy_pair("valid")
      |> post("/auth/privy/session", %{})

    assert %{"authenticated" => true} = json_response(signed_in, 200)
    topic = get_session(signed_in, :live_socket_id)
    lineage = get_session(signed_in, :session_lineage)
    AutolaunchWeb.Endpoint.subscribe(topic)

    {:ok, view, _html} =
      build_conn() |> init_test_session(get_session(signed_in)) |> live("/portfolio")

    assert Process.alive?(view.pid)

    refreshed =
      build_conn()
      |> init_test_session(get_session(signed_in))
      |> put_valid_csrf()
      |> put_privy_pair("valid")
      |> post("/auth/privy/session", %{})

    assert %{"authenticated" => true} = json_response(refreshed, 200)
    assert get_resp_header(refreshed, "x-autolaunch-session-changed") == ["false"]
    assert get_session(refreshed, :session_lineage) == lineage

    assert get_session(refreshed, :session_generation) ==
             get_session(signed_in, :session_generation) + 1

    assert get_session(refreshed, :live_socket_id) == topic
    assert refreshed.private[:plug_session_info] == :renew
    assert session_cookie(refreshed) != session_cookie(signed_in)

    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    assert Process.alive?(view.pid)

    # The socket's next event revalidates under the advanced generation and
    # keeps the principal the mount proved.
    render_click(view, "refresh")
    assert has_element?(view, "#account-control[data-account-kind=signed_in]")
  end

  test "ORDINARY_SIGNED_IN_STARTUP_IS_STABLE: reads and mounts change no authority" do
    {browser, signed_in} = signed_in_browser()
    {:ok, account_id} = SessionAuthority.exact(claim(signed_in))
    topic = get_session(signed_in, :live_socket_id)
    AutolaunchWeb.Endpoint.subscribe(topic)

    for read <- [&get(&1, "/portfolio"), &get(&1, "/auth/session"), &get(&1, "/auth/csrf")] do
      refute browser |> recycled() |> read.() |> session_cookie()
    end

    {:ok, view, _html} = browser |> recycled() |> live("/portfolio")
    assert Process.alive?(view.pid)

    # Remaining signed in is not a session event: the generation this browser
    # already holds is still the current one.
    assert SessionAuthority.exact(claim(signed_in)) == {:ok, account_id}
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
  end

  test "FIRST_BIND_AND_REFRESH_ROTATE: a superseded sign-in is refused and emits no cookie" do
    {browser, signed_in} = signed_in_browser()
    {:ok, account_id} = SessionAuthority.exact(claim(signed_in))
    {browser, csrf} = refreshed_csrf(browser)

    # The winning tab advances the row while this request is still in flight.
    assert {:ok, :refresh, current} = SessionAuthority.sign_in(claim(signed_in), account_id)

    loser =
      browser
      |> enforce_csrf()
      |> put_privy_pair("valid")
      |> put_req_header("x-csrf-token", csrf)
      |> post("/auth/privy/session", %{})

    assert json_response(loser, 409) == %{"error" => "session_superseded"}
    refute session_cookie(loser)
    assert SessionAuthority.exact(current) == {:ok, account_id}
  end

  test "TWO_STEP_ACCOUNT_SWITCH: a different account revokes, drops and disconnects first", %{
    conn: conn
  } do
    signed_in =
      conn
      |> init_test_session(%{})
      |> put_valid_csrf()
      |> put_privy_pair("valid")
      |> post("/auth/privy/session", %{})

    topic = get_session(signed_in, :live_socket_id)
    AutolaunchWeb.Endpoint.subscribe(topic)
    flush_test_messages()

    switched =
      build_conn()
      |> init_test_session(get_session(signed_in))
      |> put_valid_csrf()
      |> put_privy_pair("other-account")
      |> post("/auth/privy/session", %{})

    assert_response_sent_then_disconnect(topic)
    assert json_response(switched, 409) == %{"error" => "account_switch_required"}
    assert switched.private[:plug_session_info] == :drop
    assert SessionAuthority.exact(claim(signed_in)) == {:error, :reset}

    rebound =
      build_conn()
      |> init_test_session(%{})
      |> delete_session(:session_lineage)
      |> csrf_bootstrap()
      |> recycled()
      |> put_privy_pair("other-account")
      |> put_req_header("x-csrf-token", Plug.CSRFProtection.get_csrf_token())
      |> post("/auth/privy/session", %{})

    assert %{"authenticated" => true} = json_response(rebound, 200)
    assert get_resp_header(rebound, "x-autolaunch-session-changed") == ["true"]
    refute get_session(rebound, :session_lineage) == get_session(signed_in, :session_lineage)
  end

  test "STALE_LOGOUT_REVOKES: logout revokes a superseded claim, drops, then disconnects", %{
    conn: conn
  } do
    account = account!("logout")
    signed_in = init_test_session(conn, %{human_account_id: account.id})
    held = get_session(signed_in)
    topic = get_session(signed_in, :live_socket_id)

    assert {:ok, :refresh, _advanced} = SessionAuthority.sign_in(claim(signed_in), account.id)
    AutolaunchWeb.Endpoint.subscribe(topic)
    flush_test_messages()

    deleted =
      build_conn() |> init_test_session(held) |> put_valid_csrf() |> delete("/auth/privy/session")

    assert_response_sent_then_disconnect(topic)
    assert %{"ok" => true} = json_response(deleted, 200)
    assert deleted.private[:plug_session_info] == :drop
    assert SessionAuthority.exact(claim(signed_in)) == {:error, :reset}

    repeated =
      build_conn() |> init_test_session(held) |> put_valid_csrf() |> delete("/auth/privy/session")

    assert %{"ok" => true} = json_response(repeated, 200)
  end

  test "STALE_LOGOUT_REVOKES: logout without a claim still answers and drops", %{conn: conn} do
    deleted =
      conn
      |> init_test_session(%{})
      |> delete_session(:session_lineage)
      |> put_valid_csrf()
      |> delete("/auth/privy/session")

    assert %{"ok" => true} = json_response(deleted, 200)
    assert deleted.private[:plug_session_info] == :drop
  end

  test "CENTRAL_CURRENT_ACTOR: inspection follows the row, not the request", %{conn: conn} do
    account = account!("inspection")

    assert %{"authenticated" => false} =
             conn
             |> put_privy_pair("valid")
             |> get("/auth/session")
             |> json_response(200)

    signed_in = init_test_session(conn, %{human_account_id: account.id})
    assert %{"authenticated" => true} = signed_in |> get("/auth/session") |> json_response(200)

    superseded =
      build_conn() |> init_test_session(put_in(get_session(signed_in), ["session_generation"], 0))

    assert %{"authenticated" => false} = superseded |> get("/auth/session") |> json_response(200)

    assert SessionAuthority.revoke(claim(signed_in))

    revoked = build_conn() |> init_test_session(get_session(signed_in))
    assert %{"authenticated" => false} = revoked |> get("/auth/session") |> json_response(200)
  end

  @identity Autolaunch.TestPrivyVerifier.identity_token("valid")

  # The one rendered diagnostic line; this repository's development formatter
  # drops metadata, so the whole classification lives in the message.
  @classification ~r/Privy session rejected [^\n]+/

  test "COMPLETE_PAIR_REQUIRED: a half, blank, duplicated or unverifiable pair is refused before a write",
       %{conn: conn} do
    assert {:ok, before_attempts} =
             Accounts.get_by_privy_did("did:privy:verified", actor: %System{})

    headers = [
      # Neither token alone is a pair, and neither may be blank.
      [],
      [{"authorization", "Bearer valid"}],
      [{"privy-id-token", @identity}],
      [{"authorization", "Bearer  "}, {"privy-id-token", @identity}],
      [{"authorization", "Bearer valid"}, {"privy-id-token", "  "}],
      # A second identity header is a client choosing which evidence counts.
      [
        {"authorization", "Bearer valid"},
        {"privy-id-token", @identity},
        {"privy-id-token", @identity}
      ],
      # Role confusion in either slot, and the same token reused in both.
      [{"authorization", "Bearer #{@identity}"}, {"privy-id-token", "valid"}],
      [{"authorization", "Bearer valid"}, {"privy-id-token", "valid"}],
      [{"authorization", "Bearer #{@identity}"}, {"privy-id-token", @identity}],
      # Evidence signed for a different session is evidence for no session here.
      [
        {"authorization", "Bearer valid"},
        {"privy-id-token", Autolaunch.TestPrivyVerifier.identity_token("other-account")}
      ],
      # Neither token verifies at all.
      [
        {"authorization", "Bearer invalid"},
        {"privy-id-token", Autolaunch.TestPrivyVerifier.identity_token("invalid")}
      ]
    ]

    for pair <- headers do
      refused =
        conn
        |> init_test_session(%{})
        |> put_valid_csrf()
        |> put_headers(pair)
        |> post("/auth/privy/session", %{})

      assert json_response(refused, 401) == %{"error" => "unauthorized"}
      assert_no_token_disclosure(refused)
    end

    assert {:ok, after_attempts} =
             Accounts.get_by_privy_did("did:privy:verified", actor: %System{})

    assert account_evidence(after_attempts) == account_evidence(before_attempts)
  end

  test "SIGNED_EVIDENCE_ONLY: an accepted pair is not disclosed on the response", %{conn: conn} do
    signed_in =
      conn
      |> init_test_session(%{})
      |> put_valid_csrf()
      |> put_privy_pair("valid")
      |> post("/auth/privy/session", %{})

    assert %{"authenticated" => true} = json_response(signed_in, 200)
    assert_no_token_disclosure(signed_in)
  end

  test "REDACTED_CLASSIFICATION: the controller names the two stages it owns itself" do
    debug_logging()

    assert classification(put_headers(browser(), [{"privy-id-token", @identity}])) ==
             "Privy session rejected stage=request_pair reason=missing_access_token"

    assert classification(put_headers(browser(), [{"authorization", "Bearer valid"}])) ==
             "Privy session rejected stage=request_pair reason=missing_identity_token"

    # Lapsed wallet evidence is the account boundary's own outcome, not a
    # verification failure, and keeps its own name.
    assert classification(put_privy_pair(browser(), "no-wallet")) ==
             "Privy session rejected stage=account_evidence reason=missing_linked_wallet"
  end

  test "REDACTED_CLASSIFICATION: the two access-verification reasons keep their own names" do
    debug_logging()

    assert classification(put_privy_pair(browser(), "stale-access")) ==
             "Privy session rejected stage=access_verification reason=token_verification_failed"

    assert classification(put_privy_pair(browser(), "unverifiable")) ==
             "Privy session rejected stage=access_verification reason=invalid_token"
  end

  test "ONE_MARKED_REFUSAL: only an unverifiable access token invites a fresh provider login" do
    marked =
      browser() |> put_privy_pair("stale-access") |> post("/auth/privy/session", %{})

    assert get_resp_header(marked, "x-autolaunch-provider-relogin") == ["allowed"]

    # Every other way this endpoint refuses, across all three of its stages.
    unmarked = [
      put_headers(browser(), [{"authorization", "Bearer valid"}]),
      put_headers(browser(), [{"privy-id-token", @identity}]),
      put_headers(browser(), [
        {"authorization", "Bearer valid"},
        {"privy-id-token", Autolaunch.TestPrivyVerifier.identity_token("other-account")}
      ]),
      put_privy_pair(browser(), "unverifiable"),
      put_privy_pair(browser(), "no-wallet")
    ]

    for refused <- unmarked do
      refused = post(refused, "/auth/privy/session", %{})

      assert get_resp_header(refused, "x-autolaunch-provider-relogin") == []
      assert json_response(refused, 401) == json_response(marked, 401)
      assert refused.private[:plug_session_info] == marked.private[:plug_session_info]
    end
  end

  test "ONE_MARKED_REFUSAL: the marked refusal still revokes, drops and disconnects" do
    {browser, signed_in} = signed_in_browser()
    {:ok, account_id} = SessionAuthority.exact(claim(signed_in))
    topic = get_session(signed_in, :live_socket_id)
    AutolaunchWeb.Endpoint.subscribe(topic)
    {browser, csrf} = refreshed_csrf(browser)
    flush_test_messages()

    marked =
      browser
      |> enforce_csrf()
      |> put_privy_pair("stale-access")
      |> put_req_header("x-csrf-token", csrf)
      |> post("/auth/privy/session", %{})

    assert_response_sent_then_disconnect(topic)
    assert json_response(marked, 401) == %{"error" => "unauthorized"}
    assert get_resp_header(marked, "x-autolaunch-provider-relogin") == ["allowed"]
    assert marked.private[:plug_session_info] == :drop
    assert_no_token_disclosure(marked)

    assert SessionAuthority.exact(claim(signed_in)) == {:error, :reset}
    assert SessionAuthority.sign_in(claim(signed_in), account_id) == {:error, :reset}
  end

  test "REDACTED_CLASSIFICATION: the classification repeats neither token" do
    debug_logging()
    log = refusal_log(put_privy_pair(browser(), "unverifiable"))

    assert Regex.run(@classification, log) ==
             ["Privy session rejected stage=access_verification reason=invalid_token"]

    refute log =~ "unverifiable"
  end

  # Raises the primary Logger level for one case, because this repository logs at
  # warning under test and the diagnostic is deliberately debug-level. Every case
  # in this synchronous file runs alone, so nothing else observes the change.
  defp debug_logging do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  defp classification(browser) do
    assert [classification] = Regex.run(@classification, refusal_log(browser))
    classification
  end

  defp refusal_log(browser) do
    capture_log(fn ->
      assert browser |> post("/auth/privy/session", %{}) |> json_response(401) ==
               %{"error" => "unauthorized"}
    end)
  end

  defp browser, do: build_conn() |> init_test_session(%{}) |> put_valid_csrf()

  defp put_privy_pair(conn, access_token) do
    conn
    |> put_req_header("authorization", "Bearer #{access_token}")
    |> put_req_header(
      "privy-id-token",
      Autolaunch.TestPrivyVerifier.identity_token(access_token)
    )
  end

  # Carries the headers exactly as given, so a duplicated one travels the way a
  # client would actually send it.
  defp put_headers(conn, headers), do: %{conn | req_headers: conn.req_headers ++ headers}

  # Neither token may come back as a token on anything the page or a log can
  # read. The match is bounded so an unrelated word that merely spells one of
  # them inside itself, such as `must-revalidate`, is not read as a disclosure.
  # The session cookie is opaque ciphertext carrying no request header, and its
  # contents are pinned by `CANONICAL_AUTHORITY_ROW`.
  defp assert_no_token_disclosure(conn) do
    observable =
      conn.resp_headers
      |> Enum.reject(fn {name, _value} -> name == "set-cookie" end)
      |> Enum.map_join("\n", fn {name, value} -> "#{name}: #{value}" end)

    for surface <- [observable, conn.resp_body], secret <- ["valid", @identity] do
      refute surface =~ ~r/\b#{Regex.escape(secret)}\b/
    end
  end

  test "verified registration is idempotent under concurrent attempts" do
    verified = %Autolaunch.VerifiedPrivyIdentity{
      privy_user_id: "did:privy:concurrent",
      session_id: "concurrent-session",
      wallet_address: "0x3333333333333333333333333333333333333333",
      wallet_addresses: ["0x3333333333333333333333333333333333333333"]
    }

    results =
      1..2
      |> Task.async_stream(fn _ -> Autolaunch.Accounts.VerifiedSession.establish(verified) end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _, []}}, &1))
    assert {:ok, account} = Accounts.get_by_privy_did("did:privy:concurrent", actor: %System{})
    assert account.wallet_address == verified.wallet_address
  end

  test "an upsert conflict without linked accounts cannot erase wallet evidence" do
    actor = %System{}
    wallet = "0x4444444444444444444444444444444444444444"

    assert {:ok, _account} =
             Accounts.register_verified("did:privy:wallet-race", wallet, [wallet], actor: actor)

    assert {:ok, _account} =
             Accounts.register_verified("did:privy:wallet-race", nil, [], actor: actor)

    assert {:ok, account} = Accounts.get_by_privy_did("did:privy:wallet-race", actor: actor)

    assert account.wallet_address == wallet
    assert account.wallet_addresses == [wallet]
  end

  test "CSRF is required for both session creation and deletion", %{conn: conn} do
    assert_error_sent 403, fn ->
      conn
      |> init_test_session(%{})
      |> enforce_csrf()
      |> put_privy_pair("valid")
      |> post("/auth/privy/session", %{})
    end

    assert_error_sent 403, fn ->
      conn
      |> init_test_session(%{})
      |> enforce_csrf()
      |> delete("/auth/privy/session")
    end
  end

  test "SIWA headers cannot enter the browser-human rail", %{conn: conn} do
    response =
      conn
      |> init_test_session(%{})
      |> put_valid_csrf()
      |> put_req_header("x-regent-siwa-receipt", "signed-agent-receipt")
      |> post("/auth/privy/session", %{})

    assert %{"error" => "unauthorized"} = json_response(response, 401)
  end

  test "session cookies are HTTP-only locally and secure under production options", %{conn: conn} do
    original = Application.fetch_env!(:autolaunch, :session_options)
    on_exit(fn -> Application.put_env(:autolaunch, :session_options, original) end)

    local_cookie = conn |> init_test_session(%{}) |> csrf_bootstrap() |> session_cookie()
    assert local_cookie =~ "; HttpOnly"
    refute String.downcase(local_cookie) =~ "; secure"

    Application.put_env(
      :autolaunch,
      :session_options,
      Keyword.merge(original, secure: true, http_only: true)
    )

    secure_cookie = build_conn() |> init_test_session(%{}) |> csrf_bootstrap() |> session_cookie()
    assert secure_cookie =~ "; HttpOnly"
    assert String.downcase(secure_cookie) =~ "; secure"
  end

  test "STALE_LOGOUT_REVOKES: an unverifiable bearer revokes the bound lineage it was offered for" do
    {browser, signed_in} = signed_in_browser()
    {:ok, account_id} = SessionAuthority.exact(claim(signed_in))
    topic = get_session(signed_in, :live_socket_id)
    AutolaunchWeb.Endpoint.subscribe(topic)
    {browser, csrf} = refreshed_csrf(browser)
    flush_test_messages()

    rejected =
      browser
      |> enforce_csrf()
      |> put_privy_pair("invalid")
      |> put_req_header("x-csrf-token", csrf)
      |> post("/auth/privy/session", %{})

    assert_response_sent_then_disconnect(topic)
    assert %{"error" => "unauthorized"} = json_response(rejected, 401)
    assert rejected.private[:plug_session_info] == :drop

    # The lineage the bearer was offered for is terminally revoked, so the
    # cookie the browser was still holding can neither authenticate nor mount.
    assert SessionAuthority.exact(claim(signed_in)) == {:error, :reset}
    assert SessionAuthority.sign_in(claim(signed_in), account_id) == {:error, :reset}

    held = build_conn() |> Phoenix.ConnTest.init_test_session(get_session(signed_in))
    assert %{"authenticated" => false} = held |> get("/auth/session") |> json_response(200)

    assert {:error, {:redirect, %{to: "/"}}} =
             build_conn()
             |> init_test_session(get_session(signed_in))
             |> live("/portfolio")
  end

  test "STALE_LOGOUT_REVOKES: lapsed wallet evidence fails closed on the same rule" do
    {browser, signed_in} = signed_in_browser()
    {browser, csrf} = refreshed_csrf(browser)

    rejected =
      browser
      |> enforce_csrf()
      |> put_privy_pair("no-wallet")
      |> put_req_header("x-csrf-token", csrf)
      |> post("/auth/privy/session", %{})

    assert %{"error" => "unauthorized"} = json_response(rejected, 401)
    assert rejected.private[:plug_session_info] == :drop

    assert {:ok, invalidated} = Accounts.get_by_privy_did("did:privy:verified", actor: %System{})
    assert invalidated.wallet_address == nil
    assert invalidated.wallet_addresses == []
    assert SessionAuthority.exact(claim(signed_in)) == {:error, :reset}
  end

  test "current provider evidence refreshes a stale former wallet without changing identity", %{
    conn: conn
  } do
    signed_in =
      conn
      |> init_test_session(%{})
      |> put_valid_csrf()
      |> put_privy_pair("valid")
      |> post("/auth/privy/session", %{})

    assert {:ok, account} = Accounts.get_by_privy_did("did:privy:verified", actor: %System{})
    topic = get_session(signed_in, :live_socket_id)

    refreshed =
      build_conn()
      |> init_test_session(get_session(signed_in))
      |> put_valid_csrf()
      |> put_privy_pair("changed-wallet")
      |> post("/auth/privy/session", %{})

    assert %{"authenticated" => true} = json_response(refreshed, 200)
    assert get_resp_header(refreshed, "x-autolaunch-session-changed") == ["false"]
    assert get_session(refreshed, :live_socket_id) == topic

    assert {:ok, current} = Accounts.get_by_privy_did("did:privy:verified", actor: %System{})
    assert current.id == account.id
    assert current.wallet_address == "0x2222222222222222222222222222222222222222"
    assert current.wallet_addresses == ["0x2222222222222222222222222222222222222222"]
  end

  test "a social account conflict preserves login and reports a connection error", %{conn: conn} do
    owner = Accounts.register_verified!("did:privy:conflict-owner", nil, [], actor: %System{})

    assert {:ok, _identity} =
             Accounts.upsert_linked_identity(
               :x,
               "shared-x-subject",
               "owner",
               nil,
               DateTime.utc_now(),
               %{},
               owner.id,
               actor: %System{}
             )

    response =
      conn
      |> init_test_session(%{})
      |> put_valid_csrf()
      |> put_privy_pair("conflicting-social")
      |> post("/auth/privy/session", %{})

    assert %{"authenticated" => true} = json_response(response, 200)
    assert get_resp_header(response, "x-autolaunch-identity-error") == ["already-connected"]

    account = Accounts.get_by_privy_did!("did:privy:conflicting-social", actor: %System{})
    assert SessionAuthority.exact(claim(response)) == {:ok, account.id}
    assert {:ok, []} = Accounts.list_linked_identities_for_account(account.id, actor: %System{})

    topic = get_session(response, :live_socket_id)
    AutolaunchWeb.Endpoint.subscribe(topic)

    refreshed =
      build_conn()
      |> init_test_session(get_session(response))
      |> put_valid_csrf()
      |> put_privy_pair("conflicting-social")
      |> post("/auth/privy/session", %{})

    assert %{"authenticated" => true} = json_response(refreshed, 200)
    assert get_resp_header(refreshed, "x-autolaunch-identity-error") == ["already-connected"]
    assert get_resp_header(refreshed, "x-autolaunch-session-changed") == ["false"]
    assert get_session(refreshed, :live_socket_id) == topic
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
  end

  @wallet "0x1111111111111111111111111111111111111111"

  defp account!(suffix) do
    Accounts.register_verified!(
      "did:privy:privy-session:#{suffix}:#{Elixir.System.unique_integer([:positive])}",
      @wallet,
      [@wallet],
      actor: %System{}
    )
  end

  # A browser that reached signed-in state through the real HTTP flow, so its
  # session travels only as a cookie and no test-side write marks it dirty.
  test "CENTRAL_CURRENT_ACTOR: an ordinary response under refused authority emits no Set-Cookie" do
    {browser, signed_in} = signed_in_browser()
    {:ok, account_id} = SessionAuthority.exact(claim(signed_in))
    stale = get_session(signed_in)

    # A delayed read must never be able to overwrite the cookie a later
    # response already gave this browser, so an ordinary request under refused
    # authority leaves the session untouched.
    assert {:ok, :refresh, _current} = SessionAuthority.sign_in(claim(signed_in), account_id)
    assert_no_session_cookie(browser)

    assert SessionAuthority.revoke(claim(signed_in))
    assert_no_session_cookie(browser)

    malformed = %{stale | "live_socket_id" => SessionAuthority.topic(unrelated_lineage())}
    assert_no_session_cookie(carrying(malformed))
    assert_no_session_cookie(carrying(Map.delete(stale, "live_socket_id")))
  end

  defp assert_no_session_cookie(browser) do
    for read <- [&get(&1, "/portfolio"), &get(&1, "/auth/session"), &get(&1, "/")] do
      refute browser |> recycled() |> read.() |> session_cookie()
    end
  end

  # A browser holding `session` in a genuinely signed cookie rather than in the
  # test process, so the response's own cookie decision is what is observed.
  defp carrying(session) do
    options =
      :autolaunch
      |> Application.fetch_env!(:session_options)
      |> Keyword.drop([:store, :key])
      |> Plug.Session.COOKIE.init()

    cookie =
      Plug.Session.COOKIE.put(
        %{build_conn() | secret_key_base: AutolaunchWeb.Endpoint.config(:secret_key_base)},
        nil,
        session,
        options
      )

    put_req_cookie(build_conn(), "_autolaunch_key", cookie)
  end

  defp unrelated_lineage, do: SessionAuthority.bootstrap().lineage

  defp signed_in_browser do
    bootstrapped = csrf_bootstrap(build_conn())

    signed_in =
      bootstrapped
      |> recycled()
      |> enforce_csrf()
      |> put_privy_pair("valid")
      |> put_req_header("x-csrf-token", json_response(bootstrapped, 200)["csrf_token"])
      |> post("/auth/privy/session", %{})

    assert %{"authenticated" => true} = json_response(signed_in, 200)
    {recycled(signed_in), signed_in}
  end

  # What the browser does after a renewing response: adopt the rotated token.
  defp refreshed_csrf(browser) do
    response = csrf_bootstrap(browser)
    {recycled(response), json_response(response, 200)["csrf_token"]}
  end

  defp claim(conn), do: conn |> get_session() |> SessionAuthority.claim()

  defp csrf_bootstrap(conn), do: get(conn, "/auth/csrf")

  # Restores the release budget this file's bound is specified in, and hands the
  # limiter back the way the next case expects to find it. Every case that spends
  # the budget lives in this synchronous file, so no reset can race an admission.
  defp release_budget do
    raised = Application.fetch_env!(:autolaunch, :session_bootstrap_rate_limit)
    Application.put_env(:autolaunch, :session_bootstrap_rate_limit, @release_budget)
    BootstrapRateLimiter.reset()

    on_exit(fn ->
      Application.put_env(:autolaunch, :session_bootstrap_rate_limit, raised)
      BootstrapRateLimiter.reset()
    end)
  end

  # A cookie-less browser whose peer address is `peer`, carrying `headers`
  # exactly as given so a duplicated or forged address header travels the way a
  # client would actually send it.
  defp bootstrap_from(peer, headers \\ []) do
    conn = %{build_conn() | remote_ip: peer}
    csrf_bootstrap(%{conn | req_headers: conn.req_headers ++ headers})
  end

  # Spends one client's whole budget and returns its next, denied, response.
  defp exhaust(request) do
    Enum.each(1..@limit, fn _ -> assert request.().status == 200 end)
    request.()
  end

  defp authority_count, do: Ash.count!(SessionAuthority, actor: %System{})

  defp attach_denial_telemetry do
    handler = "session-bootstrap-denial-#{Elixir.System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      handler,
      @denial_event,
      fn _event, measurements, metadata, _config ->
        send(test, {:denial, measurements, metadata})
      end,
      nil
    )

    handler
  end

  # Carries the response's own cookie into the next request the way a browser
  # does, without losing the connect info a mount needs.
  defp recycled(conn), do: conn |> Phoenix.ConnTest.recycle() |> connects_with_own_cookie()

  defp put_valid_csrf(conn) do
    token = Plug.CSRFProtection.get_csrf_token()

    conn
    |> enforce_csrf()
    |> put_session("_csrf_token", Plug.CSRFProtection.dump_state())
    |> put_req_header("x-csrf-token", token)
  end

  defp enforce_csrf(conn),
    do: %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}

  defp session_cookie(conn) do
    conn |> get_resp_header("set-cookie") |> Enum.find(&String.contains?(&1, "_autolaunch_key"))
  end

  defp flush_test_messages do
    receive do
      _message -> flush_test_messages()
    after
      0 -> :ok
    end
  end

  defp assert_response_sent_then_disconnect(topic) do
    assert receive_until_disconnect(topic, []) == [:response_sent, :socket_disconnect]
  end

  defp receive_until_disconnect(topic, events) do
    receive do
      {:plug_conn, :sent} ->
        receive_until_disconnect(topic, [:response_sent | events])

      %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"} ->
        Enum.reverse([:socket_disconnect | events])

      _message ->
        receive_until_disconnect(topic, events)
    after
      100 -> flunk("expected response send followed by socket disconnect")
    end
  end

  defp account_evidence(nil), do: nil

  defp account_evidence(account),
    do:
      Map.take(account, [:id, :privy_user_id, :wallet_address, :wallet_addresses, :display_name])
end
