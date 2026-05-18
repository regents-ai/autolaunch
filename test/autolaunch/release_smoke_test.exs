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
        chain_id: 8_453,
        cca_factory_address: "0xCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
        revenue_share_factory_address: "0x1111111111111111111111111111111111111111",
        revenue_ingress_factory_address: "0x2222222222222222222222222222222222222222",
        lbp_strategy_factory_address: "0x3333333333333333333333333333333333333333",
        token_factory_address: "0x4444444444444444444444444444444444444444",
        identity_registry_address: "0x9999999999999999999999999999999999999999",
        factory_owner_address: "0x9999999999999999999999999999999999999997",
        strategy_operator: "0x9999999999999999999999999999999999999998",
        official_pool_fee: "0",
        official_pool_tick_spacing: "60",
        cca_tick_spacing_q96: "79228162514264337593543950",
        cca_floor_price_q96: "7922816251426433759354395000",
        auction_duration_blocks: "9258",
        cca_prebid_blocks: "0",
        cca_final_block_bps: "3000",
        cca_start_block_offset: "300",
        cca_claim_block_offset: "64",
        lbp_migration_block_offset: "128",
        lbp_sweep_block_offset: "256",
        pool_manager_address: "0x5555555555555555555555555555555555555555",
        position_manager_address: "0x6666666666666666666666666666666666666666",
        auction_quote_token_address: "0x6f89bca4ea5931edfcb09786267b251dee752b07",
        revenue_usdc_address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
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
    assert %{
             ok: true,
             job_id: job_id,
             subject_id: subject_id,
             chain_id: chain_id,
             network: network,
             agent_id: agent_id,
             checks: checks
           } =
             ReleaseSmoke.run()

    assert String.starts_with?(job_id, "job_smoke_")
    assert subject_id == "0x" <> String.duplicate("1", 64)

    assert Enum.map(checks, & &1.key) == [
             "launch_job_ready",
             "trust_urls",
             "regent_bid_quote",
             "subject_read",
             "ingress_read"
           ]

    assert chain_id == 8_453
    assert network == "base-mainnet"
    assert agent_id == "8453:42"
  end
end
