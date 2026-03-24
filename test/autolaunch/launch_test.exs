defmodule Autolaunch.LaunchTest do
  use Autolaunch.DataCase, async: true

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

  test "chain options expose ethereum mainnet only" do
    assert Enum.map(Launch.chain_options(), & &1.id) == [1]
  end

  test "auction listings expose ENS and world completion state" do
    now = DateTime.utc_now()

    {:ok, _first} =
      %Auction{}
      |> Auction.changeset(%{
        source_job_id: "auc_first",
        agent_id: "1:42",
        agent_name: "Atlas",
        ens_name: "atlas.eth",
        owner_address: "0x1111111111111111111111111111111111111111",
        auction_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        token_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        network: "ethereum-mainnet",
        chain_id: 1,
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
        agent_id: "1:99",
        agent_name: "Nova",
        ens_name: nil,
        owner_address: "0x2222222222222222222222222222222222222222",
        auction_address: "0xcccccccccccccccccccccccccccccccccccccccc",
        token_address: "0xdddddddddddddddddddddddddddddddddddddddd",
        network: "ethereum-mainnet",
        chain_id: 1,
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
          agent_id: "1:42",
          token_name: "Atlas Coin",
          token_symbol: "ATLAS",
          network: "ethereum-mainnet",
          chain_id: 1,
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
        agent_id: "1:42",
        agent_name: "Atlas",
        owner_address: "0x1111111111111111111111111111111111111111",
        auction_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        token_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        network: "ethereum-mainnet",
        chain_id: 1,
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
          agent_id: "1:42",
          ens_name: "atlas.eth",
          token_name: "Atlas Coin",
          token_symbol: "ATLAS",
          network: "ethereum-mainnet",
          chain_id: 1,
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
      launch_fee_vault_address: "0xcccccccccccccccccccccccccccccccccccccccc",
      revenue_share_splitter_address: "0xdddddddddddddddddddddddddddddddddddddddd",
      subject_id: "0x" <> String.duplicate("1", 64)
    })
    |> Repo.update!()

    response = Launch.get_job_response("job_prompt")

    assert response.job.launch_fee_vault_address ==
             "0xcccccccccccccccccccccccccccccccccccccccc"

    assert response.job.revenue_share_splitter_address ==
             "0xdddddddddddddddddddddddddddddddddddddddd"

    assert response.job.subject_id == "0x" <> String.duplicate("1", 64)
    refute Map.has_key?(response.job, :emission_recipient)
    refute Map.has_key?(response.job, :default_ingress_address)
    refute Map.has_key?(response.job, :revenue_ingress_router_address)
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
end
