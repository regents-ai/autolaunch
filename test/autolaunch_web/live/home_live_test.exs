defmodule AutolaunchWeb.HomeLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.Accounts
  alias Autolaunch.Xmtp

  @agent_private_key "0x1111111111111111111111111111111111111111111111111111111111111111"

  defmodule LaunchStub do
    def list_auctions(_filters, _human) do
      [
        %{
          id: "auction-1",
          agent_id: "11155111:42",
          agent_name: "Atlas",
          symbol: "ATLAS",
          phase: "biddable",
          current_price_usdc: "0.04",
          implied_market_cap_usdc: "4000000",
          started_at: "2026-04-10T12:00:00Z",
          ends_at: "2026-04-13T12:00:00Z",
          price_source: "auction_clearing",
          trust: %{ens: %{connected: true, name: "atlas.eth"}, world: %{connected: true}},
          detail_url: "/auctions/auction-1",
          subject_url: "/subjects/subject-1"
        },
        %{
          id: "auction-2",
          agent_id: "11155111:77",
          agent_name: "Beacon",
          symbol: "BECN",
          phase: "live",
          current_price_usdc: "0.09",
          implied_market_cap_usdc: "9000000",
          started_at: "2026-04-08T12:00:00Z",
          ends_at: "2026-04-09T12:00:00Z",
          price_source: "uniswap_spot",
          trust: %{},
          detail_url: "/auctions/auction-2",
          subject_url: "/subjects/subject-2"
        }
      ]
    end
  end

  setup do
    previous_xmtp = Application.get_env(:autolaunch, Xmtp, [])
    previous_home = Application.get_env(:autolaunch, :home_live, [])

    Application.put_env(
      :autolaunch,
      Xmtp,
      rooms: [
        %{
          key: "autolaunch_wire",
          name: "Autolaunch Wire",
          description: "The shared Autolaunch chat room.",
          app_data: "autolaunch-wire",
          agent_private_key: @agent_private_key,
          moderator_wallets: [],
          capacity: 200,
          presence_timeout_ms: :timer.minutes(2),
          presence_check_interval_ms: :timer.seconds(30),
          policy_options: %{
            allowed_kinds: [:human, :agent],
            required_claims: %{}
          }
        }
      ]
    )

    Application.put_env(:autolaunch, :home_live, launch_module: LaunchStub)

    :ok = Xmtp.reset_for_test!()
    assert {:ok, _room} = Xmtp.bootstrap_room!()

    on_exit(fn ->
      Application.put_env(:autolaunch, Xmtp, previous_xmtp)
      Application.put_env(:autolaunch, :home_live, previous_home)
      :ok = Xmtp.reset_for_test!()
    end)

    :ok
  end

  test "home page renders the wizard-first operator layout", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "Copy the wizard command. Let your agent carry the launch."
    assert html =~ "Copy wizard command"
    assert html =~ "Copy OpenClaw brief"
    assert html =~ "Copy Hermes brief"
    assert html =~ "The market starts here and keeps moving."
    assert html =~ "Atlas"
    assert html =~ "Beacon"
    assert html =~ "Stay on the Autolaunch wire."
  end

  test "home page can drive the XMTP join and send flow from the live view", %{conn: conn} do
    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:home-xmtp", %{
        "wallet_address" => "0x3333333333333333333333333333333333333333",
        "wallet_addresses" => ["0x3333333333333333333333333333333333333333"],
        "display_name" => "Home Operator"
      })

    conn = init_test_session(conn, privy_user_id: human.privy_user_id)
    {:ok, view, _html} = live(conn, "/")

    html =
      view
      |> element("#home-xmtp-room")
      |> render_hook("xmtp_join", %{})

    assert html =~ "Sign the XMTP message to join this chat."

    [_, request_id] =
      Regex.run(~r/data-pending-request-id="([^"]+)"/, html) ||
        flunk("expected a pending XMTP signature request in the rendered home page")

    html =
      view
      |> element("#home-xmtp-room")
      |> render_hook("xmtp_join_signature_signed", %{
        "request_id" => request_id,
        "signature" => "0xsigned"
      })

    assert html =~ "You are in the chat."

    html =
      view
      |> element("#home-xmtp-room")
      |> render_hook("xmtp_send", %{"body" => "Hello from home"})

    assert html =~ "Hello from home"
    assert html =~ "joined"
  end
end
