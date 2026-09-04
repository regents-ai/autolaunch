defmodule AutolaunchWeb.TreasuryControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestAutolaunchTreasuryChainClient, as: Client

  test "GET_READS_ONLY_THE_STORED_REPORT_AND_FAILS_CLOSED_PUBLICLY", %{conn: conn} do
    address = "0x9999999999999999999999999999999999999999"
    report = Client.seed_verified!(address)

    assert %{"data" => public} =
             conn
             |> get("/api/v1/treasury-security/#{address}")
             |> json_response(200)

    assert public["id"] == report.id
    assert public["classification"] == "supported_safe"
    assert public["verification_state"] == "awaiting_current_chain_confirmation"
    assert public["verification_reason"] == "projector_refresh_not_integrated"

    Client.install(error: :provider_should_not_be_called)

    assert conn
           |> recycle()
           |> get("/api/v1/treasury-security/#{address}")
           |> json_response(200)

    Application.delete_env(:autolaunch, :autolaunch_treasury_chain_client)
    Application.delete_env(:autolaunch, :test_autolaunch_treasury_observation)
  end
end
