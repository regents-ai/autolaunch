defmodule Autolaunch.LaunchJobTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Actors.System
  alias Autolaunch.TestSupport

  @unsafe_job_ids [
    slash: "launch/slash",
    query: "launch?query",
    fragment: "launch#fragment",
    percent: "launch%encoded",
    space: "launch identity",
    unicode: "launch-é",
    too_long: String.duplicate("a", 129)
  ]

  test "anonymous reads expose launch progress, identity, auction linkage, addresses, and times" do
    auction =
      TestSupport.project_auction(
        title: "Launch job auction",
        state: :active,
        opened_at: DateTime.utc_now()
      )

    started_at = ~U[2026-07-30 10:00:00.000000Z]
    finished_at = ~U[2026-07-30 10:15:00.000000Z]

    launch =
      TestSupport.project_launch(
        job_id: "launch:resource",
        auction_id: auction.id,
        status: "complete",
        step: "record_addresses",
        started_at: started_at,
        finished_at: finished_at
      )

    assert {:ok, launches} = Autolaunch.list_launches()
    assert launch.job_id in Enum.map(launches, & &1.job_id)

    assert {:ok, public} = Autolaunch.get_public_launch(launch.job_id)
    assert public.status == "complete"
    assert public.step == "record_addresses"
    assert public.agent_id == "agent:resource"
    assert public.agent_name == "Resource Agent"
    assert public.token_name == "Resource Token"
    assert public.token_symbol == "RSC"
    assert public.chain_id == 8453
    assert public.auction_id == auction.id
    assert public.agent_safe_address == "0x1111111111111111111111111111111111111111"
    assert public.auction_address == "0x2222222222222222222222222222222222222222"
    assert public.token_address == "0x3333333333333333333333333333333333333333"
    assert public.hook_address == "0x4444444444444444444444444444444444444444"

    assert public.revenue_share_splitter_address ==
             "0x5555555555555555555555555555555555555555"

    assert public.started_at == started_at
    assert public.finished_at == finished_at
    assert {:ok, nil} = Autolaunch.get_public_launch("launch:missing")
  end

  test "canonical launch identities reject every value unsafe for the public route" do
    for {unsafe_class, job_id} <- @unsafe_job_ids do
      assert {:error, %Ash.Error.Invalid{} = error} = project_launch(job_id)

      message = Exception.message(error)
      assert message =~ "job_id", "#{unsafe_class} did not identify the invalid field"

      assert message =~ "must match the pattern" or
               message =~ "length must be less than or equal to 128",
             "#{unsafe_class} did not explain the canonical ID format"
    end
  end

  test "launch projection requires the real system actor" do
    for actor <- [nil, %{role: :system}, %{role: :human, human_account_id: 1}] do
      assert {:error, %Ash.Error.Forbidden{}} =
               project_launch("launch:forbidden", actor: actor)
    end

    assert {:ok, launch} = project_launch("launch:system", actor: %System{})
    assert launch.job_id == "launch:system"
  end

  defp project_launch(job_id, attrs \\ []) do
    Autolaunch.project_lab_launch(
      %{
        job_id: job_id,
        status: Keyword.get(attrs, :status, "running"),
        step: Keyword.get(attrs, :step, "deploy_token"),
        agent_id: Keyword.get(attrs, :agent_id, "agent:resource"),
        agent_name: Keyword.get(attrs, :agent_name, "Resource Agent"),
        token_name: Keyword.get(attrs, :token_name, "Resource Token"),
        token_symbol: Keyword.get(attrs, :token_symbol, "RSC"),
        chain_id: Keyword.get(attrs, :chain_id, 8453),
        auction_id: Keyword.get(attrs, :auction_id),
        agent_safe_address:
          Keyword.get(attrs, :agent_safe_address, "0x1111111111111111111111111111111111111111"),
        auction_address:
          Keyword.get(attrs, :auction_address, "0x2222222222222222222222222222222222222222"),
        token_address:
          Keyword.get(attrs, :token_address, "0x3333333333333333333333333333333333333333"),
        hook_address:
          Keyword.get(attrs, :hook_address, "0x4444444444444444444444444444444444444444"),
        revenue_share_splitter_address:
          Keyword.get(
            attrs,
            :revenue_share_splitter_address,
            "0x5555555555555555555555555555555555555555"
          ),
        started_at: Keyword.get(attrs, :started_at),
        finished_at: Keyword.get(attrs, :finished_at)
      },
      actor: Keyword.get(attrs, :actor, %System{})
    )
  end
end
