defmodule AutolaunchWeb.Api.LaunchControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts

  @wallet "0x1111111111111111111111111111111111111111"

  defmodule LaunchStub do
    def preview_launch(_params, nil), do: {:error, :unauthorized}
    def preview_launch(%{"agent_id" => "missing"}, _human), do: {:error, :agent_not_found}

    def preview_launch(params, _human) do
      {:ok,
       %{
         agent: %{agent_id: params["agent_id"], name: "Atlas"},
         token: %{
           name: params["token_name"],
           symbol: params["token_symbol"],
           chain_id: 11_155_111
         }
       }}
    end

    def create_launch_job(_params, nil, _request_ip), do: {:error, :unauthorized}

    def create_launch_job(
          %{"wallet_address" => "0x9999999999999999999999999999999999999999"},
          _,
          _
        ) do
      {:error, :wallet_mismatch}
    end

    def create_launch_job(%{"signature" => "bad"}, _, _) do
      {:error, {:verify_failed, %{"ok" => false, "reason" => "bad signature"}}}
    end

    def create_launch_job(%{"signature" => "sidecar"}, _, _) do
      {:error, {:sidecar_error, 503, %{"ok" => false, "error" => "siwa_down"}}}
    end

    def create_launch_job(_params, _human, _request_ip) do
      {:ok, %{job_id: "job_123", status: "queued"}}
    end

    def get_job_response("job_123", _owner_address) do
      %{job: %{job_id: "job_123", status: "queued", step: "queued"}, auction: nil}
    end

    def get_job_response("job_forbidden", "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"),
      do: {:error, :forbidden}

    def get_job_response(_job_id, _owner_address), do: nil
  end

  setup %{conn: conn} do
    original = Application.get_env(:autolaunch, :launch_controller, [])
    Application.put_env(:autolaunch, :launch_controller, launch_module: LaunchStub)

    on_exit(fn ->
      Application.put_env(:autolaunch, :launch_controller, original)
    end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:launch-controller", %{
        "wallet_address" => @wallet,
        "wallet_addresses" => [@wallet],
        "display_name" => "Launch Operator"
      })

    %{conn: conn, human: human}
  end

  test "preview returns the normalized launch review", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)

    conn =
      post(conn, "/api/launch/preview", %{
        "agent_id" => "11155111:42",
        "token_name" => "Atlas Coin",
        "token_symbol" => "ATLAS"
      })

    assert %{
             "ok" => true,
             "preview" => %{
               "agent" => %{"agent_id" => "11155111:42"},
               "token" => %{"chain_id" => 11_155_111, "symbol" => "ATLAS"}
             }
           } = json_response(conn, 200)
  end

  test "preview still requires auth", %{conn: conn} do
    conn =
      post(conn, "/api/launch/preview", %{
        "agent_id" => "11155111:42",
        "token_name" => "Atlas Coin",
        "token_symbol" => "ATLAS"
      })

    assert %{"ok" => false, "error" => %{"code" => "auth_required"}} = json_response(conn, 401)
  end

  test "create_job returns queued launch data", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)

    conn =
      post(conn, "/api/launch/jobs", %{
        "agent_id" => "11155111:42",
        "token_name" => "Atlas Coin",
        "token_symbol" => "ATLAS",
        "wallet_address" => @wallet,
        "message" => "signed message",
        "signature" => "good",
        "nonce" => "nonce-1"
      })

    assert %{"ok" => true, "job_id" => "job_123", "status" => "queued"} = json_response(conn, 200)
  end

  test "create_job passes through signature verification failures", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)

    conn =
      post(conn, "/api/launch/jobs", %{
        "agent_id" => "11155111:42",
        "token_name" => "Atlas Coin",
        "token_symbol" => "ATLAS",
        "wallet_address" => @wallet,
        "message" => "signed message",
        "signature" => "bad",
        "nonce" => "nonce-1"
      })

    assert %{"ok" => false, "reason" => "bad signature"} = json_response(conn, 401)
  end

  test "create_job passes through sidecar failures", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)

    conn =
      post(conn, "/api/launch/jobs", %{
        "agent_id" => "11155111:42",
        "token_name" => "Atlas Coin",
        "token_symbol" => "ATLAS",
        "wallet_address" => @wallet,
        "message" => "signed message",
        "signature" => "sidecar",
        "nonce" => "nonce-1"
      })

    assert %{"ok" => false, "error" => "siwa_down"} = json_response(conn, 503)
  end

  test "show_job enforces owner filtering", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)

    conn =
      get(
        conn,
        "/api/launch/jobs/job_forbidden?address=0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
      )

    assert %{"ok" => false, "error" => %{"code" => "job_forbidden"}} = json_response(conn, 403)
  end
end
