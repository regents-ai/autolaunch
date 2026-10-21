defmodule Autolaunch.AgentDraftsTest do
  @moduledoc """
  A paired agent fills in a whole launch draft: the token's details, its
  picture and its launch settings. Every field it set is named until the
  person changes it, and the person's own acknowledgement for a treasury
  owned by a private key is never the agent's to give.
  """
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.{AgentDrafts, Agents, TestSupport}

  @wallet "0x" <> String.duplicate("cd", 20)
  @treasury "0x" <> String.duplicate("7a", 20)
  @aapl "0xb200000000000000000000c2e324d24d7eecd1fb"
  @route "0x547f3b931eaf75bab98364ab396058ddc2e68e4a"
  @picture File.read!("test/support/fixtures/launch-draft.png")

  setup do
    account = TestSupport.register_creator!()

    code =
      RegentAgents.issue_pairing_code!(
        actor: %RegentAgents.Person{privy_user_id: account.privy_user_id}
      )

    RegentAgents.pair_agent!(code.code, "Draft Agent", :codex,
      actor: %RegentAgents.Agent{wallet: @wallet}
    )

    {:ok, agent, _account} = Agents.resolve(@wallet)
    {:ok, agent: agent, person: %Human{human_account_id: account.id}}
  end

  test "an agent fills a whole Revstake draft, picture and treasury included, and each field is named",
       %{agent: agent} do
    picture = %{"content_type" => "image/png", "data" => Base.encode64(@picture)}

    assert {:ok, draft} =
             AgentDrafts.save(
               "revstake",
               %{
                 "name" => "Research Agent",
                 "symbol" => "rsrch",
                 "description" => "Earns stablecoins for its stakers.",
                 "treasury" => @treasury,
                 "treasury_path" => "contract",
                 "image" => picture
               },
               agent
             )

    assert draft.symbol == "RSRCH"
    assert draft.treasury == @treasury
    assert draft.treasury_path == :contract
    assert draft.image =~ "/images/"

    assert Enum.sort(draft.agent_set_fields) ==
             Enum.sort([:name, :symbol, :description, :treasury, :treasury_path, :image])

    assert %{agent_set_fields: _, treasury: @treasury} = AgentDrafts.present(draft)
  end

  test "the person's own edits leave the agent's list; their EOA acknowledgement is never the agent's",
       %{agent: agent, person: person} do
    {:ok, _draft} =
      AgentDrafts.save("revstake", %{"name" => "Agent Name", "treasury" => @treasury}, agent)

    {:ok, draft} =
      Autolaunch.LaunchDraft
      |> Ash.Query.for_read(:agent_read, %{}, actor: agent)
      |> Ash.read_one()

    acknowledged =
      draft
      |> Ash.Changeset.for_update(
        :autosave_treasury,
        %{treasury: @treasury, treasury_path: :eoa, eoa_acknowledgement: "typed by the person"},
        actor: person
      )
      |> Ash.update!()

    # The person chose the path; the agent's treasury is still theirs to check.
    assert :treasury in acknowledged.agent_set_fields
    refute :treasury_path in acknowledged.agent_set_fields

    renamed =
      acknowledged
      |> Ash.Changeset.for_update(:autosave_token_details, %{name: "Person Name"}, actor: person)
      |> Ash.update!()

    refute :name in renamed.agent_set_fields

    # An agent changing the treasury takes back the person's acknowledgement.
    {:ok, changed} =
      AgentDrafts.save("revstake", %{"treasury" => "0x" <> String.duplicate("7b", 20)}, agent)

    assert changed.eoa_acknowledgement == nil

    for refused <- [
          %{"eoa_acknowledgement" => "typed by the agent"},
          %{"name" => 7},
          %{"wallet" => @wallet},
          %{"image" => %{"content_type" => "image/png", "data" => "not base64!"}},
          %{}
        ] do
      assert {:error, :invalid_draft} = AgentDrafts.save("revstake", refused, agent)
    end

    assert {:error, :invalid_image} =
             AgentDrafts.save(
               "revstake",
               %{
                 "image" => %{
                   "content_type" => "image/png",
                   "data" => Base.encode64("plain text")
                 }
               },
               agent
             )
  end

  test "an agent fills a Memestock draft's chain and stock, and only a stock the chain lists",
       %{agent: agent} do
    Autolaunch.record_stock_admission!(
      %{
        chain_id: 8453,
        address: @aapl,
        symbol: "AAPLc",
        name: "Apple Inc.",
        decimals: 8,
        route: @route,
        admitted: true
      },
      actor: %System{}
    )

    assert {:ok, draft} =
             AgentDrafts.save(
               "memestock",
               %{
                 "name" => "Apple Pair",
                 "symbol" => "APLP",
                 "chain" => "base",
                 "stock_address" => @aapl
               },
               agent
             )

    assert draft.stock_address == @aapl
    assert :stock_address in draft.agent_set_fields

    assert {:error, :invalid_draft} =
             AgentDrafts.save(
               "memestock",
               %{"stock_address" => "0x" <> String.duplicate("99", 20)},
               agent
             )

    assert {:error, :invalid_draft} =
             AgentDrafts.save("memestock", %{"treasury" => @treasury}, agent)
  end
end
