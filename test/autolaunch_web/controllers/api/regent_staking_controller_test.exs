defmodule AutolaunchWeb.Api.RegentStakingControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts

  defmodule RegentStakingStub do
    def overview(_human) do
      {:ok,
       %{
         chain_id: 8_453,
         contract_address: "0x9999999999999999999999999999999999999999",
         treasury_residual_usdc: "150"
       }}
    end

    def account(address, _human) do
      {:ok, %{wallet_address: String.downcase(address), wallet_claimable_usdc: "12"}}
    end

    def stake(%{"amount" => "1.5"}, %{
          "wallet_address" => "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        }) do
      {:ok,
       %{
         prepared: prepared("stake", "0x7acb7757", "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
       }}
    end

    def stake(%{"amount" => "1.5", "receiver" => _receiver}, _human) do
      {:ok,
       %{
         prepared: prepared("stake", "0x7acb7757")
       }}
    end

    def stake(%{"amount" => "1.5"}, _human) do
      {:ok,
       %{
         prepared: prepared("stake", "0x7acb7757")
       }}
    end

    def stake(_params, _human), do: {:error, :amount_required}

    def unstake(_params, _human) do
      {:ok,
       %{
         prepared: prepared("unstake", "0x8381e182")
       }}
    end

    def claim_usdc(_params, _human) do
      {:ok,
       %{
         prepared: prepared("claim_usdc", "0x42852610")
       }}
    end

    def claim_regent(_params, _human), do: {:error, {:unexpected, "internal detail"}}

    def prepare_deposit_usdc(_params, operator_wallet_address) do
      {:ok,
       %{
         prepared: %{
           action_id: "prepared_deposit_usdc",
           owner_product: "autolaunch",
           resource: "regent_staking",
           resource_id: "0x9999999999999999999999999999999999999999",
           action: "deposit_usdc",
           chain_id: 8_453,
           expected_signer: operator_wallet_address,
           expires_at: "2999-01-01T00:00:00Z",
           idempotency_key: "prepared_deposit_usdc",
           risk_copy: "Deposits Base USDC into the Regent staking rail.",
           wallet_action: %{
             action_id: "prepared_deposit_usdc",
             owner_product: "autolaunch",
             resource: "regent_staking",
             resource_id: "0x9999999999999999999999999999999999999999",
             action: "deposit_usdc",
             chain_id: 8_453,
             to: "0x9999999999999999999999999999999999999999",
             value: "0",
             data: "0x7dc6bb98",
             expected_signer: operator_wallet_address,
             expires_at: "2999-01-01T00:00:00Z",
             idempotency_key: "prepared_deposit_usdc",
             simulation: %{required: false, status: "not_required", block_number: nil},
             risk_copy: "Deposits Base USDC into the Regent staking rail."
           }
         }
       }}
    end

    def prepare_withdraw_treasury(_params, operator_wallet_address) do
      {:ok,
       %{
         prepared: %{
           action_id: "prepared_withdraw_treasury",
           owner_product: "autolaunch",
           resource: "regent_staking",
           resource_id: "0x9999999999999999999999999999999999999999",
           action: "withdraw_treasury",
           chain_id: 8_453,
           expected_signer: operator_wallet_address,
           expires_at: "2999-01-01T00:00:00Z",
           idempotency_key: "prepared_withdraw_treasury",
           risk_copy:
             "Withdraws available Regent staking treasury USDC to the selected recipient.",
           wallet_action: %{
             action_id: "prepared_withdraw_treasury",
             owner_product: "autolaunch",
             resource: "regent_staking",
             resource_id: "0x9999999999999999999999999999999999999999",
             action: "withdraw_treasury",
             chain_id: 8_453,
             to: "0x9999999999999999999999999999999999999999",
             value: "0",
             data: "0xe13b5822",
             expected_signer: operator_wallet_address,
             expires_at: "2999-01-01T00:00:00Z",
             idempotency_key: "prepared_withdraw_treasury",
             simulation: %{required: false, status: "not_required", block_number: nil},
             risk_copy:
               "Withdraws available Regent staking treasury USDC to the selected recipient."
           }
         }
       }}
    end

    defp prepared(action, data, expected_signer \\ "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") do
      %{
        action_id: "prepared_#{action}",
        owner_product: "autolaunch",
        resource: "regent_staking",
        resource_id: "0x9999999999999999999999999999999999999999",
        action: action,
        chain_id: 8_453,
        expected_signer: expected_signer,
        expires_at: "2999-01-01T00:00:00Z",
        idempotency_key: "prepared_#{action}",
        risk_copy: "Review the wallet transaction before signing.",
        wallet_action: %{
          action_id: "prepared_#{action}",
          owner_product: "autolaunch",
          resource: "regent_staking",
          resource_id: "0x9999999999999999999999999999999999999999",
          action: action,
          chain_id: 8_453,
          to: "0x9999999999999999999999999999999999999999",
          value: "0",
          data: data,
          expected_signer: expected_signer,
          expires_at: "2999-01-01T00:00:00Z",
          idempotency_key: "prepared_#{action}",
          simulation: %{required: false, status: "not_required", block_number: nil},
          risk_copy: "Review the wallet transaction before signing."
        }
      }
    end
  end

  setup_all do
    original_siwa_cfg = Application.get_env(:autolaunch, :siwa, [])
    port = available_port()

    start_supervised!(
      {Bandit, plug: Autolaunch.TestSupport.SiwaBrokerStub, ip: {127, 0, 0, 1}, port: port}
    )

    Application.put_env(:autolaunch, :siwa,
      internal_url: "http://127.0.0.1:#{port}",
      http_connect_timeout_ms: 2_000,
      http_receive_timeout_ms: 5_000
    )

    on_exit(fn -> Application.put_env(:autolaunch, :siwa, original_siwa_cfg) end)

    :ok
  end

  setup do
    original = Application.get_env(:autolaunch, :regent_staking_api, [])
    original_staking = Application.get_env(:autolaunch, :regent_staking, [])

    Application.put_env(:autolaunch, :regent_staking_api, context_module: RegentStakingStub)

    Application.put_env(
      :autolaunch,
      :regent_staking,
      Keyword.put(original_staking, :operator_wallets, [
        "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      ])
    )

    on_exit(fn ->
      Application.put_env(:autolaunch, :regent_staking_api, original)
      Application.put_env(:autolaunch, :regent_staking, original_staking)
    end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:regent-staking-api", %{
        "wallet_address" => "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "wallet_addresses" => ["0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
        "display_name" => "Operator"
      })

    %{human: human}
  end

  test "show returns the regent staking overview", %{conn: conn} do
    conn = get(conn, "/v1/app/regent/staking")

    assert %{
             "ok" => true,
             "chain_id" => 8_453,
             "treasury_residual_usdc" => "150"
           } = json_response(conn, 200)
  end

  test "account returns account state", %{conn: conn} do
    conn = get(conn, "/v1/app/regent/staking/account/0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")

    assert %{
             "ok" => true,
             "wallet_address" => "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
             "wallet_claimable_usdc" => "12"
           } = json_response(conn, 200)
  end

  test "stake returns a prepared wallet action", %{conn: conn} do
    conn = post(conn, "/v1/app/regent/staking/stake", %{"amount" => "1.5"})

    assert %{
             "ok" => true,
             "prepared" => %{
               "expected_signer" => "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
               "idempotency_key" => "prepared_stake",
               "wallet_action" => %{"chain_id" => 8_453, "data" => "0x7acb7757"}
             }
           } = json_response(conn, 200)
  end

  test "stake accepts a receiving wallet", %{conn: conn} do
    receiver = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    conn =
      post(conn, "/v1/app/regent/staking/stake", %{"amount" => "1.5", "receiver" => receiver})

    assert %{
             "ok" => true,
             "prepared" => %{
               "expected_signer" => "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
               "wallet_action" => %{"data" => "0x7acb7757"}
             }
           } = json_response(conn, 200)
  end

  test "unknown API errors use stable public wording", %{conn: conn} do
    conn = post(conn, "/v1/app/regent/staking/claim-regent", %{})

    assert %{
             "ok" => false,
             "error" => %{
               "code" => "regent_staking_invalid",
               "message" => "Regent staking request could not be completed"
             }
           } = json_response(conn, 422)
  end

  test "deposit prepare requires a browser session", %{conn: conn} do
    conn =
      post(conn, "/v1/app/regent/staking/deposit-usdc/prepare", %{
        "amount" => "250.5",
        "source_tag" => "base_manual",
        "source_ref" => "2026-03"
      })

    assert %{"ok" => false, "error" => %{"code" => "auth_required"}} =
             json_response(conn, 401)
  end

  test "deposit prepare returns a multisig payload for a signed-in user", %{
    conn: conn,
    human: human
  } do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)

    conn =
      post(conn, "/v1/app/regent/staking/deposit-usdc/prepare", %{
        "amount" => "250.5",
        "source_tag" => "base_manual",
        "source_ref" => "2026-03"
      })

    assert %{
             "ok" => true,
             "prepared" => %{
               "action" => "deposit_usdc",
               "expected_signer" => "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
               "wallet_action" => %{"data" => "0x7dc6bb98"}
             }
           } = json_response(conn, 200)
  end

  test "deposit prepare requires an allowed operator wallet", %{conn: conn} do
    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:regent-staking-non-operator", %{
        "wallet_address" => "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "wallet_addresses" => ["0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],
        "display_name" => "Reader"
      })

    conn = init_test_session(conn, privy_user_id: human.privy_user_id)

    conn =
      post(conn, "/v1/app/regent/staking/deposit-usdc/prepare", %{
        "amount" => "250.5",
        "source_tag" => "base_manual",
        "source_ref" => "2026-03"
      })

    assert %{"ok" => false, "error" => %{"code" => "operator_required"}} =
             json_response(conn, 403)
  end

  defp available_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
