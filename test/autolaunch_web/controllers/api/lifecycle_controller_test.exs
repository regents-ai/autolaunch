defmodule AutolaunchWeb.Api.LifecycleControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts

  @wallet "0x1111111111111111111111111111111111111111"

  defmodule LifecycleStub do
    @authorized_wallet "0x1111111111111111111111111111111111111111"

    def job_summary("job_alpha", human) do
      case access_status(human) do
        :authorized ->
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

        :unauthorized ->
          {:error, :unauthorized}

        :forbidden ->
          {:error, :forbidden}
      end
    end

    def job_summary(_job_id, human) do
      case access_status(human) do
        :authorized -> {:error, :not_found}
        :unauthorized -> {:error, :unauthorized}
        :forbidden -> {:error, :forbidden}
      end
    end

    def prepare_finalize("job_alpha", human) do
      case access_status(human) do
        :authorized ->
          {:ok,
           %{
             job: %{job_id: "job_alpha", status: "ready"},
             recommended_action: "migrate",
             prepared: %{
               resource: "strategy",
               action: "migrate",
               tx_request: %{
                 chain_id: 84_532,
                 to: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                 value: "0x0",
                 data: "0x8fd3ab80"
               }
             }
           }}

        :unauthorized ->
          {:error, :unauthorized}

        :forbidden ->
          {:error, :forbidden}
      end
    end

    def prepare_finalize(_job_id, human) do
      case access_status(human) do
        :authorized -> {:error, :not_found}
        :unauthorized -> {:error, :unauthorized}
        :forbidden -> {:error, :forbidden}
      end
    end

    def register_finalize("job_alpha", %{"tx_hash" => tx_hash}, human) do
      case access_status(human) do
        :authorized ->
          if valid_tx_hash?(tx_hash) do
            {:ok,
             %{
               job_id: "job_alpha",
               tx_hash: tx_hash,
               status: "submitted",
               recommended_action: "migrate",
               next_summary: %{recommended_action: "wait"}
             }}
          else
            {:error, :invalid_transaction_hash}
          end

        :unauthorized ->
          {:error, :unauthorized}

        :forbidden ->
          {:error, :forbidden}
      end
    end

    def register_finalize(_job_id, _attrs, human) do
      case access_status(human) do
        :authorized -> {:error, :not_found}
        :unauthorized -> {:error, :unauthorized}
        :forbidden -> {:error, :forbidden}
      end
    end

    def vesting_status("job_alpha", human) do
      case access_status(human) do
        :authorized ->
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

        :unauthorized ->
          {:error, :unauthorized}

        :forbidden ->
          {:error, :forbidden}
      end
    end

    def vesting_status(_job_id, human) do
      case access_status(human) do
        :authorized -> {:error, :not_found}
        :unauthorized -> {:error, :unauthorized}
        :forbidden -> {:error, :forbidden}
      end
    end

    defp access_status(nil), do: :unauthorized

    defp access_status(%{} = human) do
      [Map.get(human, :wallet_address) | List.wrap(Map.get(human, :wallet_addresses))]
      |> Enum.map(&normalize_address/1)
      |> Enum.any?(&(&1 == @authorized_wallet))
      |> then(fn
        true -> :authorized
        false -> :forbidden
      end)
    end

    defp access_status(_human), do: :unauthorized

    defp normalize_address(value) when is_binary(value) do
      value |> String.trim() |> String.downcase()
    end

    defp normalize_address(_value), do: nil

    defp valid_tx_hash?(tx_hash) when is_binary(tx_hash) do
      Regex.match?(~r/\A0x[0-9a-fA-F]{64}\z/, tx_hash)
    end

    defp valid_tx_hash?(_tx_hash), do: false
  end

  setup %{conn: conn} do
    original = Application.get_env(:autolaunch, :lifecycle_api, [])
    Application.put_env(:autolaunch, :lifecycle_api, context_module: LifecycleStub)
    on_exit(fn -> Application.put_env(:autolaunch, :lifecycle_api, original) end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:lifecycle-controller", %{
        "wallet_address" => @wallet,
        "wallet_addresses" => [@wallet],
        "display_name" => "Lifecycle Operator"
      })

    {:ok, wrong_human} =
      Accounts.upsert_human_by_privy_id("did:privy:lifecycle-controller-wrong", %{
        "wallet_address" => "0x2222222222222222222222222222222222222222",
        "wallet_addresses" => ["0x2222222222222222222222222222222222222222"],
        "display_name" => "Wrong Wallet"
      })

    %{conn: conn, human: human, wrong_human: wrong_human}
  end

  defp signed_in_conn(conn, human) do
    init_test_session(conn, privy_user_id: human.privy_user_id)
  end

  defp lifecycle_job_path(job_id), do: "/api/lifecycle/jobs/#{job_id}"

  defp lifecycle_finalize_prepare_path(job_id),
    do: "/api/lifecycle/jobs/#{job_id}/finalize/prepare"

  defp lifecycle_finalize_register_path(job_id),
    do: "/api/lifecycle/jobs/#{job_id}/finalize/register"

  defp lifecycle_vesting_path(job_id), do: "/api/lifecycle/jobs/#{job_id}/vesting"

  test "lifecycle summary rejects unauthenticated access", %{conn: conn} do
    summary_conn = get(conn, lifecycle_job_path("job_alpha"))

    assert %{"ok" => false, "error" => %{"code" => "auth_required"}} =
             json_response(summary_conn, 401)
  end

  test "lifecycle finalize prepare rejects unauthenticated access", %{conn: conn} do
    prepare_conn = post(conn, lifecycle_finalize_prepare_path("job_alpha"), %{})

    assert %{"ok" => false, "error" => %{"code" => "auth_required"}} =
             json_response(prepare_conn, 401)
  end

  test "lifecycle finalize register rejects unauthenticated access", %{conn: conn} do
    register_conn =
      post(conn, lifecycle_finalize_register_path("job_alpha"), %{
        "tx_hash" => "0x" <> String.duplicate("a", 64)
      })

    assert %{"ok" => false, "error" => %{"code" => "auth_required"}} =
             json_response(register_conn, 401)
  end

  test "lifecycle vesting rejects unauthenticated access", %{conn: conn} do
    vesting_conn = get(conn, lifecycle_vesting_path("job_alpha"))

    assert %{"ok" => false, "error" => %{"code" => "auth_required"}} =
             json_response(vesting_conn, 401)
  end

  test "lifecycle summary rejects signed-in wrong-wallet access", %{
    conn: conn,
    wrong_human: wrong_human
  } do
    conn = signed_in_conn(conn, wrong_human)
    summary_conn = get(conn, lifecycle_job_path("job_alpha"))

    assert %{"ok" => false, "error" => %{"code" => "lifecycle_forbidden"}} =
             json_response(summary_conn, 403)
  end

  test "lifecycle finalize prepare rejects signed-in wrong-wallet access", %{
    conn: conn,
    wrong_human: wrong_human
  } do
    conn = signed_in_conn(conn, wrong_human)
    prepare_conn = post(conn, lifecycle_finalize_prepare_path("job_alpha"), %{})

    assert %{"ok" => false, "error" => %{"code" => "lifecycle_forbidden"}} =
             json_response(prepare_conn, 403)
  end

  test "lifecycle finalize register rejects signed-in wrong-wallet access", %{
    conn: conn,
    wrong_human: wrong_human
  } do
    conn = signed_in_conn(conn, wrong_human)

    register_conn =
      post(conn, lifecycle_finalize_register_path("job_alpha"), %{
        "tx_hash" => "0x" <> String.duplicate("a", 64)
      })

    assert %{"ok" => false, "error" => %{"code" => "lifecycle_forbidden"}} =
             json_response(register_conn, 403)
  end

  test "lifecycle vesting rejects signed-in wrong-wallet access", %{
    conn: conn,
    wrong_human: wrong_human
  } do
    conn = signed_in_conn(conn, wrong_human)
    vesting_conn = get(conn, lifecycle_vesting_path("job_alpha"))

    assert %{"ok" => false, "error" => %{"code" => "lifecycle_forbidden"}} =
             json_response(vesting_conn, 403)
  end

  test "lifecycle summary returns not found for a signed-in owner when the job is missing", %{
    conn: conn,
    human: human
  } do
    conn = signed_in_conn(conn, human)
    summary_conn = get(conn, lifecycle_job_path("job_missing"))

    assert %{"ok" => false, "error" => %{"code" => "lifecycle_not_found"}} =
             json_response(summary_conn, 404)
  end

  test "lifecycle finalize prepare returns not found for a signed-in owner when the job is missing",
       %{conn: conn, human: human} do
    conn = signed_in_conn(conn, human)
    prepare_conn = post(conn, lifecycle_finalize_prepare_path("job_missing"), %{})

    assert %{"ok" => false, "error" => %{"code" => "lifecycle_not_found"}} =
             json_response(prepare_conn, 404)
  end

  test "lifecycle finalize register returns not found for a signed-in owner when the job is missing",
       %{conn: conn, human: human} do
    conn = signed_in_conn(conn, human)

    register_conn =
      post(conn, lifecycle_finalize_register_path("job_missing"), %{
        "tx_hash" => "0x" <> String.duplicate("a", 64)
      })

    assert %{"ok" => false, "error" => %{"code" => "lifecycle_not_found"}} =
             json_response(register_conn, 404)
  end

  test "lifecycle vesting returns not found for a signed-in owner when the job is missing", %{
    conn: conn,
    human: human
  } do
    conn = signed_in_conn(conn, human)
    vesting_conn = get(conn, lifecycle_vesting_path("job_missing"))

    assert %{"ok" => false, "error" => %{"code" => "lifecycle_not_found"}} =
             json_response(vesting_conn, 404)
  end

  test "lifecycle summary returns data for the signed-in owner", %{conn: conn, human: human} do
    conn = signed_in_conn(conn, human)
    conn = get(conn, lifecycle_job_path("job_alpha"))

    assert %{
             "ok" => true,
             "job" => %{"job_id" => "job_alpha"},
             "recommended_action" => "migrate",
             "migrate_ready" => true
           } = json_response(conn, 200)
  end

  test "lifecycle finalize prepare returns a prepared payload for the signed-in owner", %{
    conn: conn,
    human: human
  } do
    conn = signed_in_conn(conn, human)
    conn = post(conn, lifecycle_finalize_prepare_path("job_alpha"), %{})

    assert %{
             "ok" => true,
             "prepared" => %{
               "resource" => "strategy",
               "action" => "migrate",
               "tx_request" => %{"data" => "0x8fd3ab80"}
             }
           } = json_response(conn, 200)
  end

  test "lifecycle finalize register returns a submitted hash for the signed-in owner", %{
    conn: conn,
    human: human
  } do
    conn = signed_in_conn(conn, human)

    conn =
      post(conn, lifecycle_finalize_register_path("job_alpha"), %{
        "tx_hash" => "0x" <> String.duplicate("a", 64)
      })

    assert %{
             "ok" => true,
             "status" => "submitted",
             "tx_hash" => "0x" <> _
           } = json_response(conn, 200)
  end

  test "lifecycle finalize register rejects malformed hashes for the signed-in owner", %{
    conn: conn,
    human: human
  } do
    conn = signed_in_conn(conn, human)

    conn =
      post(conn, lifecycle_finalize_register_path("job_alpha"), %{
        "tx_hash" => "not-a-valid-hash"
      })

    assert %{"ok" => false, "error" => %{"code" => "invalid_transaction_hash"}} =
             json_response(conn, 422)
  end

  test "lifecycle vesting returns data for the signed-in owner", %{conn: conn, human: human} do
    conn = signed_in_conn(conn, human)
    conn = get(conn, lifecycle_vesting_path("job_alpha"))

    assert %{
             "ok" => true,
             "job_id" => "job_alpha",
             "release_ready" => true,
             "releasable_launch_token" => 25
           } = json_response(conn, 200)
  end
end
