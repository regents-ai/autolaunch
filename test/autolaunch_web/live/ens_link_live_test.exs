defmodule AutolaunchWeb.EnsLinkLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.Accounts

  defmodule LaunchStub do
    def list_agents(_human) do
      [
        %{
          agent_id: "84532:42",
          id: "84532:42",
          name: "Atlas",
          state: "eligible",
          access_mode: "owner",
          owner_address: "0x1111111111111111111111111111111111111111",
          supported_chains: [%{id: 84_532, label: "Base Sepolia"}],
          chain_id: 84_532,
          ens: nil
        }
      ]
    end
  end

  defmodule EnsLinkStub do
    def prepare_bidirectional_link(_human, %{
          "identity_id" => "84532:42",
          "ens_name" => "atlas.eth"
        }) do
      {:ok,
       %{
         plan: %{
           normalized_ens_name: "atlas.eth",
           ensip25_key: "agent-registration[test][42]",
           verify_status: :ens_record_missing,
           erc8004_status: :ens_service_missing,
           ens_write_status: :ready,
           erc8004_write_status: :ready,
           ens_manager: "0x1111111111111111111111111111111111111111",
           ens_manager_source: :registry_owner,
           signer_address: "0x1111111111111111111111111111111111111111",
           warnings: [],
           actions: [
             %{
               kind: :update_erc8004_registration,
               status: :ready,
               description: "Update the ERC-8004 registration file"
             },
             %{kind: :set_ens_text, status: :ready, description: "Set the ENSIP-25 text record"},
             %{kind: :set_reverse_name, status: :skipped, description: "Set the reverse name"}
           ]
         },
         erc8004: %{
           tx: %{
             chain_id: 84_532,
             to: "0x2222222222222222222222222222222222222222",
             data: "0xabc",
             value: "0x0"
           }
         },
         ensip25: %{
           tx: %{
             chain_id: 84_532,
             to: "0x3333333333333333333333333333333333333333",
             data: "0xdef",
             value: "0x0"
           }
         },
         reverse: :skipped
       }}
    end
  end

  setup do
    original = Application.get_env(:autolaunch, :ens_link_live, [])

    Application.put_env(:autolaunch, :ens_link_live,
      launch_module: LaunchStub,
      ens_link_module: EnsLinkStub
    )

    on_exit(fn -> Application.put_env(:autolaunch, :ens_link_live, original) end)
    :ok
  end

  test "guest sees sign-in copy", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/ens-link")

    assert html =~ "Choose an identity, choose an ENS name, then send only the missing writes."
    assert html =~ "Sign in with Privy before planning ENS links."
  end

  test "signed-in human can plan ENS link actions", %{conn: conn} do
    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:ens-live", %{
        "wallet_address" => "0x1111111111111111111111111111111111111111",
        "wallet_addresses" => ["0x1111111111111111111111111111111111111111"],
        "display_name" => "ENS Operator"
      })

    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/ens-link")

    view
    |> form("form", %{"ens_link" => %{"ens_name" => "atlas.eth"}})
    |> render_change()

    html =
      view
      |> element("form")
      |> render_submit()

    assert html =~ "Current link state"
    assert html =~ "agent-registration[test][42]"
    assert html =~ "Send from wallet"
  end

  test "launch follow-up query preloads the selected identity and ENS name", %{conn: conn} do
    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:ens-followup", %{
        "wallet_address" => "0x1111111111111111111111111111111111111111",
        "wallet_addresses" => ["0x1111111111111111111111111111111111111111"],
        "display_name" => "ENS Operator"
      })

    conn = init_test_session(conn, privy_user_id: human.privy_user_id)

    {:ok, _view, html} = live(conn, "/ens-link?identity_id=84532:42&ens_name=atlas.eth")

    assert html =~ "atlas.eth"
    assert html =~ "Launch follow-up"
    assert html =~ "Selected"
  end
end
