defmodule Autolaunch.LaunchDeployCommandTest do
  use ExUnit.Case, async: true

  alias Autolaunch.Launch.DeployCommand
  alias Autolaunch.Launch.Job

  test "build includes every deploy-script input in the command environment" do
    assert {:ok, command} = DeployCommand.build(job(), launch_config())

    env = Map.new(command.opts[:env])

    assert env["AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS"] ==
             "0x9999999999999999999999999999999999999999"

    assert env["AUTOLAUNCH_AGENT_ID"] == "8453:42"
    assert env["AUTOLAUNCH_TOKEN_METADATA_DESCRIPTION"] == "Atlas launch"
    assert env["AUTOLAUNCH_TOKEN_METADATA_WEBSITE"] == "https://atlas.example"
    assert env["AUTOLAUNCH_TOKEN_METADATA_IMAGE"] == "ipfs://atlas"
    assert env["STRATEGY_OPERATOR"] == "0x9999999999999999999999999999999999999998"
    assert env["AUTOLAUNCH_FACTORY_OWNER_ADDRESS"] == "0x9999999999999999999999999999999999999997"
    assert env["OFFICIAL_POOL_FEE"] == "0"
    assert env["OFFICIAL_POOL_TICK_SPACING"] == "60"
    assert env["CCA_TICK_SPACING_Q96"] == "79228162514264337593543950"
    assert env["CCA_FLOOR_PRICE_Q96"] == "7922816251426433759354395000"
    assert env["CCA_REQUIRED_CURRENCY_RAISED"] == "1000000000000000000"

    assert env["AUTOLAUNCH_AUCTION_QUOTE_TOKEN_ADDRESS"] ==
             "0x6f89bca4ea5931edfcb09786267b251dee752b07"

    assert env["AUTOLAUNCH_REVENUE_USDC_ADDRESS"] ==
             "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"

    refute Map.has_key?(env, "AUTOLAUNCH_USDC_ADDRESS")
    assert env["AUCTION_DURATION_BLOCKS"] == "86400"
    assert env["CCA_PREBID_BLOCKS"] == "0"
    assert env["CCA_FINAL_BLOCK_BPS"] == "3000"
    assert env["CCA_START_BLOCK_OFFSET"] == "300"
    assert env["CCA_CLAIM_BLOCK_OFFSET"] == "64"
    assert env["LBP_MIGRATION_BLOCK_OFFSET"] == "128"
    assert env["LBP_SWEEP_BLOCK_OFFSET"] == "256"

    assert "--account" in command.args
    assert "--sender" in command.args
    refute "--private-key" in command.args
  end

  test "build fails before running forge when a required script input is missing" do
    config = Keyword.put(launch_config(), :strategy_operator, "")

    assert {:error, "Missing strategy operator address.", %{stdout_tail: "", stderr_tail: ""}} =
             DeployCommand.build(job(), config)
  end

  test "build requires the factory owner address" do
    config = Keyword.put(launch_config(), :factory_owner_address, "")

    assert {:error, "Missing factory owner address.", %{stdout_tail: "", stderr_tail: ""}} =
             DeployCommand.build(job(), config)
  end

  test "build validates convex CCA schedule inputs before running forge" do
    config = Keyword.put(launch_config(), :cca_final_block_bps, "4001")

    assert {:error, "Missing CCA final block basis points.", %{stdout_tail: "", stderr_tail: ""}} =
             DeployCommand.build(job(), config)

    config = Keyword.put(launch_config(), :auction_duration_blocks, "12")

    assert {:error, "Invalid auction duration.", %{stdout_tail: "", stderr_tail: ""}} =
             DeployCommand.build(job(), config)

    config = Keyword.put(launch_config(), :cca_prebid_blocks, "1099511627776")

    assert {:error, "Invalid CCA prebid blocks.", %{stdout_tail: "", stderr_tail: ""}} =
             DeployCommand.build(job(), config)
  end

  test "build leaves identity env blank when the registry is not configured" do
    config = Keyword.put(launch_config(), :identity_registry_address, "")

    assert {:ok, command} = DeployCommand.build(job(), config)

    env = Map.new(command.opts[:env])
    assert env["AUTOLAUNCH_IDENTITY_REGISTRY_ADDRESS"] == ""
    assert env["AUTOLAUNCH_AGENT_ID"] == ""
  end

  defp job do
    %Job{
      job_id: "job_deploy_command",
      owner_address: "0x1111111111111111111111111111111111111111",
      agent_id: "8453:42",
      agent_name: "Atlas",
      token_name: "Atlas Coin",
      token_symbol: "ATLAS",
      minimum_raise_quote_raw: "1000000000000000000",
      total_supply: "1000",
      agent_safe_address: "0x2222222222222222222222222222222222222222",
      lifecycle_run_id: "life_1",
      launch_notes: "Launch",
      network: "base-mainnet",
      chain_id: 8_453,
      broadcast: false
    }
  end

  defp launch_config do
    [
      chain_id: 8_453,
      deploy_binary: "forge",
      deploy_workdir: "contracts",
      deploy_script_target: "scripts/ExampleCCADeploymentScript.s.sol:ExampleCCADeploymentScript",
      rpc_url: "https://base-mainnet.example",
      revenue_share_factory_address: "0x3333333333333333333333333333333333333333",
      revenue_ingress_factory_address: "0x4444444444444444444444444444444444444444",
      lbp_strategy_factory_address: "0x5555555555555555555555555555555555555555",
      token_factory_address: "0x6666666666666666666666666666666666666666",
      token_metadata_description: "Atlas launch",
      token_metadata_website: "https://atlas.example",
      token_metadata_image: "ipfs://atlas",
      regent_multisig_address: "0x7777777777777777777777777777777777777777",
      deploy_account: "autolaunch-infra",
      deploy_sender: "0x1515eefa0d418ef1a8cd788b57eb36b6d7437b86",
      factory_owner_address: "0x9999999999999999999999999999999999999997",
      strategy_operator: "0x9999999999999999999999999999999999999998",
      auction_quote_token_address: "0x6f89bca4ea5931edfcb09786267b251dee752b07",
      revenue_usdc_address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      official_pool_fee: "0",
      official_pool_tick_spacing: "60",
      cca_tick_spacing_q96: "79228162514264337593543950",
      cca_floor_price_q96: "7922816251426433759354395000",
      auction_duration_blocks: "86400",
      cca_prebid_blocks: "0",
      cca_final_block_bps: "3000",
      cca_start_block_offset: "300",
      cca_claim_block_offset: "64",
      lbp_migration_block_offset: "128",
      lbp_sweep_block_offset: "256",
      identity_registry_address: "0x9999999999999999999999999999999999999999",
      cca_factory_address: "0x8888888888888888888888888888888888888888",
      pool_manager_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      position_manager_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    ]
  end
end
