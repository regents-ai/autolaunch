defmodule AutolaunchWeb.RegentStakingLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.Accounts

  defmodule StakingStub do
    def overview(_human) do
      {:ok, state()}
    end

    def account("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266", _human) do
      {:ok,
       Map.merge(state(), %{
         wallet_address: "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
         wallet_stake_balance_raw: 2_600_000 * 1_000_000_000_000_000_000,
         wallet_stake_balance: "2600000",
         wallet_token_balance_raw: 5_000_000 * 1_000_000_000_000_000_000,
         wallet_token_balance: "5000000",
         wallet_claimable_usdc_raw: 7_000_000,
         wallet_claimable_usdc: "7",
         wallet_claimable_regent_raw: 8 * 1_000_000_000_000_000_000,
         wallet_claimable_regent: "8"
       })}
    end

    def account(_address, _human), do: {:ok, state()}

    def state do
      %{
        chain_id: 8453,
        chain_label: "Base",
        contract_address: "0x9999999999999999999999999999999999999999",
        owner_address: "0x1111111111111111111111111111111111111111",
        stake_token_address: "0x2222222222222222222222222222222222222222",
        usdc_address: "0x3333333333333333333333333333333333333333",
        treasury_recipient: "0x4444444444444444444444444444444444444444",
        revenue_share_supply_denominator: "100000000000",
        paused: false,
        total_staked_raw: 12_345 * 1_000_000_000_000_000_000,
        total_staked: "12345",
        total_usdc_received_raw: 500_000_000,
        total_usdc_received: "500",
        direct_deposit_usdc_raw: 500_000_000,
        direct_deposit_usdc: "500",
        treasury_residual_usdc_raw: 50_000_000,
        treasury_residual_usdc: "50",
        materialized_outstanding_raw: 10 * 1_000_000_000_000_000_000,
        materialized_outstanding: "10",
        available_reward_inventory_raw: 200 * 1_000_000_000_000_000_000,
        available_reward_inventory: "200",
        total_claimed_so_far_raw: 25 * 1_000_000_000_000_000_000,
        total_claimed_so_far: "25",
        wallet_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        wallet_stake_balance_raw: 12 * 1_000_000_000_000_000_000,
        wallet_stake_balance: "12",
        wallet_token_balance_raw: 90 * 1_000_000_000_000_000_000,
        wallet_token_balance: "90",
        wallet_claimable_usdc_raw: 5_000_000,
        wallet_claimable_usdc: "5",
        wallet_claimable_regent_raw: 3 * 1_000_000_000_000_000_000,
        wallet_claimable_regent: "3",
        wallet_funded_claimable_regent_raw: 2 * 1_000_000_000_000_000_000,
        wallet_funded_claimable_regent: "2"
      }
    end

    def stake(%{"amount" => "1.5", "receiver" => ""}, _human), do: tx("0xstake")

    def stake(
          %{"amount" => "1.5", "receiver" => "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
          _human
        ),
        do: tx("0xstakeforreceiver")

    def unstake(%{"amount" => "1.0"}, _human), do: tx("0xunstake")
    def claim_usdc(_attrs, _human), do: tx("0xclaimusdc")
    def claim_regent(_attrs, _human), do: tx("0xclaimregent")
    def claim_and_restake_regent(_attrs, _human), do: tx("0xrestake")

    defp tx(data) do
      {:ok,
       %{
         prepared: %{
           wallet_action: %{
             chain_id: 8453,
             to: "0x9999999999999999999999999999999999999999",
             value: "0x0",
             data: data,
             expected_signer: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
           }
         }
       }}
    end
  end

  defmodule ZeroBalanceStakingStub do
    def overview(_human) do
      {:ok,
       Map.merge(StakingStub.state(), %{
         wallet_stake_balance_raw: 0,
         wallet_stake_balance: "0",
         wallet_token_balance_raw: 0,
         wallet_token_balance: "0",
         wallet_claimable_usdc_raw: 0,
         wallet_claimable_usdc: "0",
         wallet_claimable_regent_raw: 0,
         wallet_claimable_regent: "0",
         wallet_funded_claimable_regent_raw: 0,
         wallet_funded_claimable_regent: "0"
       })}
    end

    def account(_address, human), do: overview(human)
  end

  setup do
    original = Application.get_env(:autolaunch, :regent_staking_live, [])
    Application.put_env(:autolaunch, :regent_staking_live, context_module: StakingStub)

    on_exit(fn ->
      Application.put_env(:autolaunch, :regent_staking_live, original)
    end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:regent-staking-live", %{
        "wallet_address" => "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "wallet_addresses" => ["0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
        "display_name" => "Operator"
      })

    %{human: human}
  end

  test "renders the Regent staking page", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, _view, html} = live(conn, "/regent-staking")

    assert html =~ "$REGENT staking"
    assert html =~ "Stake and earn your slice of all Regents revenue"
    assert html =~ "The remainder goes to buy back the token."
    assert html =~ "Stake $REGENT and withdraw anytime."
    assert html =~ "Earn a pro-rata share of USDC the Regents Protocol makes across all apps."
    assert html =~ "Earn 20% bonus $REGENT on your stake in the first year."
    assert html =~ "Total staked"
    assert html =~ "Wallet balance"
    assert html =~ "Stake on Autolaunch"
    assert html =~ "Claim USDC"
    assert html =~ "Claim REGENT"
    assert html =~ "Unstake"
    assert html =~ "data-tooltip=\"12345 REGENT\""
    assert html =~ "data-tooltip=\"5 USDC\""
    refute html =~ "Direct deposits"
    refute html =~ "Stake $REGENT, claim USDC from the Regent rewards pool"
    refute html =~ "Prepare USDC deposit"
    refute html =~ "Prepare treasury withdrawal"
    refute html =~ "USDC deposit amount"
  end

  test "prepares wallet actions", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/regent-staking")

    html =
      view
      |> form("#regent-staking-form", %{"staking" => %{"amount" => "1.5"}})
      |> render_change()

    assert html =~ "Stake on Autolaunch"

    html =
      view
      |> element("#regent-stake-button")
      |> render_click()

    assert html =~ "Open your wallet to confirm the staking transaction."

    html =
      view
      |> element("#regent-claim-usdc-button")
      |> render_click()

    assert html =~ "Open your wallet to confirm the USDC claim."

    view
    |> form("#regent-staking-form", %{"staking" => %{"amount" => "1.0"}})
    |> render_change()

    html =
      view
      |> element("#regent-unstake-button")
      |> render_click()

    assert html =~ "Open your wallet to confirm the unstake transaction."
  end

  test "prepares stake for another wallet", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/regent-staking")

    html =
      view
      |> form("#regent-staking-form", %{
        "staking" => %{
          "amount" => "1.5",
          "stake_for_different_address" => "true"
        }
      })
      |> render_change()

    assert html =~ "Receiving wallet"

    html =
      view
      |> form("#regent-staking-form", %{
        "staking" => %{
          "amount" => "1.5",
          "stake_for_different_address" => "true",
          "receiver" => "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        }
      })
      |> render_change()

    assert html =~ "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    html =
      view
      |> element("#regent-stake-button")
      |> render_click()

    assert html =~ "Open your wallet to confirm the staking transaction."
  end

  test "anonymous visitors are sent to wallet connection", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/regent-staking")

    assert has_element?(view, "#regent-staking-connect", "Connect wallet")
    refute has_element?(view, "#regent-stake-button", "Connect wallet")
    refute has_element?(view, "#regent-claim-usdc-button", "Connect wallet")
    refute has_element?(view, "#regent-unstake-button", "Connect wallet")
    assert has_element?(view, "#regent-stake-button[disabled]")
    assert has_element?(view, "#regent-claim-usdc-button[disabled]")
    assert has_element?(view, "#regent-unstake-button[disabled]")
    refute has_element?(view, "#regent-deposit-usdc")
    refute has_element?(view, "#regent-withdraw-treasury")
  end

  test "wallet connection reloads balances for the connected wallet", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, html} = live(conn, "/regent-staking")

    assert html =~ "12"

    html =
      render_hook(view, "wallet_connected", %{
        "wallet_address" => "0xF39fD6e51AaD88F6F4cE6aB8827279cffFb92266"
      })

    assert html =~ "2.6M"
    assert html =~ "5M"
  end

  test "staking for a different address disables non-stake actions", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/regent-staking")

    refute has_element?(view, "#regent-stake-button[disabled]")
    refute has_element?(view, "#regent-unstake-button[disabled]")
    refute has_element?(view, "#regent-claim-usdc-button[disabled]")
    refute has_element?(view, "#regent-claim-regent-button[disabled]")
    refute has_element?(view, "#regent-restake-button[disabled]")

    view
    |> form("#regent-staking-form", %{
      "staking" => %{
        "amount" => "1.5",
        "stake_for_different_address" => "true"
      }
    })
    |> render_change()

    refute has_element?(view, "#regent-stake-button[disabled]")
    assert has_element?(view, "#regent-unstake-button[disabled]")
    assert has_element?(view, "#regent-claim-usdc-button[disabled]")
    assert has_element?(view, "#regent-claim-regent-button[disabled]")
    assert has_element?(view, "#regent-restake-button[disabled]")
  end

  test "successful staking transactions refresh balances after confirmation", %{
    conn: conn,
    human: human
  } do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/regent-staking")

    html = render_hook(view, "staking_tx_complete", %{"action" => "stake"})

    assert html =~ "Stake sent. Refreshing your staking snapshot."
    assert has_element?(view, ".al-regent-refresh-button.is-refreshing")

    Process.sleep(2_350)

    html = render(view)
    assert html =~ "Balances refreshed."
    refute has_element?(view, ".al-regent-refresh-button.is-refreshing")
  end

  test "staking transaction failures show the wallet error", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/regent-staking")

    html = render_hook(view, "staking_tx_failed", %{"message" => "Wallet rejected the request."})

    assert html =~ "Wallet rejected the request."
  end

  test "zero-balance staking actions are disabled", %{conn: conn, human: human} do
    Application.put_env(:autolaunch, :regent_staking_live, context_module: ZeroBalanceStakingStub)

    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/regent-staking")

    assert has_element?(view, "#regent-stake-button[disabled]")
    assert has_element?(view, "#regent-claim-usdc-button[disabled]")
    assert has_element?(view, "#regent-claim-regent-button[disabled]")
    assert has_element?(view, "#regent-restake-button[disabled]")
    assert has_element?(view, "#regent-unstake-button[disabled]")
  end
end
