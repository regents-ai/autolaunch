defmodule Mix.Tasks.Autolaunch.SmokeTest do
  use Autolaunch.DataCase, async: false

  import ExUnit.CaptureIO

  setup do
    previous_launch = Application.get_env(:autolaunch, :launch, [])
    previous_rpc = Application.get_env(:autolaunch, :cca_rpc_adapter)

    Application.put_env(
      :autolaunch,
      :launch,
      Keyword.merge(previous_launch,
        mock_deploy: true,
        deploy_workdir: File.cwd!(),
        deploy_binary: "forge",
        deploy_script_target:
          "scripts/ExampleCCADeploymentScript.s.sol:ExampleCCADeploymentScript",
        eth_sepolia_factory_address: "0xCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
        revenue_share_factory_address: "0x1111111111111111111111111111111111111111",
        revenue_ingress_factory_address: "0x2222222222222222222222222222222222222222",
        lbp_strategy_factory_address: "0x3333333333333333333333333333333333333333",
        token_factory_address: "0x4444444444444444444444444444444444444444",
        eth_sepolia_pool_manager_address: "0x5555555555555555555555555555555555555555",
        eth_sepolia_position_manager_address: "0x6666666666666666666666666666666666666666",
        eth_sepolia_usdc_address: "0x7777777777777777777777777777777777777777"
      )
    )

    on_exit(fn ->
      Application.put_env(:autolaunch, :launch, previous_launch)

      if previous_rpc do
        Application.put_env(:autolaunch, :cca_rpc_adapter, previous_rpc)
      else
        Application.delete_env(:autolaunch, :cca_rpc_adapter)
      end
    end)

    Mix.Task.reenable("autolaunch.smoke")
    :ok
  end

  test "smoke task prints the synthetic identifiers" do
    output =
      capture_io(fn ->
        Mix.Tasks.Autolaunch.Smoke.run([])
      end)

    assert output =~ "Autolaunch smoke passed."
    assert output =~ "Smoke job:"
    assert output =~ "Smoke subject:"
  end
end
