defmodule AutolaunchWeb.LaunchPagesTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.Accounts

  defmodule LaunchStub do
    def list_agents(_human) do
      [
        %{
          agent_id: "11155111:42",
          id: "11155111:42",
          name: "Atlas",
          state: "eligible",
          access_mode: "owner",
          owner_address: "0x1111111111111111111111111111111111111111",
          supported_chains: [%{id: 11_155_111, label: "Ethereum Sepolia", short_label: "Sepolia"}],
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

    def launch_readiness_for_agent(_human, "11155111:42") do
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
         agent: %{agent_id: "11155111:42", name: "Atlas"},
         token: %{
           name: "Atlas Coin",
           symbol: "ATLAS",
           chain_id: 11_155_111,
           chain_label: "Ethereum Sepolia",
           agent_safe_address: "0x1111111111111111111111111111111111111111"
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
               action_url: "/ens-link?identity_id=11155111%3A42&ens_name=atlas.eth",
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
          network: "ethereum-sepolia",
          chain_label: "Ethereum Sepolia",
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
                action_url: "/ens-link?identity_id=11155111%3A42&ens_name=atlas.eth",
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

  test "launch page renders the CLI-first review page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/launch")

    assert html =~ "Run the launch from one main path."
    assert html =~ "regent autolaunch prelaunch wizard"
    assert html =~ "Operator briefs"
    assert html =~ "What you need"
    assert html =~ "What to run"
    assert html =~ "Canonical operator path"
  end

  test "launch via agent page explains the CLI-first path", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/launch-via-agent")

    assert html =~ "Choose the agent handoff, then move into the main launch console."
    assert html =~ "regent autolaunch prelaunch wizard"
    assert html =~ "Pick the agent that should carry the run."
    assert html =~ "Keep the run boring in the best way."
    assert html =~ "Run the launch and watch the sale."
  end

  test "launch page links operators toward the CLI flow and browser follow-up pages", %{
    conn: conn
  } do
    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:launch-live", %{
        "wallet_address" => "0x1111111111111111111111111111111111111111",
        "wallet_addresses" => ["0x1111111111111111111111111111111111111111"],
        "display_name" => "Launch Operator"
      })

    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, _view, html} = live(conn, "/launch")

    assert html =~ "The exact sequence"
    assert html =~ "regent autolaunch launch run --plan"
    assert html =~ "regent autolaunch launch finalize --job"
    assert html =~ "Starter command"
    assert html =~ "Browse auctions"
    assert html =~ "One repeatable launch path"
  end

  test "launch page keeps the browser role focused on review rather than launch creation", %{
    conn: conn
  } do
    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:launch-back", %{
        "wallet_address" => "0x1111111111111111111111111111111111111111",
        "wallet_addresses" => ["0x1111111111111111111111111111111111111111"],
        "display_name" => "Launch Operator"
      })

    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, _view, html} = live(conn, "/launch")

    assert html =~ "Come back here after the launch is live"
    assert html =~ "Claim, stake, unstake, and sweep from the token page."
    refute html =~ "Choose an eligible agent"
    refute html =~ "Queue deploy job."
  end

  test "launch page renders the CLI command sequence instead of the removed browser wizard", %{
    conn: conn
  } do
    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:launch-chain", %{
        "wallet_address" => "0x1111111111111111111111111111111111111111",
        "wallet_addresses" => ["0x1111111111111111111111111111111111111111"],
        "display_name" => "Launch Operator"
      })

    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, _view, html} = live(conn, "/launch")

    assert html =~ "regent autolaunch prelaunch validate --plan"
    assert html =~ "regent autolaunch prelaunch publish --plan"
    assert html =~ "regent autolaunch launch monitor --job"

    assert html =~
             "Open the contracts page when you want to review addresses or prepare the next action."

    assert html =~ "Open contracts"
    refute html =~ "Prepare review"
  end

  test "market page renders token directory copy", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/home")

    assert html =~ "Choose a live market, then open the bid page."
    assert html =~ "Biddable 0"
    assert html =~ "No tokens match this directory view yet."
  end

  test "positions page renders sign-in guidance for guests", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/positions")

    assert html =~ "Sign in to inspect your bids."
  end

  test "shell keeps five primary destinations and a secondary utility row", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/launch")

    assert html =~ ~s(aria-label="Primary")
    assert html =~ "Home"
    assert html =~ "Launch"
    assert html =~ "Auctions"
    assert html =~ "Positions"
    assert html =~ "Profile"
    assert html =~ "More"
    assert html =~ "Guide"
    assert html =~ "Trust Check"
    assert html =~ "X Link"
    assert html =~ "Contracts"
  end
end
