defmodule AutolaunchWeb.SurfaceLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.Accounts

  defmodule LaunchStub do
    def list_agents(_human) do
      [
        %{
          agent_id: "1:42",
          id: "1:42",
          name: "Atlas",
          state: "eligible",
          access_mode: "owner",
          owner_address: "0x1111111111111111111111111111111111111111",
          supported_chains: [%{id: 1, label: "Ethereum Mainnet", short_label: "Ethereum"}],
          operator_addresses: [],
          blocker_texts: [],
          description: "Launch-ready identity",
          image_url: nil,
          ens: nil,
          source: "ERC-8004",
          token_id: "42"
        }
      ]
    end

    def fee_split_summary do
      %{
        headline:
          "2% trade fee -> 1% official agent revenue accounting + 1% Regent/protocol accounting."
      }
    end

    def launch_readiness_for_agent(_human, "1:42") do
      %{
        checks: [
          %{
            key: "ownerOrOperatorAuthorized",
            passed: true,
            message: "Wallet controls this identity."
          },
          %{key: "noPriorSuccessfulLaunch", passed: true, message: "No prior launch found."}
        ],
        resolved_lifecycle_run_id: "life_42"
      }
    end

    def preview_launch(_attrs, _human) do
      {:ok,
       %{
         agent: %{agent_id: "1:42", name: "Atlas"},
         token: %{
           name: "Atlas Coin",
           symbol: "ATLAS",
           chain_id: 1,
           chain_label: "Ethereum Mainnet",
           recovery_safe_address: "0x1111111111111111111111111111111111111111",
           auction_proceeds_recipient: "0x1111111111111111111111111111111111111111",
           ethereum_revenue_treasury: "0x1111111111111111111111111111111111111111"
         },
         next_steps: [
           "Sign the SIWA message with a linked wallet that controls this ERC-8004 identity.",
           "Queue deploy job.",
           "Wait for the auction page to go live."
         ],
         permanence_notes: [
           "One ERC-8004 identity can launch at most one Agent Coin."
         ],
         reputation_prompt: %{
           prompt:
             "To improve agent token reputation, you can optionally link an ENS name and/or connect to a human's World ID.",
           warning:
             "You can skip this, though the token launch may be less trusted until these links are added.",
           skip_label: "Skip for now",
           instructions: [
             "Link an ENS name so the creator identity advertises a public name.",
             "After launch creates the token address, ask the human behind this token to complete the World AgentBook proof."
           ],
           actions: [
             %{
               key: "ens",
               label: "Link ENS name",
               status: "available",
               action_url: "/ens-link?identity_id=1%3A42&ens_name=atlas.eth",
               note: "Finish the ENS link so the creator identity advertises a public name."
             },
             %{
               key: "world",
               label: "Connect World ID",
               status: "pending",
               action_url: nil,
               note: "World AgentBook proof becomes available after the token address exists."
             }
           ]
         }
       }}
    end

    def get_job_response("job_queued") do
      %{
        job: %{
          job_id: "job_queued",
          status: "queued",
          step: "queued",
          network: "ethereum-mainnet",
          chain_label: "Ethereum Mainnet",
          reputation_prompt: %{
            prompt:
              "To improve agent token reputation, you can optionally link an ENS name and/or connect to a human's World ID.",
            warning:
              "You can skip this, though the token launch may be less trusted until these links are added.",
            skip_label: "Skip for now",
            instructions: [
              "ENS is already linked for the creator identity.",
              "Ask the human behind this token to complete the World AgentBook proof."
            ],
            actions: [
              %{
                key: "ens",
                label: "Review ENS link",
                status: "complete",
                action_url: "/ens-link?identity_id=1%3A42&ens_name=atlas.eth",
                note: "ENS link already present on the creator identity."
              },
              %{
                key: "world",
                label: "Connect World ID",
                status: "available",
                action_url:
                  "/agentbook?agent_address=0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb&network=world&launch_job_id=job_queued",
                note: "A human must finish the World AgentBook proof for this launched token."
              }
            ]
          }
        },
        auction: nil
      }
    end

    def get_job_response(_job_id), do: nil

    def terminal_status?(status), do: status in ["ready", "failed", "blocked"]
  end

  setup do
    original = Application.get_env(:autolaunch, :launch_live, [])
    Application.put_env(:autolaunch, :launch_live, launch_module: LaunchStub)
    on_exit(fn -> Application.put_env(:autolaunch, :launch_live, original) end)
    :ok
  end

  test "launch page renders agent-first copy", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/launch")

    assert html =~ "Choose an eligible agent"
    assert html =~ "ERC-8004"
    assert html =~ "Configure token"
  end

  test "launch flow shows an optional trust step that can be skipped", %{conn: conn} do
    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:launch-live", %{
        "wallet_address" => "0x1111111111111111111111111111111111111111",
        "wallet_addresses" => ["0x1111111111111111111111111111111111111111"],
        "display_name" => "Launch Operator"
      })

    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/launch")

    view
    |> element("button[phx-value-agent_id='1:42']")
    |> render_click()

    view
    |> form("form", %{
      "launch" => %{
        "token_name" => "Atlas Coin",
        "token_symbol" => "ATLAS",
        "recovery_safe_address" => "0x1111111111111111111111111111111111111111",
        "auction_proceeds_recipient" => "0x1111111111111111111111111111111111111111",
        "ethereum_revenue_treasury" => "0x1111111111111111111111111111111111111111"
      }
    })
    |> render_change()

    view
    |> element("button[phx-click='prepare_review']")
    |> render_click()

    assert render(view) =~ "Optional trust step"

    assert render(view) =~
             "The next screen gives the links and lets you skip this without blocking launch."

    html = render_hook(view, "launch_queued", %{"job_id" => "job_queued"})

    assert html =~ "Optional reputation step"
    assert html =~ "To improve agent token reputation, you can optionally link an ENS name"
    assert html =~ "Skip for now"
    assert html =~ "Open ENS planner"
  end

  test "auctions page renders market copy", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/auctions")

    assert html =~ "Auction Market"
    assert html =~ "No auctions match the current filter."
  end

  test "positions page renders sign-in guidance for guests", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/positions")

    assert html =~ "Sign in to inspect your bids."
  end
end
