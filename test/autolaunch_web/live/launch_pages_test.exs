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

  defmodule PrelaunchStub do
    def update_metadata("plan_alpha", %{"metadata" => metadata}, %{
          privy_user_id: "did:privy:launch-plan"
        }) do
      if pid = Application.get_env(:autolaunch, :launch_pages_test_pid) do
        send(pid, {:metadata_updated, metadata})
      end

      {:ok,
       %{
         plan: %{
           plan_id: "plan_alpha",
           state: "launchable",
           metadata_draft: metadata
         },
         metadata_preview: %{
           title: metadata["title"],
           subtitle: metadata["subtitle"],
           description: metadata["description"],
           image_url: metadata["image_url"],
           website_url: metadata["website_url"]
         }
       }}
    end

    def update_metadata(_plan_id, _attrs, _human), do: {:error, :not_found}

    def list_plans(%{privy_user_id: "did:privy:launch-plan"}) do
      {:ok,
       [
         %{
           plan_id: "plan_alpha",
           state: "launchable",
           agent_id: "11155111:42",
           agent_name: "Atlas",
           token_name: "Atlas Coin",
           token_symbol: "ATLAS",
           metadata_draft: %{
             "title" => "Atlas Launch",
             "subtitle" => "Agent market",
             "description" => "A saved plan from the CLI.",
             "website_url" => "https://atlas.example",
             "image_url" => "https://atlas.example/cover.png"
           },
           identity_snapshot: %{},
           launch_job_id: nil
         }
       ]}
    end

    def list_plans(%{privy_user_id: "did:privy:launch-live-plan"}) do
      {:ok,
       [
         %{
           plan_id: "plan_live",
           state: "launched",
           agent_id: "11155111:42",
           agent_name: "Atlas",
           token_name: "Atlas Coin",
           token_symbol: "ATLAS",
           metadata_draft: %{},
           identity_snapshot: %{},
           launch_job_id: "job_alpha"
         }
       ]}
    end

    def list_plans(_human), do: {:ok, []}
  end

  setup do
    original = Application.get_env(:autolaunch, :launch_live, [])
    original_test_pid = Application.get_env(:autolaunch, :launch_pages_test_pid)

    Application.put_env(:autolaunch, :launch_live,
      launch_module: LaunchStub,
      prelaunch_module: PrelaunchStub
    )

    Application.put_env(:autolaunch, :launch_pages_test_pid, self())

    on_exit(fn ->
      Application.put_env(:autolaunch, :launch_live, original)

      if is_nil(original_test_pid) do
        Application.delete_env(:autolaunch, :launch_pages_test_pid)
      else
        Application.put_env(:autolaunch, :launch_pages_test_pid, original_test_pid)
      end
    end)

    :ok
  end

  test "launch page renders the CLI-first review page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/launch")

    assert html =~ "Launch your agent on Base, the right way."
    assert html =~ "regent autolaunch prelaunch wizard"
    assert html =~ "Launch console"
    assert html =~ "Direct operator path"
    assert html =~ "Agent-assisted path"
    assert html =~ "Review launch setup"
  end

  test "launch via agent page explains the CLI-first path", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/launch-via-agent")

    assert html =~ "Launch your agent on Base, the right way."
    assert html =~ "regent autolaunch prelaunch wizard"
    assert html =~ "Agent-assisted path"
    assert html =~ "OpenClaw"
    assert html =~ "Hermes"
    assert html =~ "Open agent-assisted brief"
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

    assert html =~ "Starter command"
    assert html =~ "Copy direct CLI command"
    assert html =~ "Open agent-assisted brief"
    assert html =~ "Review launch setup"
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

    assert html =~ "Stay in one operator flow from command line to live market."
    assert html =~ "Open contracts"
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

    assert html =~ "Run this in your terminal to start the guided launch flow."
    assert html =~ "Deploy the Safe, strategy, splitter, ingress, and registry."
    assert html =~ "Fund the strategy and set the launch allocations."
    assert html =~ "Start the market on Base and keep the operator run moving."
    assert html =~ "Open contracts"
    refute html =~ "Prepare review"
  end

  test "launch page uses wallet, profile, identity, and plan state for the next action", %{
    conn: conn
  } do
    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:launch-plan", %{
        "wallet_address" => "0x1111111111111111111111111111111111111111",
        "wallet_addresses" => ["0x1111111111111111111111111111111111111111"],
        "display_name" => "Launch Operator"
      })

    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, _view, html} = live(conn, "/launch")

    assert html =~ "Operator wallet"
    assert html =~ "Launch Operator"
    assert html =~ "1 identity ready for launch."
    assert html =~ "ATLAS plan is ready to publish and run."
    assert html =~ "Run the launch"
    assert html =~ "Copy launch command"
    assert html =~ "CLI starts the launch. Web completes public details and trust review."
    assert html =~ "Atlas Launch"
    assert html =~ "A saved plan from the CLI."
  end

  test "launch page saves public metadata without launching from the browser", %{conn: conn} do
    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:launch-plan", %{
        "wallet_address" => "0x1111111111111111111111111111111111111111",
        "wallet_addresses" => ["0x1111111111111111111111111111111111111111"],
        "display_name" => "Launch Operator"
      })

    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/launch")

    html =
      view
      |> form("#launch-metadata-form", %{
        "metadata" => %{
          "title" => "Atlas Public Launch",
          "subtitle" => "Operator reviewed",
          "description" => "Public launch details for bidders.",
          "website_url" => "https://atlas.example/public",
          "image_url" => "https://atlas.example/public.png"
        }
      })
      |> render_submit()

    assert_received {:metadata_updated,
                     %{
                       "title" => "Atlas Public Launch",
                       "image_url" => "https://atlas.example/public.png"
                     }}

    assert html =~ "Atlas Public Launch"
    assert html =~ "Public launch details for bidders."
    refute html =~ "Publish plan"
    refute html =~ "Run from browser"
    refute html =~ "Finalize launch"
  end

  test "launch page points launched plans to contract review", %{conn: conn} do
    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:launch-live-plan", %{
        "wallet_address" => "0x1111111111111111111111111111111111111111",
        "wallet_addresses" => ["0x1111111111111111111111111111111111111111"],
        "display_name" => "Launch Operator"
      })

    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, _view, html} = live(conn, "/launch")

    assert html =~ "Launch tracking is open for job_alpha."
    assert html =~ "Track launch work"
    assert html =~ "Open contracts"
  end

  test "market page renders token directory copy", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/auctions")

    assert html =~ "Open markets"
    assert html =~ "Total market cap"
    assert html =~ "Total bid volume"
  end

  test "positions page renders sign-in guidance for guests", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/positions")

    assert html =~ "Sign in to inspect your bids."
  end

  test "shell keeps five primary destinations in the sidebar", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/launch")

    assert html =~ ~s(aria-label="Primary")
    assert html =~ "Home"
    assert html =~ "Launch"
    assert html =~ "Auctions"
    assert html =~ "Positions"
    assert html =~ "Profile"
    assert html =~ "Network"
    assert html =~ "Base mainnet"
  end
end
