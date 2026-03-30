defmodule AutolaunchWeb.Api.LifecycleControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  defmodule LifecycleStub do
    def job_summary("job_alpha", _human) do
      {:ok,
       %{
         job: %{job_id: "job_alpha", status: "ready"},
         auction: %{auction_id: "auc_alpha", status: "settled"},
         current_block: 1_234,
         migrate_ready: true,
         currency_sweep_ready: false,
         token_sweep_ready: false,
         vesting_release_ready: false,
         recommended_action: "migrate"
       }}
    end

    def job_summary(_job_id, _human), do: {:error, :not_found}

    def prepare_finalize("job_alpha", _human) do
      {:ok,
       %{
         job: %{job_id: "job_alpha", status: "ready"},
         recommended_action: "migrate",
         prepared: %{
           resource: "strategy",
           action: "migrate",
           tx_request: %{
             chain_id: 11_155_111,
             to: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
             value: "0x0",
             data: "0x8fd3ab80"
           }
         }
       }}
    end

    def prepare_finalize(_job_id, _human), do: {:error, :not_found}

    def register_finalize("job_alpha", %{"tx_hash" => tx_hash}, _human) do
      {:ok,
       %{
         job_id: "job_alpha",
         tx_hash: tx_hash,
         status: "submitted",
         recommended_action: "migrate",
         next_summary: %{recommended_action: "wait"}
       }}
    end

    def register_finalize(_job_id, _attrs, _human), do: {:error, :invalid_transaction_hash}

    def vesting_status("job_alpha", _human) do
      {:ok,
       %{
         job_id: "job_alpha",
         vesting_wallet_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
         releasable_launch_token: 25,
         released_launch_token: 10,
         beneficiary: "0x00000000000000000000000000000000000000aa",
         start_timestamp: 1_700_000_000,
         duration_seconds: 31_536_000,
         release_ready: true
       }}
    end

    def vesting_status(_job_id, _human), do: {:error, :not_found}
  end

  setup do
    original = Application.get_env(:autolaunch, :lifecycle_api, [])
    Application.put_env(:autolaunch, :lifecycle_api, context_module: LifecycleStub)
    on_exit(fn -> Application.put_env(:autolaunch, :lifecycle_api, original) end)
    :ok
  end

  test "returns lifecycle summary", %{conn: conn} do
    conn = get(conn, "/api/lifecycle/jobs/job_alpha")

    assert %{
             "ok" => true,
             "job" => %{"job_id" => "job_alpha"},
             "recommended_action" => "migrate",
             "migrate_ready" => true
           } = json_response(conn, 200)
  end

  test "prepares finalize action payload", %{conn: conn} do
    conn = post(conn, "/api/lifecycle/jobs/job_alpha/finalize/prepare", %{})

    assert %{
             "ok" => true,
             "prepared" => %{
               "resource" => "strategy",
               "action" => "migrate",
               "tx_request" => %{"data" => "0x8fd3ab80"}
             }
           } = json_response(conn, 200)
  end

  test "registers finalize transaction hashes", %{conn: conn} do
    conn =
      post(conn, "/api/lifecycle/jobs/job_alpha/finalize/register", %{
        "tx_hash" => "0x" <> String.duplicate("a", 64)
      })

    assert %{
             "ok" => true,
             "status" => "submitted",
             "tx_hash" => "0x" <> _
           } = json_response(conn, 200)
  end

  test "returns vesting status", %{conn: conn} do
    conn = get(conn, "/api/lifecycle/jobs/job_alpha/vesting")

    assert %{
             "ok" => true,
             "job_id" => "job_alpha",
             "release_ready" => true,
             "releasable_launch_token" => 25
           } = json_response(conn, 200)
  end
end
