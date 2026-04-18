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
           chain_id: 84_532
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

    def create_launch_job(_params, _human, request_ip) do
      {:ok, %{job_id: "job_123", status: "queued", request_ip: request_ip}}
    end

    def get_job_response("job_123") do
      {:ok,
       %{
         job: %{
           job_id: "job_123",
           status: "queued",
           step: "queued",
           owner_address: "0x1111111111111111111111111111111111111111"
         },
         auction: nil
       }}
    end

    def get_job_response("job_forbidden") do
      {:ok,
       %{
         job: %{
           job_id: "job_forbidden",
           status: "queued",
           step: "queued",
           owner_address: "0x9999999999999999999999999999999999999999"
         },
         auction: nil
       }}
    end

    def get_job_response("job_missing"), do: {:error, :not_found}

    def get_job_response(_job_id), do: {:error, :not_found}
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

  defp signed_in_conn(conn, human) do
    init_test_session(conn, privy_user_id: human.privy_user_id)
  end

  defp launch_preview_payload do
    %{
      "agent_id" => "84532:42",
      "token_name" => "Atlas Coin",
      "token_symbol" => "ATLAS"
    }
  end

  defp launch_job_payload(signature) do
    %{
      "agent_id" => "84532:42",
      "token_name" => "Atlas Coin",
      "token_symbol" => "ATLAS",
      "wallet_address" => @wallet,
      "message" => "signed message",
      "signature" => signature,
      "nonce" => "nonce-1"
    }
  end

  defp launch_job_path(job_id), do: "/api/launch/jobs/#{job_id}"
  defp launch_preview_path, do: "/api/launch/preview"

  test "preview returns the normalized launch review", %{conn: conn, human: human} do
    conn = signed_in_conn(conn, human)

    conn = post(conn, launch_preview_path(), launch_preview_payload())

    assert %{
             "ok" => true,
             "preview" => %{
               "agent" => %{"agent_id" => "84532:42"},
               "token" => %{"chain_id" => 84_532, "symbol" => "ATLAS"}
             }
           } = json_response(conn, 200)
  end

  test "launch preview rejects unauthenticated access", %{conn: conn} do
    conn = post(conn, launch_preview_path(), launch_preview_payload())

    assert %{"ok" => false, "error" => %{"code" => "auth_required"}} = json_response(conn, 401)
  end

  test "launch job creation returns queued data for the signed-in owner", %{
    conn: conn,
    human: human
  } do
    conn = signed_in_conn(conn, human)

    conn = post(conn, "/api/launch/jobs", launch_job_payload("good"))

    assert %{"ok" => true, "job_id" => "job_123", "status" => "queued"} = json_response(conn, 200)
  end

  test "create_job ignores spoofed forwarded headers when recording the request ip", %{
    conn: conn,
    human: human
  } do
    conn =
      conn
      |> Map.put(:remote_ip, {203, 0, 113, 10})
      |> signed_in_conn(human)
      |> put_req_header("x-forwarded-for", "198.51.100.77")

    conn = post(conn, "/api/launch/jobs", launch_job_payload("good"))

    assert %{
             "ok" => true,
             "job" => %{"request_ip" => "203.0.113.10"}
           } = json_response(conn, 200)
  end

  test "launch job creation returns signature verification failures", %{
    conn: conn,
    human: human
  } do
    conn = signed_in_conn(conn, human)

    conn = post(conn, "/api/launch/jobs", launch_job_payload("bad"))

    assert %{"ok" => false, "reason" => "bad signature"} = json_response(conn, 401)
  end

  test "launch job creation returns sidecar failures", %{conn: conn, human: human} do
    conn = signed_in_conn(conn, human)

    conn = post(conn, "/api/launch/jobs", launch_job_payload("sidecar"))

    assert %{"ok" => false, "error" => "siwa_down"} = json_response(conn, 503)
  end

  test "launch job show rejects unauthorized access", %{conn: conn, human: human} do
    conn = signed_in_conn(conn, human)

    conn = get(conn, launch_job_path("job_forbidden"))

    assert %{"ok" => false, "error" => %{"code" => "job_forbidden"}} = json_response(conn, 403)
  end

  test "launch job show rejects unauthenticated access", %{conn: conn} do
    conn = get(conn, launch_job_path("job_123"))

    assert %{"ok" => false, "error" => %{"code" => "auth_required"}} = json_response(conn, 401)
  end

  test "launch job show returns data for the signed-in owner", %{conn: conn, human: human} do
    conn = signed_in_conn(conn, human)

    conn = get(conn, launch_job_path("job_123"))

    assert %{
             "ok" => true,
             "job" => %{"job_id" => "job_123", "status" => "queued"}
           } = json_response(conn, 200)
  end

  test "launch job show returns not found for the signed-in owner when the job is missing", %{
    conn: conn,
    human: human
  } do
    conn = signed_in_conn(conn, human)

    conn = get(conn, launch_job_path("job_missing"))

    assert %{"ok" => false, "error" => %{"code" => "job_not_found"}} =
             json_response(conn, 404)
  end
end
