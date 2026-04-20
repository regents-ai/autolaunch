defmodule Autolaunch.TrustTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Trust

  test "summary_for_agent rejects malformed agent ids" do
    assert {:error, :invalid_agent_id} = Trust.summary_for_agent("not-an-agent-id")
    assert {:error, :invalid_agent_id} = Trust.summary_for_agent("8453:   ")
  end

  test "compose_summary only marks ERC-8004 as connected when the identity exists" do
    summary =
      Trust.compose_summary("84532:42", nil, %{
        ens_name: nil,
        world_connected: false,
        world_human_id: nil,
        world_network: "world",
        world_launch_count: 0,
        x_account: nil
      })

    assert summary.erc8004.connected == false
    assert summary.erc8004.agent_id == "84532:42"
    assert summary.erc8004.chain_id == 84_532
    assert summary.erc8004.token_id == "42"
  end
end
