defmodule Autolaunch.ReleaseSmokeTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.ReleaseSmoke

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

    :ok
  end

  test "smoke drives a synthetic launch job to ready and proves subject reads" do
    assert %{ok: true, job_id: job_id, subject_id: subject_id, checks: checks} =
             ReleaseSmoke.run()

    assert String.starts_with?(job_id, "job_smoke_")
    assert subject_id == "0x" <> String.duplicate("1", 64)

    assert Enum.map(checks, & &1.key) == [
             "launch_job_ready",
             "trust_urls",
             "subject_read",
             "ingress_read"
           ]
  end
end
