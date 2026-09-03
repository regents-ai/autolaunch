defmodule Autolaunch.TreasurySecurityReportTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Actors.Human
  alias Autolaunch.TestAutolaunchTreasuryChainClient, as: Client
  alias Autolaunch.TreasurySecurityReport

  test "REPORT_CREATION_IS_SYSTEM_ONLY_AND_NO_GENERIC_MUTATION_EXISTS" do
    report = Client.seed_verified!("0x9999999999999999999999999999999999999999")

    attrs = Map.take(report, TreasurySecurityReport.__schema__(:fields))

    assert {:error, _forbidden} =
             TreasurySecurityReport
             |> Ash.Changeset.for_create(:record_observation, attrs,
               domain: Autolaunch,
               actor: %Human{human_account_id: 1}
             )
             |> Ash.create(domain: Autolaunch, actor: %Human{human_account_id: 1})

    assert Enum.map(Ash.Resource.Info.actions(TreasurySecurityReport), & &1.type) |> Enum.sort() ==
             [:create, :read, :read, :read]

    assert {:ok, stored} = Autolaunch.get_treasury_security_report(report.id, actor: nil)
    assert stored.id == report.id

    Application.delete_env(:autolaunch, :autolaunch_treasury_chain_client)
    Application.delete_env(:autolaunch, :test_autolaunch_treasury_observation)
  end
end
