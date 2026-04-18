defmodule AutolaunchWeb.SubjectLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.Accounts

  @subject_id "0x" <> String.duplicate("1a", 32)

  defmodule ContextStub do
    @subject_id "0x" <> String.duplicate("1a", 32)

    def get_subject(@subject_id, _human) do
      {:ok,
       %{
         subject_id: @subject_id,
         token_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
         splitter_address: "0x9999999999999999999999999999999999999999",
         default_ingress_address: "0x7777777777777777777777777777777777777777",
         treasury_residual_usdc: "25",
         protocol_reserve_usdc: "10",
         wallet_stake_balance: "12",
         wallet_token_balance: "90",
         claimable_usdc: "5",
         total_staked: "250",
         can_manage_ingress: true,
         ingress_accounts: [
           %{
             address: "0x7777777777777777777777777777777777777777",
             usdc_balance: "7",
             is_default: true
           }
         ]
       }}
    end

    def stake(@subject_id, %{"amount" => "1.5"}, _human) do
      {:ok,
       %{
         subject: get_subject(@subject_id, nil) |> elem(1),
         tx_request: %{
           chain_id: 84_532,
           to: "0x9999999999999999999999999999999999999999",
           value: "0x0",
           data: "0x7acb7757"
         }
       }}
    end

    def unstake(@subject_id, %{"amount" => "1.0"}, _human) do
      {:ok,
       %{
         subject: get_subject(@subject_id, nil) |> elem(1),
         tx_request: %{
           chain_id: 84_532,
           to: "0x9999999999999999999999999999999999999999",
           value: "0x0",
           data: "0x8381e182"
         }
       }}
    end

    def claim_usdc(@subject_id, _attrs, _human) do
      {:ok,
       %{
         subject: get_subject(@subject_id, nil) |> elem(1),
         tx_request: %{
           chain_id: 84_532,
           to: "0x9999999999999999999999999999999999999999",
           value: "0x0",
           data: "0x42852610"
         }
       }}
    end

    def sweep_ingress(@subject_id, "0x7777777777777777777777777777777777777777", _attrs, _human) do
      {:ok,
       %{
         subject: get_subject(@subject_id, nil) |> elem(1),
         tx_request: %{
           chain_id: 84_532,
           to: "0x7777777777777777777777777777777777777777",
           value: "0x0",
           data: "0xbe25fb30"
         }
       }}
    end
  end

  setup do
    original = Application.get_env(:autolaunch, :revenue_live, [])
    Application.put_env(:autolaunch, :revenue_live, context_module: ContextStub)
    on_exit(fn -> Application.put_env(:autolaunch, :revenue_live, original) end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:subject-live", %{
        "wallet_address" => "0x1111111111111111111111111111111111111111",
        "wallet_addresses" => ["0x1111111111111111111111111111111111111111"],
        "display_name" => "Operator"
      })

    %{human: human}
  end

  test "subject page renders splitter and ingress state", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, _view, html} = live(conn, "/subjects/#{@subject_id}")

    assert html =~ "See the revenue state, then take the one action that matters most."
    assert html =~ "Your staked tokens"
    assert html =~ "Wallet token balance"
    assert html =~ "Claimable USDC"
    assert html =~ "Primary next step"
    assert html =~ "Other actions"
    assert html =~ "Known USDC intake accounts"
    assert html =~ "Prepare USDC claim"
    assert html =~ "Open advanced contracts console"
  end

  test "subject page prepares wallet actions", %{conn: conn, human: human} do
    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/subjects/#{@subject_id}")

    html =
      view
      |> form("form[phx-change='stake_changed']", %{"stake" => %{"amount" => "1.5"}})
      |> render_change()

    assert html =~ "Prepare stake"
    assert html =~ "Wallet balance: 90"

    html =
      view
      |> element("button[phx-value-action='stake']")
      |> render_click()

    assert html =~ "Send stake transaction"
    assert html =~ ~s(data-register-body="{&quot;amount&quot;:&quot;1.5&quot;}")

    html =
      view
      |> form("form[phx-change='unstake_changed']", %{"unstake" => %{"amount" => "0.5"}})
      |> render_change()

    assert html =~ "Prepare unstake"

    html =
      view
      |> element("button[phx-value-action='claim']")
      |> render_click()

    assert html =~ "Send claim transaction"
  end
end
