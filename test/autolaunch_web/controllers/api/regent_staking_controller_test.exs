defmodule AutolaunchWeb.Api.RegentStakingControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  defmodule RegentStakingStub do
    def overview(_human) do
      {:ok,
       %{
         chain_id: 84_532,
         contract_address: "0x9999999999999999999999999999999999999999",
         treasury_residual_usdc: "150"
       }}
    end

    def account(address, _human) do
      {:ok, %{wallet_address: String.downcase(address), wallet_claimable_usdc: "12"}}
    end

    def stake(%{"amount" => "1.5"}, _human) do
      {:ok,
       %{
         tx_request: %{
           chain_id: 84_532,
           to: "0x9999999999999999999999999999999999999999",
           value: "0x0",
           data: "0x7acb7757"
         }
       }}
    end

    def stake(_params, _human), do: {:error, :amount_required}

    def unstake(_params, _human) do
      {:ok,
       %{
         tx_request: %{
           chain_id: 84_532,
           to: "0x9999999999999999999999999999999999999999",
           value: "0x0",
           data: "0x8381e182"
         }
       }}
    end

    def claim_usdc(_params, _human) do
      {:ok,
       %{
         tx_request: %{
           chain_id: 84_532,
           to: "0x9999999999999999999999999999999999999999",
           value: "0x0",
           data: "0x42852610"
         }
       }}
    end

    def prepare_deposit_usdc(_params) do
      {:ok,
       %{
         prepared: %{
           action: "deposit_usdc",
           tx_request: %{
             chain_id: 84_532,
             to: "0x9999999999999999999999999999999999999999",
             value: "0x0",
             data: "0x7dc6bb98"
           }
         }
       }}
    end

    def prepare_withdraw_treasury(_params) do
      {:ok,
       %{
         prepared: %{
           action: "withdraw_treasury",
           tx_request: %{
             chain_id: 84_532,
             to: "0x9999999999999999999999999999999999999999",
             value: "0x0",
             data: "0xe13b5822"
           }
         }
       }}
    end
  end

  setup do
    original = Application.get_env(:autolaunch, :regent_staking_api, [])
    Application.put_env(:autolaunch, :regent_staking_api, context_module: RegentStakingStub)
    on_exit(fn -> Application.put_env(:autolaunch, :regent_staking_api, original) end)
    :ok
  end

  test "show returns the regent staking overview", %{conn: conn} do
    conn = get(conn, "/v1/app/regent/staking")

    assert %{
             "ok" => true,
             "chain_id" => 84_532,
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

  test "stake returns a wallet tx request", %{conn: conn} do
    conn = post(conn, "/v1/app/regent/staking/stake", %{"amount" => "1.5"})

    assert %{
             "ok" => true,
             "tx_request" => %{"chain_id" => 84_532, "data" => "0x7acb7757"}
           } = json_response(conn, 200)
  end

  test "deposit prepare returns a multisig payload", %{conn: conn} do
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
               "tx_request" => %{"data" => "0x7dc6bb98"}
             }
           } = json_response(conn, 200)
  end
end
