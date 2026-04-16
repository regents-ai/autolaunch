defmodule AutolaunchWeb.ContractsLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.Accounts

  defmodule ContextStub do
    def admin_overview do
      {:ok,
       %{
         dependencies: %{usdc_address: "0x1111111111111111111111111111111111111111"},
         admin_contracts: %{
           revenue_share_factory: %{address: "0x2222222222222222222222222222222222222222"},
           revenue_ingress_factory: %{address: "0x3333333333333333333333333333333333333333"},
           regent_lbp_strategy_factory: %{address: "0x4444444444444444444444444444444444444444"}
         }
       }}
    end

    def job_state("job_contracts", _human) do
      {:ok,
       %{
         job: %{
           job_id: "job_contracts",
           owner_address: "0x2222222222222222222222222222222222222222",
           token_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
         },
         controller: %{
           deploy_binary: "forge",
           deploy_workdir: "/tmp/contracts",
           script_target: "scripts/ExampleCCADeploymentScript.s.sol",
           deploy_tx_hash: "0x" <> String.duplicate("b", 64),
           result_addresses: %{
             strategy_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
             pool_id: "0x" <> String.duplicate("c", 64)
           }
         },
         strategy: %{
           address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
           auction_address: "0xcccccccccccccccccccccccccccccccccccccccc",
           migrated: false,
           migrated_pool_id: "0x" <> String.duplicate("d", 64),
           migrated_position_id: 0,
           migrated_liquidity: 0,
           migrated_currency_for_lp: 0,
           migrated_token_for_lp: 0
         },
         vesting: %{
           address: "0xdddddddddddddddddddddddddddddddddddddddd",
           beneficiary: "0x1111111111111111111111111111111111111111",
           pending_beneficiary: nil,
           pending_beneficiary_eta: 0,
           rotation_delay: 259_200,
           releasable_launch_token: 0
         },
         fee_registry: %{
           address: "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
           pool_id: "0x" <> String.duplicate("f", 64),
           pool_config: %{
             hook_enabled: true,
             pool_fee: 10_000,
             tick_spacing: 60,
             treasury: "0x1111111111111111111111111111111111111111",
             regent_recipient: "0x2222222222222222222222222222222222222222"
           }
         },
         fee_vault: %{
           address: "0xffffffffffffffffffffffffffffffffffffffff",
           hook: "0x1212121212121212121212121212121212121212",
           treasury_accrued: %{token: 1, usdc: 2},
           regent_accrued: %{token: 3, usdc: 4}
         },
         hook: %{
           address: "0x3434343434343434343434343434343434343434",
           pool_id: "0x" <> String.duplicate("e", 64)
         }
       }}
    end

    def job_state(_job_id, _human), do: {:error, :not_found}

    def subject_state(subject_id, _human) do
      {:ok,
       %{
         subject: %{
           subject_id: String.downcase(subject_id),
           splitter_address: "0x9999999999999999999999999999999999999999",
           default_ingress_address: "0x8888888888888888888888888888888888888888",
           total_staked: "250",
           treasury_residual_usdc: "25",
           protocol_reserve_usdc: "10",
           can_manage_ingress: true,
           ingress_accounts: [
             %{
               address: "0x8888888888888888888888888888888888888888",
               usdc_balance: "7",
               is_default: true
             }
           ]
         },
         registry: %{
           address: "0x7777777777777777777777777777777777777777",
           owner: "0x6666666666666666666666666666666666666666",
           connected_wallet_can_manage: true,
           subject_config: %{
             splitter: "0x9999999999999999999999999999999999999999",
             treasury_safe: "0x5555555555555555555555555555555555555555",
             active: true,
             label: "Atlas"
           },
           identity_links: [
             %{
               chain_id: 11_155_111,
               registry: "0x4444444444444444444444444444444444444444",
               agent_id: 42
             }
           ]
         },
         splitter: %{
           owner: "0x3333333333333333333333333333333333333333",
           paused: false,
           treasury_recipient: "0x2222222222222222222222222222222222222222",
           pending_treasury_recipient: nil,
           pending_treasury_recipient_eta: 0,
           treasury_rotation_delay: 259_200,
           protocol_recipient: "0x1111111111111111111111111111111111111111",
           protocol_skim_bps: 100,
           label: "Atlas revenue"
         },
         ingress_factory: %{
           address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
           owner: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
           default_ingress_address: "0x8888888888888888888888888888888888888888",
           ingress_account_count: 1
         },
         revenue_share_factory: %{
           address: "0xcccccccccccccccccccccccccccccccccccccccc",
           owner: "0xdddddddddddddddddddddddddddddddddddddddd"
         }
       }}
    end

    def prepare_job_action("job_contracts", "strategy", "migrate", _attrs, _human) do
      {:ok,
       %{
         job_id: "job_contracts",
         prepared: %{
           resource: "strategy",
           action: "migrate",
           chain_id: 11_155_111,
           target: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
           calldata: "0x8fd3ab80",
           tx_request: %{
             chain_id: 11_155_111,
             to: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
             value: "0x0",
             data: "0x8fd3ab80"
           },
           submission_mode: "prepare_only"
         }
       }}
    end

    def prepare_subject_action(_subject_id, "splitter", "set_paused", _attrs, _human) do
      {:ok,
       %{
         subject_id: "0x" <> String.duplicate("1a", 32),
         prepared: %{
           resource: "splitter",
           action: "set_paused",
           chain_id: 11_155_111,
           target: "0x9999999999999999999999999999999999999999",
           calldata: "0x16c38b3c",
           tx_request: %{
             chain_id: 11_155_111,
             to: "0x9999999999999999999999999999999999999999",
             value: "0x0",
             data: "0x16c38b3c"
           },
           submission_mode: "prepare_only"
         }
       }}
    end

    def prepare_admin_action("revenue_share_factory", "set_authorized_creator", _attrs) do
      {:ok,
       %{
         prepared: %{
           resource: "revenue_share_factory",
           action: "set_authorized_creator",
           chain_id: 11_155_111,
           target: "0x2222222222222222222222222222222222222222",
           calldata: "0xe1434f4e",
           tx_request: %{
             chain_id: 11_155_111,
             to: "0x2222222222222222222222222222222222222222",
             value: "0x0",
             data: "0xe1434f4e"
           },
           submission_mode: "prepare_only"
         }
       }}
    end
  end

  setup do
    original = Application.get_env(:autolaunch, :contracts_live, [])
    Application.put_env(:autolaunch, :contracts_live, context_module: ContextStub)
    on_exit(fn -> Application.put_env(:autolaunch, :contracts_live, original) end)
    :ok
  end

  test "contracts page renders both job and subject scopes", %{conn: conn} do
    {:ok, _view, html} =
      live(
        conn,
        "/contracts?job_id=job_contracts&subject_id=0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
      )

    assert html =~ "Pick the contract view you need before you review or prepare anything."
    assert html =~ "Open one launch job"
    assert html =~ "Open one subject"

    assert html =~ "Review mode"
    assert html =~ "LBP runtime state"
    assert html =~ "Advanced revenue controls"
    assert html =~ "Prepared action"
  end

  test "contracts page prompts for the linked owner wallet when a different linked wallet is active",
       %{conn: conn} do
    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:contracts-wallet-switch", %{
        "wallet_address" => "0x1111111111111111111111111111111111111111",
        "wallet_addresses" => [
          "0x1111111111111111111111111111111111111111",
          "0x2222222222222222222222222222222222222222"
        ],
        "display_name" => "Contracts Operator"
      })

    conn = init_test_session(conn, privy_user_id: human.privy_user_id)

    {:ok, _view, html} = live(conn, "/contracts?job_id=job_contracts")

    assert html =~ "Wallet required"
    assert html =~ "This page belongs to a different linked wallet."
    assert html =~ "Switch wallets in your browser wallet, then continue here."
  end

  test "contracts page prepares transaction payloads", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/contracts?job_id=job_contracts")

    html =
      view
      |> element("button[phx-value-resource='strategy'][phx-value-action='migrate']")
      |> render_click()

    assert html =~ "migrate"
    assert html =~ "0x8fd3ab80"
    assert html =~ "Copy tx JSON"
  end
end
