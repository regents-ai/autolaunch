defmodule Autolaunch.LaunchTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Launch
  alias Autolaunch.Launch.Auction
  alias Autolaunch.Launch.Job
  alias Autolaunch.Repo

  defmodule TokenPricingStub do
    def current_token_price_usdc(_chain_id, _pool_id, token_address) do
      case String.downcase(token_address) do
        "0xdddddddddddddddddddddddddddddddddddddddd" -> {:ok, "0.011"}
        _ -> {:error, :missing_quote}
      end
    end
  end

  defp launch_recipients do
    %{agent_safe_address: "0x1111111111111111111111111111111111111111"}
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
    previous_launch = Application.get_env(:autolaunch, :launch, [])

    Application.put_env(
      :autolaunch,
      :launch,
      Keyword.put(previous_launch, :token_pricing_module, TokenPricingStub)
    )

    on_exit(fn ->
      Application.put_env(:autolaunch, :launch, previous_launch)
    end)

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
        status: "settled",
        started_at: DateTime.add(now, -9 * 86_400, :second),
        ends_at: DateTime.add(now, -2 * 86_400, :second),
        world_registered: true,
        world_human_id: "0x1234"
      })
      |> Repo.insert()

    {:ok, _job} =
      %Job{}
      |> Job.create_changeset(%{
        job_id: "job_second",
        owner_address: "0x2222222222222222222222222222222222222222",
        agent_id: "11155111:99",
        token_name: "Nova Coin",
        token_symbol: "NOVA",
        agent_safe_address: "0x2222222222222222222222222222222222222222",
        network: "ethereum-sepolia",
        chain_id: 11_155_111,
        status: "ready",
        step: "ready",
        total_supply: "1000",
        message: "signed",
        siwa_nonce: "nonce-second",
        siwa_signature: "sig",
        issued_at: now
      })
      |> Repo.insert()

    Repo.get!(Job, "job_second")
    |> Job.update_changeset(%{
      token_address: "0xdddddddddddddddddddddddddddddddddddddddd",
      pool_id: "0x" <> String.duplicate("f", 64),
      subject_id: "0x" <> String.duplicate("1", 64),
      revenue_share_splitter_address: "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    })
    |> Repo.update!()

    [latest | _rest] = Launch.list_auctions(%{"mode" => "all", "sort" => "newest"}, nil)

    assert latest.trust.ens.connected
    assert latest.trust.ens.name == "atlas.eth"
    assert latest.trust.world.connected
    assert latest.trust.world.human_id == "0x1234"
    assert latest.trust.world.launch_count == 2
    assert latest.completion_plan.agentbook.launch_count == 2
  end

  test "auction listings default to biddable newest first and compute live market cap from quoted price" do
    previous_launch = Application.get_env(:autolaunch, :launch, [])

    Application.put_env(
      :autolaunch,
      :launch,
      Keyword.put(previous_launch, :token_pricing_module, TokenPricingStub)
    )

    on_exit(fn ->
      Application.put_env(:autolaunch, :launch, previous_launch)
    end)

    newer = DateTime.utc_now()
    older = DateTime.add(newer, -8 * 86_400, :second)

    Repo.insert!(
      Auction.changeset(%Auction{}, %{
        source_job_id: "auc_new",
        agent_id: "11155111:10",
        agent_name: "Fresh",
        owner_address: "0x1111111111111111111111111111111111111111",
        auction_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        token_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        network: "ethereum-sepolia",
        chain_id: 11_155_111,
        status: "active",
        started_at: newer,
        ends_at: DateTime.add(newer, 3_600, :second)
      })
    )

    Repo.insert!(
      Auction.changeset(%Auction{}, %{
        source_job_id: "auc_old",
        agent_id: "11155111:11",
        agent_name: "Mature",
        owner_address: "0x1111111111111111111111111111111111111111",
        auction_address: "0xcccccccccccccccccccccccccccccccccccccccc",
        token_address: "0xdddddddddddddddddddddddddddddddddddddddd",
        network: "ethereum-sepolia",
        chain_id: 11_155_111,
        status: "settled",
        started_at: older,
        ends_at: DateTime.add(older, 86_400, :second)
      })
    )

    Repo.insert!(
      %Job{}
      |> Job.create_changeset(%{
        job_id: "job_old",
        owner_address: "0x1111111111111111111111111111111111111111",
        agent_id: "11155111:11",
        token_name: "Mature Coin",
        token_symbol: "MAT",
        agent_safe_address: "0x1111111111111111111111111111111111111111",
        network: "ethereum-sepolia",
        chain_id: 11_155_111,
        status: "ready",
        step: "ready",
        total_supply: "1000",
        message: "signed",
        siwa_nonce: "nonce-old",
        siwa_signature: "sig",
        issued_at: older
      })
    )

    Repo.get!(Job, "job_old")
    |> Job.update_changeset(%{
      token_address: "0xdddddddddddddddddddddddddddddddddddddddd",
      pool_id: "0x" <> String.duplicate("e", 64),
      subject_id: "0x" <> String.duplicate("2", 64),
      revenue_share_splitter_address: "0xffffffffffffffffffffffffffffffffffffffff"
    })
    |> Repo.update!()

    [row] = Launch.list_auctions()
    assert row.id == "auc_new"
    assert row.phase == "biddable"

    [live_row] = Launch.list_auctions(%{"mode" => "live", "sort" => "market_cap_desc"}, nil)
    assert live_row.id == "auc_old"
    assert live_row.current_price_usdc == "0.011"
    assert live_row.implied_market_cap_usdc == "1100000000"
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

    assert {:ok, response} = Launch.get_job_response("job_prompt")

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
    assert response.job.trust.ens.connected
    assert response.job.trust.ens.name == "atlas.eth"
    refute response.job.trust.world.connected
    assert response.job.trust.world.human_id == nil
    assert response.job.trust.world.launch_count == 0
    refute response.job.completion_plan.agentbook.attached
    assert response.job.reputation_prompt.prompt =~ "optionally link an ENS name"
    assert response.job.reputation_prompt.skip_label == "Skip for now"
    refute Map.has_key?(response.job, :ens_name)
    refute Map.has_key?(response.job, :ens_attached)
    refute Map.has_key?(response.job, :world_registered)
    refute Map.has_key?(response.job, :world_human_id)
    refute Map.has_key?(response.job, :world_network)
    refute Map.has_key?(response.job, :world_launch_count)
    refute Map.has_key?(response.job, :emission_recipient)
    refute Map.has_key?(response.job, :epoch_seconds)

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
        assert {:ok, response} = Launch.get_job_response("job_canonical_output")

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
