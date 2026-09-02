defmodule AutolaunchWeb.XOAuthControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.System
  require Logger

  defmodule Strategy do
    def authorize_url(config),
      do: Application.fetch_env!(:autolaunch, :x_controller_authorize).(config)

    def callback(config, params),
      do: Application.fetch_env!(:autolaunch, :x_controller_callback).(config, params)
  end

  setup do
    Application.put_env(:autolaunch, :x_oauth_client_id, "controller-client")
    Application.put_env(:autolaunch, :x_oauth_strategy, Strategy)

    Application.put_env(:autolaunch, :x_controller_authorize, fn _config ->
      {:ok,
       %{
         url: "https://x.example.test/authorize?state=controller-state",
         session_params: %{state: "controller-state", code_verifier: "controller-verifier"}
       }}
    end)

    Application.put_env(:autolaunch, :x_controller_callback, fn _config, _params ->
      {:ok,
       %{
         token: %{"access_token" => "callback-access-token"},
         user: %{
           "data" => %{
             "id" => "controller-user",
             "username" => "controller_profile",
             "name" => "Controller Profile"
           }
         }
       }}
    end)

    on_exit(fn ->
      for key <- [
            :x_oauth_client_id,
            :x_oauth_strategy,
            :x_controller_authorize,
            :x_controller_callback
          ],
          do: Application.delete_env(:autolaunch, key)
    end)

    :ok
  end

  test "start and disconnect require the live signed-in session and valid CSRF", %{conn: conn} do
    account = account!("csrf")

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> enforce_csrf()
      |> post("/auth/x/connections/profile")
    end

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> enforce_csrf()
      |> delete("/auth/x/connections/profile")
    end

    started =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> put_valid_csrf()
      |> post("/auth/x/connections/profile", intent_params())

    assert %{
             "url" => "https://x.example.test/authorize?state=controller-state",
             "role" => "profile",
             "generation" => generation
           } = json_response(started, 200)

    assert is_binary(generation)
    assert get_resp_header(started, "cache-control") == ["no-store"]

    disconnected =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> put_valid_csrf()
      |> delete("/auth/x/connections/profile", intent_params())

    assert %{"ok" => true, "role" => "profile"} = json_response(disconnected, 200)

    anonymous =
      build_conn()
      |> init_test_session(%{})
      |> put_valid_csrf()
      |> post("/auth/x/connections/profile", intent_params())

    assert json_response(anonymous, 409) == %{"error" => "stale_authority"}
  end

  test "callback uses only the endpoint origin and never reflects OAuth secrets", %{conn: conn} do
    account = account!("callback")

    started =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> put_valid_csrf()
      |> post("/auth/x/connections/company", intent_params())

    %{"generation" => generation} = json_response(started, 200)

    test_process = self()

    logs =
      capture_log(fn ->
        Logger.warning("X callback log-capture sentinel")

        callback =
          started
          |> recycle()
          |> Map.put(:host, "attacker.example")
          |> get("/auth/x/callback", %{
            "state" => "controller-state",
            "code" => "callback-code"
          })

        send(test_process, {:x_callback_response, callback})
      end)

    assert_received {:x_callback_response, callback}
    assert logs =~ "X callback log-capture sentinel"
    refute logs =~ "controller-state"
    refute logs =~ "callback-code"

    body = html_response(callback, 200)
    assert body =~ ~s(data-origin="#{Autolaunch.Accounts.XOAuth.origin()}")
    assert body =~ ~s(data-generation="#{generation}")
    assert body =~ ~s(data-role="company")
    assert body =~ ~s(source: "ash-x-oauth")
    refute body =~ "attacker.example"
    refute body =~ "controller-state"
    refute body =~ "controller-verifier"
    refute body =~ "callback-code"
    refute body =~ "callback-access-token"
    assert get_resp_header(callback, "cache-control") == ["no-store"]
    assert get_resp_header(callback, "content-security-policy") != []
  end

  test "a provider denial returns only the exact preflighted popup identity", %{conn: conn} do
    account = account!("provider-denial")

    started =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> put_valid_csrf()
      |> post("/auth/x/connections/profile", intent_params())

    %{"generation" => generation} = json_response(started, 200)

    Application.put_env(:autolaunch, :x_controller_callback, fn _config, _params ->
      {:error, :access_denied}
    end)

    denied =
      started
      |> recycle()
      |> get("/auth/x/callback", %{
        "state" => "controller-state",
        "error" => "access_denied"
      })

    denied_body = html_response(denied, 200)
    assert denied_body =~ ~s(data-status="failed")
    assert denied_body =~ ~s(data-role="profile")
    assert denied_body =~ ~s(data-generation="#{generation}")

    invalid =
      started
      |> recycle()
      |> get("/auth/x/callback", %{"state" => "wrong-state", "error" => "access_denied"})

    invalid_body = html_response(invalid, 200)
    assert invalid_body =~ ~s(data-status="failed")
    assert invalid_body =~ ~s(data-role="")
    assert invalid_body =~ ~s(data-generation="")
  end

  test "missing X configuration disables start without changing the session", %{conn: conn} do
    Application.delete_env(:autolaunch, :x_oauth_client_id)
    account = account!("disabled")

    response =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> put_valid_csrf()
      |> post("/auth/x/connections/profile", intent_params())

    assert json_response(response, 503) == %{"error" => "x_oauth_disabled"}
  end

  defp account!(suffix) do
    nonce = Elixir.System.unique_integer([:positive])

    wallet =
      "0x" <>
        (:crypto.hash(:sha256, "controller:#{suffix}:#{nonce}")
         |> Base.encode16(case: :lower)
         |> binary_part(0, 40))

    Accounts.register_verified!(
      "did:privy:x-controller:#{suffix}:#{nonce}",
      wallet,
      [wallet],
      actor: %System{}
    )
  end

  defp put_valid_csrf(conn) do
    token = Plug.CSRFProtection.get_csrf_token()

    conn
    |> enforce_csrf()
    |> put_session("_csrf_token", Plug.CSRFProtection.dump_state())
    |> put_req_header("x-csrf-token", token)
  end

  defp enforce_csrf(conn),
    do: %{conn | private: Map.delete(conn.private, :plug_skip_csrf_protection)}

  defp intent_params do
    %{
      "intent_sequence" => Elixir.System.unique_integer([:positive, :monotonic]),
      "intent_generation" => Ash.UUID.generate()
    }
  end
end
