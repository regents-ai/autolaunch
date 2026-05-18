defmodule Autolaunch.PrelaunchTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.Prelaunch
  alias Autolaunch.Prelaunch.Plan

  setup do
    human =
      %HumanUser{}
      |> HumanUser.changeset(%{
        privy_user_id: "did:privy:prelaunch-test",
        wallet_address: "0x1111111111111111111111111111111111111111"
      })
      |> Repo.insert!()

    %Plan{}
    |> Plan.create_changeset(%{
      plan_id: "plan_metadata",
      privy_user_id: human.privy_user_id,
      state: "draft",
      agent_id: "8453:42",
      chain_id: 8_453,
      token_name: "Atlas Coin",
      token_symbol: "ATLAS",
      agent_safe_address: "0x1111111111111111111111111111111111111111",
      metadata_draft: %{}
    })
    |> Repo.insert!()

    %{human: human}
  end

  test "new prelaunch plan structs default to Base mainnet" do
    assert %Plan{}.chain_id == 8_453
  end

  test "prelaunch plans save decimal REGENT minimum raises as 18-decimal raw amounts" do
    actor = %{
      "wallet_address" => "0x1111111111111111111111111111111111111111",
      "chain_id" => "8453",
      "registry_address" => "0x2222222222222222222222222222222222222222",
      "token_id" => "44",
      "label" => "Atlas"
    }

    assert {:ok,
            %{
              minimum_raise_quote: "1.500000000000000000",
              minimum_raise_quote_raw: "1500000000000000000"
            }} =
             Prelaunch.create_plan(
               %{
                 "agent_id" => "8453:44",
                 "token_name" => "Atlas Coin",
                 "token_symbol" => "ATLAS",
                 "minimum_raise_quote" => "1.5",
                 "agent_safe_address" => "0x1111111111111111111111111111111111111111"
               },
               actor
             )
  end

  test "metadata updates require the canonical metadata wrapper", %{human: human} do
    assert {:error, :metadata_required} =
             Prelaunch.update_metadata("plan_metadata", %{"title" => "Flat title"}, human)

    assert Repo.get_by!(Plan, plan_id: "plan_metadata").metadata_draft == %{}
  end

  test "metadata updates save canonical metadata", %{human: human} do
    assert {:ok, %{plan: %{metadata_draft: %{"title" => "Atlas Launch"}}}} =
             Prelaunch.update_metadata(
               "plan_metadata",
               %{"metadata" => %{"title" => "Atlas Launch"}},
               human
             )
  end

  test "supporting evidence lists Techtree evidence references for the agent", %{human: human} do
    %Plan{}
    |> Plan.create_changeset(%{
      plan_id: "plan_techtree_evidence",
      privy_user_id: human.privy_user_id,
      state: "draft",
      agent_id: "8453:42",
      chain_id: 8_453,
      token_name: "Atlas Coin",
      token_symbol: "ATLAS",
      agent_safe_address: "0x1111111111111111111111111111111111111111",
      techtree_evidence_packet_ref: "techtree:fold:evidence:agent:42",
      metadata_draft: %{}
    })
    |> Repo.insert!()

    assert {:ok,
            [
              %{
                kind: "techtree_evidence_packet",
                label: "Techtree evidence",
                ref: "techtree:fold:evidence:agent:42",
                source: "techtree"
              }
            ]} = Prelaunch.supporting_evidence_for_agent("8453:42", human)
  end
end
