defmodule Autolaunch.DocsExamplesTest do
  use ExUnit.Case, async: true

  @bundle_path Path.expand("../../docs/autolaunch_examples.json", __DIR__)

  test "canonical example bundle keeps the current response shapes" do
    bundle =
      @bundle_path
      |> File.read!()
      |> Jason.decode!()

    assert Map.has_key?(bundle, "launch_preview")
    assert Map.has_key?(bundle, "launch_job_response")
    assert Map.has_key?(bundle, "prelaunch_plan")
    assert Map.has_key?(bundle, "prelaunch_validation")
    assert Map.has_key?(bundle, "lifecycle_monitor")
    assert Map.has_key?(bundle, "finalize_response")
    assert Map.has_key?(bundle, "vesting_status")
    assert Map.has_key?(bundle, "bid_quote")
    assert Map.has_key?(bundle, "position")
    assert Map.has_key?(bundle, "reputation_prompt")

    prelaunch_plan = bundle["prelaunch_plan"]
    assert prelaunch_plan["chain_id"] == 84_532
    assert prelaunch_plan["metadata_draft"]["image_asset_id"] == "asset_alpha"

    prelaunch_validation = bundle["prelaunch_validation"]
    assert prelaunch_validation["validation"]["launchable"] == true
    assert prelaunch_validation["validation"]["identity_status"]["agent_id"] == "84532:42"

    launch_preview = bundle["launch_preview"]
    assert launch_preview["token"]["chain_id"] == 84_532
    assert launch_preview["completion_plan"]["ens"]["action_url"] =~ "/ens-link?"
    assert launch_preview["reputation_prompt"]["skip_label"] == "Skip for now"

    job = bundle["launch_job_response"]["job"]
    assert job["status"] == "ready"
    assert job["reputation_prompt"]["prompt"] =~ "ENS name"
    assert job["reputation_prompt"]["actions"] |> Enum.map(& &1["key"]) == ["ens", "world"]
    assert job["default_ingress_address"] == "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

    lifecycle_monitor = bundle["lifecycle_monitor"]
    assert lifecycle_monitor["recommended_action"] == "migrate"
    assert lifecycle_monitor["settlement_state"] == "awaiting_migration"
    assert lifecycle_monitor["allowed_actions"] == ["migrate"]
    assert lifecycle_monitor["balance_snapshot"]["strategy"]["usdc_balance"] == 120_000_000

    finalize_response = bundle["finalize_response"]
    assert finalize_response["settlement_state"] == "awaiting_migration"
    assert finalize_response["prepared"]["action"] == "migrate"
    assert finalize_response["prepared"]["tx_request"]["chain_id"] == 84_532

    vesting_status = bundle["vesting_status"]
    assert vesting_status["release_ready"] == true

    assert vesting_status["vesting_wallet_address"] ==
             "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    regent_staking_overview = bundle["regent_staking_overview"]
    assert regent_staking_overview["chain_id"] == 8_453
    assert regent_staking_overview["chain_label"] == "Base"

    regent_staking_prepare = bundle["regent_staking_prepare"]
    assert regent_staking_prepare["prepared"]["chain_id"] == 8_453
    assert regent_staking_prepare["prepared"]["tx_request"]["chain_id"] == 8_453

    bid_quote = bundle["bid_quote"]
    assert bid_quote["tx_request"]["chain_id"] == 84_532
    assert bid_quote["quote_mode"] == "onchain_exact_v1"

    position = bundle["position"]
    assert position["status"] == "claimable"
    assert position["tx_actions"]["claim"]["chain_id"] == 84_532
    assert position["next_action_label"] == "Claim purchased tokens now."

    reputation_prompt = bundle["reputation_prompt"]
    assert reputation_prompt["prompt"] =~ "ENS name"
    assert reputation_prompt["actions"] |> Enum.map(& &1["key"]) == ["ens", "world"]
  end
end
