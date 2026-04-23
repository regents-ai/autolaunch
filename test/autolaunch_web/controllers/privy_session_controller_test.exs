defmodule AutolaunchWeb.PrivySessionControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.Controller, only: [get_csrf_token: 0]
  import Autolaunch.TestSupport.XmtpSupport

  alias Autolaunch.Accounts

  @test_wallet_private_key "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

  setup do
    ensure_xmtp_identity_runtime!()
    privy = setup_privy_config!()
    Application.put_env(:autolaunch, :portfolio_schedule_test_pid, self())
    original = Application.get_env(:autolaunch, :privy_session_controller, [])

    Application.put_env(
      :autolaunch,
      :privy_session_controller,
      privy_module: Autolaunch.Privy,
      portfolio_module: __MODULE__.PortfolioStub
    )

    on_exit(fn ->
      privy.restore.()
      Application.put_env(:autolaunch, :privy_session_controller, original)
      Application.delete_env(:autolaunch, :portfolio_schedule_test_pid)
    end)

    {:ok, privy: privy}
  end

  defmodule PortfolioStub do
    def schedule_login_refresh(human) do
      if pid = Application.get_env(:autolaunch, :portfolio_schedule_test_pid) do
        send(pid, {:scheduled_portfolio_refresh, human.privy_user_id})
      end

      :ok
    end
  end

  test "POST /v1/auth/privy/session writes the browser session and returns the next room step",
       %{conn: conn, privy: privy} do
    wallet_address = cast_wallet_address!(@test_wallet_private_key) |> String.downcase()

    conn =
      conn
      |> csrf_json_conn()
      |> with_privy_bearer("privy-autolaunch-user", privy.app_id, privy.private_pem)
      |> post("/v1/auth/privy/session", %{
        "display_name" => "Autolaunch User",
        "wallet_address" => wallet_address,
        "wallet_addresses" => [wallet_address]
      })

    assert %{
             "ok" => true,
             "human" => %{
               "privy_user_id" => "privy-autolaunch-user",
               "display_name" => "Autolaunch User",
               "wallet_address" => ^wallet_address,
               "wallet_addresses" => [^wallet_address],
               "xmtp_inbox_id" => nil
             },
             "xmtp" => %{
               "status" => "signature_required",
               "wallet_address" => ^wallet_address,
               "client_id" => client_id,
               "signature_request_id" => signature_request_id,
               "signature_text" => signature_text,
               "inbox_id" => nil
             }
           } = json_response(conn, 200)

    assert is_binary(client_id) and client_id != ""
    assert is_binary(signature_request_id) and signature_request_id != ""
    assert is_binary(signature_text) and signature_text != ""
    assert get_session(conn, :privy_user_id) == "privy-autolaunch-user"
    assert_received {:scheduled_portfolio_refresh, "privy-autolaunch-user"}

    assert %Autolaunch.Accounts.HumanUser{
             privy_user_id: "privy-autolaunch-user",
             display_name: "Autolaunch User",
             wallet_address: nil,
             xmtp_inbox_id: nil
           } = Accounts.get_human_by_privy_id("privy-autolaunch-user")
  end

  test "POST /v1/auth/privy/xmtp/complete stores the room identity and returns a ready session",
       %{conn: conn, privy: privy} do
    wallet_address = cast_wallet_address!(@test_wallet_private_key) |> String.downcase()

    session_conn =
      conn
      |> csrf_json_conn()
      |> with_privy_bearer("privy-autolaunch-complete", privy.app_id, privy.private_pem)
      |> post("/v1/auth/privy/session", %{
        "display_name" => "Complete User",
        "wallet_address" => wallet_address,
        "wallet_addresses" => [wallet_address]
      })

    assert %{
             "xmtp" => %{
               "client_id" => client_id,
               "signature_request_id" => signature_request_id,
               "signature_text" => signature_text
             }
           } = json_response(session_conn, 200)

    signature = cast_wallet_sign!(@test_wallet_private_key, signature_text)
    expected_inbox_id = deterministic_inbox_id(wallet_address)

    complete_conn =
      session_conn
      |> recycle()
      |> csrf_json_conn()
      |> post("/v1/auth/privy/xmtp/complete", %{
        "wallet_address" => wallet_address,
        "client_id" => client_id,
        "signature_request_id" => signature_request_id,
        "signature" => signature
      })

    assert %{
             "ok" => true,
             "human" => %{
               "wallet_address" => ^wallet_address,
               "wallet_addresses" => [^wallet_address],
               "xmtp_inbox_id" => ^expected_inbox_id
             },
             "xmtp" => %{"status" => "ready", "inbox_id" => ^expected_inbox_id}
           } = json_response(complete_conn, 200)

    assert %Autolaunch.Accounts.HumanUser{
             wallet_address: ^wallet_address,
             xmtp_inbox_id: ^expected_inbox_id
           } = Accounts.get_human_by_privy_id("privy-autolaunch-complete")
  end

  test "GET /v1/auth/privy/profile returns an empty session when signed out", %{conn: conn} do
    conn = get(conn, "/v1/auth/privy/profile")

    assert %{"ok" => true, "human" => nil, "xmtp" => nil} = json_response(conn, 200)
  end

  test "GET /v1/auth/privy/profile keeps a ready inbox for a known wallet", %{
    conn: conn,
    privy: privy
  } do
    wallet_address = "0x1234567890abcdef1234567890abcdef12345678"
    inbox_id = deterministic_inbox_id(wallet_address)

    {:ok, _human} =
      Accounts.upsert_human_by_privy_id("privy-autolaunch-ready", %{
        "display_name" => "Ready User",
        "wallet_address" => wallet_address,
        "wallet_addresses" => [wallet_address],
        "xmtp_inbox_id" => inbox_id
      })

    session_conn =
      conn
      |> csrf_json_conn()
      |> with_privy_bearer("privy-autolaunch-ready", privy.app_id, privy.private_pem)
      |> post("/v1/auth/privy/session", %{
        "display_name" => "Ready User",
        "wallet_address" => wallet_address,
        "wallet_addresses" => [wallet_address]
      })

    assert %{
             "human" => %{"xmtp_inbox_id" => ^inbox_id},
             "xmtp" => %{"status" => "ready", "inbox_id" => ^inbox_id}
           } = json_response(session_conn, 200)
  end

  defp ensure_xmtp_identity_runtime! do
    case Process.whereis(Autolaunch.XmtpIdentity.Runtime.IdentityServer) do
      nil -> start_supervised!(Autolaunch.XmtpIdentity)
      _pid -> :ok
    end
  end

  defp csrf_json_conn(conn) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("x-csrf-token", get_csrf_token())
  end
end
