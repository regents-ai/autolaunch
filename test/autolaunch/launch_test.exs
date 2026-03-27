defmodule Autolaunch.LaunchTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Launch.Auction
  alias Autolaunch.Launch.Job
  alias Autolaunch.Launch
  alias Autolaunch.Repo

  defp launch_recipients do
    %{
      recovery_safe_address: "0x1111111111111111111111111111111111111111",
      auction_proceeds_recipient: "0x1111111111111111111111111111111111111111",
      ethereum_revenue_treasury: "0x1111111111111111111111111111111111111111"
    }
  end

  test "repo-backed auctions fail closed when none exist" do
    assert Launch.list_auctions() == []
  end

  test "terminal statuses match launch job polling expectations" do
    assert Launch.terminal_status?("ready")
    assert Launch.terminal_status?("failed")
    refute Launch.terminal_status?("queued")
  end

  test "chain options expose ethereum sepolia only" do
    assert Enum.map(Launch.chain_options(), & &1.id) == [11_155_111]
  end

  test "auction listings expose ENS and world completion state" do
    now = DateTime.utc_now()

    {:ok, _first} =
      %Auction{}
      |> Auction.changeset(%{
        source_job_id: "auc_first",
        agent_id: "11155111:42",
        agent_name: "Atlas",
        ens_name: "atlas.eth",
        owner_address: "0x1111111111111111111111111111111111111111",
        auction_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        token_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        network: "ethereum-sepolia",
        chain_id: 11_155_111,
        status: "active",
        started_at: now,
        world_registered: true,
        world_human_id: "0x1234"
      })
      |> Repo.insert()

    {:ok, _second} =
      %Auction{}
      |> Auction.changeset(%{
        source_job_id: "auc_second",
        agent_id: "11155111:99",
        agent_name: "Nova",
        ens_name: nil,
        owner_address: "0x2222222222222222222222222222222222222222",
        auction_address: "0xcccccccccccccccccccccccccccccccccccccccc",
        token_address: "0xdddddddddddddddddddddddddddddddddddddddd",
        network: "ethereum-sepolia",
        chain_id: 11_155_111,
        status: "active",
        started_at: now,
        world_registered: true,
        world_human_id: "0x1234"
      })
      |> Repo.insert()

    [latest | _rest] = Launch.list_auctions(%{"sort" => "recent"}, nil)

    assert latest.world_registered
    assert latest.world_human_id == "0x1234"
    assert latest.world_launch_count == 2
    assert latest.completion_plan.agentbook.launch_count == 2
  end

  test "record_world_agentbook_completion updates the launch job and auction" do
    now = DateTime.utc_now()

    {:ok, _job} =
      %Job{}
      |> Job.create_changeset(
        %{
          job_id: "job_completion",
          owner_address: "0x1111111111111111111111111111111111111111",
          agent_id: "11155111:42",
          token_name: "Atlas Coin",
          token_symbol: "ATLAS",
          network: "ethereum-sepolia",
          chain_id: 11_155_111,
          status: "ready",
          step: "ready",
          total_supply: "1000",
          message: "signed",
          siwa_nonce: "nonce-1",
          siwa_signature: "sig",
          issued_at: now
        }
        |> Map.merge(launch_recipients())
      )
      |> Repo.insert()

    {:ok, _auction} =
      %Auction{}
      |> Auction.changeset(%{
        source_job_id: "auc_completion",
        agent_id: "11155111:42",
        agent_name: "Atlas",
        owner_address: "0x1111111111111111111111111111111111111111",
        auction_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        token_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        network: "ethereum-sepolia",
        chain_id: 11_155_111,
        status: "active",
        started_at: now
      })
      |> Repo.insert()

    assert {:ok, %{human_id: "0x1234"}} =
             Launch.record_world_agentbook_completion("job_completion", %{
               human_id: "0x1234",
               network: "world"
             })

    job = Repo.get!(Job, "job_completion")
    auction = Repo.get_by!(Auction, source_job_id: "auc_completion")

    assert job.world_registered
    assert job.world_human_id == "0x1234"
    assert auction.world_registered
    assert auction.world_human_id == "0x1234"
  end

  test "job responses include the optional reputation prompt" do
    now = DateTime.utc_now()

    {:ok, _job} =
      %Job{}
      |> Job.create_changeset(
        %{
          job_id: "job_prompt",
          owner_address: "0x1111111111111111111111111111111111111111",
          agent_id: "11155111:42",
          ens_name: "atlas.eth",
          token_name: "Atlas Coin",
          token_symbol: "ATLAS",
          network: "ethereum-sepolia",
          chain_id: 11_155_111,
          status: "queued",
          step: "queued",
          total_supply: "1000",
          message: "signed",
          siwa_nonce: "nonce-1",
          siwa_signature: "sig",
          issued_at: now
        }
        |> Map.merge(launch_recipients())
      )
      |> Repo.insert()

    Repo.get!(Job, "job_prompt")
    |> Job.update_changeset(%{
      token_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      strategy_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      vesting_wallet_address: "0x9999999999999999999999999999999999999999",
      launch_fee_vault_address: "0xcccccccccccccccccccccccccccccccccccccccc",
      revenue_share_splitter_address: "0xdddddddddddddddddddddddddddddddddddddddd",
      subject_id: "0x" <> String.duplicate("1", 64),
      default_ingress_address: "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
      pool_id: "0x" <> String.duplicate("2", 64)
    })
    |> Repo.update!()

    response = Launch.get_job_response("job_prompt")

    assert response.job.strategy_address == "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    assert response.job.vesting_wallet_address ==
             "0x9999999999999999999999999999999999999999"

    assert response.job.launch_fee_vault_address ==
             "0xcccccccccccccccccccccccccccccccccccccccc"

    assert response.job.revenue_share_splitter_address ==
             "0xdddddddddddddddddddddddddddddddddddddddd"

    assert response.job.subject_id == "0x" <> String.duplicate("1", 64)
    assert response.job.default_ingress_address == "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

    assert response.job.pool_id == "0x" <> String.duplicate("2", 64)

    refute Map.has_key?(response.job, :emission_recipient)
    refute Map.has_key?(response.job, :epoch_seconds)
    assert response.job.reputation_prompt.prompt =~ "optionally link an ENS name"
    assert response.job.reputation_prompt.skip_label == "Skip for now"

    assert Enum.any?(response.job.reputation_prompt.actions, fn action ->
             action.key == "ens" and action.status == "complete"
           end)

    assert Enum.any?(response.job.reputation_prompt.actions, fn action ->
             action.key == "world" and action.status == "available"
           end)
  end

  test "process_job stores the current canonical launch stack output" do
    with_launch_command_output(
      canonical_launch_output(
        strategyAddress: "0x9999999999999999999999999999999999999999",
        vestingWalletAddress: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        defaultIngressAddress: "0x7777777777777777777777777777777777777777",
        poolId: "0x" <> String.duplicate("f", 64)
      ),
      fn ->
        insert_launch_job("job_canonical_output")

        assert :ok = Launch.process_job("job_canonical_output")

        job = Repo.get!(Job, "job_canonical_output")
        response = Launch.get_job_response("job_canonical_output")

        assert job.status == "ready"
        assert job.strategy_address == "0x9999999999999999999999999999999999999999"

        assert job.vesting_wallet_address ==
                 "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

        assert job.default_ingress_address == "0x7777777777777777777777777777777777777777"

        assert job.pool_id == "0x" <> String.duplicate("f", 64)
        assert response.job.strategy_address == job.strategy_address
        assert response.job.vesting_wallet_address == job.vesting_wallet_address
        assert response.job.default_ingress_address == job.default_ingress_address
        assert response.job.pool_id == job.pool_id
      end
    )
  end

  test "process_job fails when the canonical deploy output is missing a required field" do
    with_launch_command_output(
      canonical_launch_output(%{})
      |> Map.delete("defaultIngressAddress"),
      fn ->
        insert_launch_job("job_missing_ingress")

        assert :ok = Launch.process_job("job_missing_ingress")

        job = Repo.get!(Job, "job_missing_ingress")

        assert job.status == "failed"
        assert job.step == "failed"
        assert job.error_message == "Deployment output did not include defaultIngressAddress."
      end
    )
  end

  defp insert_launch_job(job_id) do
    now = DateTime.utc_now()

    {:ok, _job} =
      %Job{}
      |> Job.create_changeset(
        %{
          job_id: job_id,
          owner_address: "0x1111111111111111111111111111111111111111",
          agent_id: "11155111:42",
          agent_name: "Atlas",
          token_name: "Atlas Coin",
          token_symbol: "ATLAS",
          network: "ethereum-sepolia",
          chain_id: 11_155_111,
          status: "queued",
          step: "queued",
          total_supply: "1000",
          message: "signed",
          siwa_nonce: "nonce-1",
          siwa_signature: "sig",
          issued_at: now,
          broadcast: false
        }
        |> Map.merge(launch_recipients())
      )
      |> Repo.insert()
  end

  defp with_launch_command_output(result_json, fun) do
    original = Application.get_env(:autolaunch, :launch, [])
    tmp_dir = System.tmp_dir!()
    script_path = Path.join(tmp_dir, "launch-test-#{System.unique_integer([:positive])}.sh")
    marker = "CCA_RESULT_JSON:"
    payload = Jason.encode!(result_json)

    script = """
    #!/bin/sh
    printf '%s\\n' '#{marker}#{payload}'
    """

    File.write!(script_path, script)
    File.chmod!(script_path, 0o755)

    Application.put_env(
      :autolaunch,
      :launch,
      Keyword.merge(original,
        mock_deploy: false,
        deploy_binary: script_path,
        deploy_workdir: tmp_dir,
        deploy_script_target: "ignored",
        eth_sepolia_rpc_url: "http://127.0.0.1:8545",
        revenue_share_factory_address: "0x1111111111111111111111111111111111111111",
        revenue_ingress_factory_address: "0x2222222222222222222222222222222222222222",
        lbp_strategy_factory_address: "0x6666666666666666666666666666666666666666",
        token_factory_address: "0x7777777777777777777777777777777777777777",
        eth_sepolia_pool_manager_address: "0x3333333333333333333333333333333333333333",
        eth_sepolia_factory_address: "0x4444444444444444444444444444444444444444",
        eth_sepolia_usdc_address: "0x5555555555555555555555555555555555555555",
        eth_sepolia_position_manager_address: "0x8888888888888888888888888888888888888888"
      )
    )

    on_exit(fn ->
      Application.put_env(:autolaunch, :launch, original)
      File.rm(script_path)
    end)

    fun.()
  end

  defp canonical_launch_output(overrides) when is_list(overrides) do
    canonical_launch_output(Map.new(overrides))
  end

  defp canonical_launch_output(overrides) do
    Map.merge(
      %{
        "factoryAddress" => "0x4444444444444444444444444444444444444444",
        "auctionAddress" => "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "tokenAddress" => "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "strategyAddress" => "0x9999999999999999999999999999999999999999",
        "vestingWalletAddress" => "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "hookAddress" => "0xcccccccccccccccccccccccccccccccccccccccc",
        "launchFeeRegistryAddress" => "0xdddddddddddddddddddddddddddddddddddddddd",
        "feeVaultAddress" => "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        "subjectRegistryAddress" => "0xffffffffffffffffffffffffffffffffffffffff",
        "subjectId" => "0x" <> String.duplicate("1", 64),
        "revenueShareSplitterAddress" => "0x9999999999999999999999999999999999999999",
        "defaultIngressAddress" => "0x7777777777777777777777777777777777777777",
        "poolId" => "0x" <> String.duplicate("f", 64),
        "txHash" => "0x" <> String.duplicate("a", 64)
      },
      overrides
    )
  end
end
