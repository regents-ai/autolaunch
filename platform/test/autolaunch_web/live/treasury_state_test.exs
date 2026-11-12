defmodule AutolaunchWeb.TreasuryStateTest do
  @moduledoc """
  A treasury's stored report is told as it is: the public answer and the
  launch card give the report's own verification, at the Base block it was
  read at, instead of a fixed "awaiting confirmation" that said no launch
  could be prepared even for a verified Safe.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.Actors.System
  alias Autolaunch.{LaunchFixture, TestAutolaunchTreasuryChainClient}

  @safe "0x9999999999999999999999999999999999999999"
  @four_owners [
    "0x1111111111111111111111111111111111111111",
    "0x2222222222222222222222222222222222222222",
    "0x3333333333333333333333333333333333333333",
    "0x4444444444444444444444444444444444444444"
  ]

  setup do
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)
  end

  # A14: every answer was "awaiting_current_chain_confirmation" whatever the
  # report said (money-path audit, 12 Nov 2026).
  test "the public answer gives the stored report's own verification", %{conn: conn} do
    TestAutolaunchTreasuryChainClient.seed_verified!(@safe)

    assert %{"verification_state" => "verified", "verification_reason" => "verified"} =
             conn
             |> get("/api/v1/treasury-security/#{@safe}")
             |> json_response(200)
             |> Map.get("data")

    TestAutolaunchTreasuryChainClient.install(owners: @four_owners)

    {:ok, _report} =
      Autolaunch.observe_treasury_security(
        @safe,
        %{
          usdc: "0x" <> String.duplicate("11", 32),
          regent: "0x" <> String.duplicate("22", 32),
          outbound: "0x" <> String.duplicate("33", 32)
        },
        actor: %System{}
      )

    assert %{"verification_state" => "unverified", "verification_reason" => "safe_owner_count"} =
             build_conn()
             |> get("/api/v1/treasury-security/#{@safe}")
             |> json_response(200)
             |> Map.get("data")
  end

  test "the launch card shows a verified Safe as verified", %{conn: conn} do
    LaunchFixture.install()
    setup = LaunchFixture.actor()
    report = TestAutolaunchTreasuryChainClient.seed_verified!(LaunchFixture.treasury())
    session = signed_in_session(setup[:account].id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/agent-business")

    render_async(view)
    waive_connections(view)

    treasury = "#autolaunch-launch-wallet-#{setup[:draft].id}-treasury"

    assert view
           |> element(~s(#{treasury} [data-treasury-verification-state="verified"]))
           |> render() =~ "#{report.source_block_number}"

    refute has_element?(view, ~s(#{treasury} [data-treasury-verification-state="unverified"]))
  end

  defp waive_connections(view) do
    view
    |> form("#launch-no-connections-form", %{
      "typed" =>
        "I realize my Revstake auction may not appear in the gallery or list, because reputation and social proof are important for raising initial funds for an agent"
    })
    |> render_submit()
  end
end
