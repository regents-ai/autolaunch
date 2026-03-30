defmodule AutolaunchWeb.Api.SubjectControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Launch.Job
  alias Autolaunch.Repo

  @subject_id "0x" <> String.duplicate("1a", 32)
  @splitter "0x9999999999999999999999999999999999999999"
  @token "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  @wallet "0x1111111111111111111111111111111111111111"

  setup %{conn: conn} do
    previous_adapter = Application.get_env(:autolaunch, :cca_rpc_adapter)
    previous_launch = Application.get_env(:autolaunch, :launch, [])

    Application.put_env(:autolaunch, :cca_rpc_adapter, Autolaunch.RevenueTest.FakeRpc)

    Application.put_env(
      :autolaunch,
      :launch,
      Keyword.put(
        previous_launch,
        :revenue_ingress_factory_address,
        "0x2222222222222222222222222222222222222222"
      )
    )

    on_exit(fn ->
      if previous_adapter do
        Application.put_env(:autolaunch, :cca_rpc_adapter, previous_adapter)
      else
        Application.delete_env(:autolaunch, :cca_rpc_adapter)
      end

      Application.put_env(:autolaunch, :launch, previous_launch)
    end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:subject-controller", %{
        "wallet_address" => @wallet,
        "wallet_addresses" => [@wallet],
        "display_name" => "Operator"
      })

    now = DateTime.utc_now()

    {:ok, job} =
      %Job{}
      |> Job.create_changeset(%{
        job_id: "job_subject_controller",
        owner_address: @wallet,
        agent_id: "11155111:42",
        token_name: "Atlas Coin",
        token_symbol: "ATLAS",
        recovery_safe_address: @wallet,
        auction_proceeds_recipient: @wallet,
        ethereum_revenue_treasury: @wallet,
        network: "ethereum-sepolia",
        chain_id: 11_155_111,
        status: "ready",
        step: "ready",
        total_supply: "1000",
        message: "signed",
        siwa_nonce: "nonce",
        siwa_signature: "sig",
        issued_at: now
      })
      |> Repo.insert()

    job
    |> Job.update_changeset(%{
      token_address: @token,
      strategy_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      subject_registry_address: "0x3333333333333333333333333333333333333333",
      revenue_share_splitter_address: @splitter,
      default_ingress_address: "0x7777777777777777777777777777777777777777",
      subject_id: @subject_id
    })
    |> Repo.update!()

    %{conn: init_test_session(conn, privy_user_id: human.privy_user_id), human: human}
  end

  test "show returns subject state", %{conn: conn} do
    conn = get(conn, "/api/subjects/#{@subject_id}")
    assert %{"ok" => true, "subject" => %{"subject_id" => @subject_id}} = json_response(conn, 200)
  end

  test "show accepts uppercase subject ids", %{conn: conn} do
    upper_subject_id = "0x" <> String.upcase(String.slice(@subject_id, 2..-1//1))

    conn = get(conn, "/api/subjects/#{upper_subject_id}")

    assert %{"ok" => true, "subject" => %{"subject_id" => @subject_id}} = json_response(conn, 200)
  end

  test "ingress returns subject ingress state", %{conn: conn} do
    conn = get(conn, "/api/subjects/#{@subject_id}/ingress")

    assert %{
             "ok" => true,
             "subject_id" => @subject_id,
             "default_ingress_address" => "0x7777777777777777777777777777777777777777",
             "can_manage_ingress" => true,
             "accounts" => [
               %{
                 "address" => "0x7777777777777777777777777777777777777777",
                 "is_default" => true,
                 "usdc_balance" => "7",
                 "usdc_balance_raw" => 7_000_000
               }
             ]
           } = json_response(conn, 200)
  end

  test "stake requires auth", %{conn: conn} do
    conn = delete_session(conn, :privy_user_id)
    conn = post(conn, "/api/subjects/#{@subject_id}/stake", %{"amount" => "1.0"})
    assert %{"ok" => false, "error" => %{"code" => "auth_required"}} = json_response(conn, 401)
  end

  test "stake returns canonical tx request", %{conn: conn} do
    conn = post(conn, "/api/subjects/#{@subject_id}/stake", %{"amount" => "1.5"})

    assert %{
             "ok" => true,
             "tx_request" => %{
               "chain_id" => 11_155_111,
               "to" => @splitter,
               "data" => data
             }
           } = json_response(conn, 200)

    assert String.starts_with?(data, "0x7acb7757")
  end

  test "stake with tx hash requires amount", %{conn: conn} do
    conn =
      post(conn, "/api/subjects/#{@subject_id}/stake", %{
        "tx_hash" => "0x" <> String.duplicate("b", 64)
      })

    assert %{"ok" => false, "error" => %{"code" => "amount_required"}} = json_response(conn, 422)
  end

  test "stake selector mismatch returns transaction_data_mismatch", %{conn: conn} do
    tx_hash = "0x" <> String.duplicate("c", 64)

    Process.put(:fake_rpc_transaction, %{
      transaction_hash: tx_hash,
      from: @wallet,
      to: @splitter,
      input: Autolaunch.Revenue.Abi.encode_claim_usdc(@wallet),
      value: "0x0",
      block_number: nil
    })

    Process.put(:fake_rpc_receipt, nil)

    conn =
      post(conn, "/api/subjects/#{@subject_id}/stake", %{
        "amount" => "1.5",
        "tx_hash" => tx_hash
      })

    assert %{"ok" => false, "error" => %{"code" => "transaction_data_mismatch"}} =
             json_response(conn, 422)
  end

  test "same tx hash on a different action is rejected", %{conn: conn} do
    tx_hash = "0x" <> String.duplicate("d", 64)

    Process.put(:fake_rpc_transaction, %{
      transaction_hash: tx_hash,
      from: @wallet,
      to: @splitter,
      input: Autolaunch.Revenue.Abi.encode_stake(1_500_000_000_000_000_000, @wallet),
      value: "0x0",
      block_number: nil
    })

    Process.put(:fake_rpc_receipt, nil)

    conn =
      post(conn, "/api/subjects/#{@subject_id}/stake", %{
        "amount" => "1.5",
        "tx_hash" => tx_hash
      })

    assert %{"ok" => false, "error" => %{"code" => "transaction_pending"}} =
             json_response(conn, 202)

    conn = post(conn, "/api/subjects/#{@subject_id}/claim-usdc", %{"tx_hash" => tx_hash})

    assert %{"ok" => false, "error" => %{"code" => "transaction_hash_reused"}} =
             json_response(conn, 409)
  end

  test "unstake accepts a confirmed tx hash", %{conn: conn} do
    tx_hash = "0x" <> String.duplicate("b", 64)

    Process.put(:fake_rpc_transaction, %{
      transaction_hash: tx_hash,
      from: @wallet,
      to: @splitter,
      input: Autolaunch.Revenue.Abi.encode_unstake(250_000_000_000_000_000, @wallet),
      value: "0x0",
      block_number: nil
    })

    Process.put(:fake_rpc_receipt, %{
      transaction_hash: tx_hash,
      status: 1,
      from: @wallet,
      to: @splitter,
      logs: []
    })

    conn =
      post(conn, "/api/subjects/#{@subject_id}/unstake", %{
        "amount" => "0.25",
        "tx_hash" => tx_hash
      })

    assert %{"ok" => true, "subject" => %{"subject_id" => @subject_id}} = json_response(conn, 200)
  end

  test "claim-usdc accepts a confirmed tx hash", %{conn: conn} do
    tx_hash = "0x" <> String.duplicate("a", 64)

    Process.put(:fake_rpc_transaction, %{
      transaction_hash: tx_hash,
      from: @wallet,
      to: @splitter,
      input: Autolaunch.Revenue.Abi.encode_claim_usdc(@wallet),
      value: "0x0",
      block_number: nil
    })

    Process.put(:fake_rpc_receipt, %{
      transaction_hash: tx_hash,
      status: 1,
      from: @wallet,
      to: @splitter,
      logs: []
    })

    conn =
      post(conn, "/api/subjects/#{@subject_id}/claim-usdc", %{
        "tx_hash" => tx_hash
      })

    assert %{"ok" => true, "subject" => %{"subject_id" => @subject_id}} = json_response(conn, 200)
  end

  test "sweep-ingress accepts a confirmed tx hash", %{conn: conn} do
    tx_hash = "0x" <> String.duplicate("c", 64)

    Process.put(:fake_rpc_transaction, %{
      transaction_hash: tx_hash,
      from: @wallet,
      to: "0x7777777777777777777777777777777777777777",
      input: Autolaunch.Revenue.Abi.encode_sweep_usdc(@subject_id),
      value: "0x0",
      block_number: nil
    })

    Process.put(:fake_rpc_receipt, %{
      transaction_hash: tx_hash,
      status: 1,
      from: @wallet,
      to: "0x7777777777777777777777777777777777777777",
      logs: []
    })

    conn =
      post(
        conn,
        "/api/subjects/#{@subject_id}/ingress/0x7777777777777777777777777777777777777777/sweep",
        %{
          "tx_hash" => tx_hash
        }
      )

    assert %{"ok" => true, "subject" => %{"subject_id" => @subject_id}} = json_response(conn, 200)
  end

  test "malformed tx hashes are rejected", %{conn: conn} do
    conn =
      post(conn, "/api/subjects/#{@subject_id}/stake", %{
        "amount" => "1.0",
        "tx_hash" => "bad-hash"
      })

    assert %{"ok" => false, "error" => %{"code" => "invalid_transaction_hash"}} =
             json_response(conn, 422)
  end
end
