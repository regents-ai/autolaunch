defmodule Autolaunch.SafeOnlyRevstakeDraftsTest do
  @moduledoc """
  Every Revstake treasury is a Safe, so the migrations of 12 Nov 2026 make the
  drafts and launch reviews stored before it canonical, run the clean-up again
  in the release after, and drop the treasury kind's columns. They run here, in
  that order, over a row in each shape stored before: a Safe, a single key and
  a contract treasury, set by the person or by their agent, and launch reviews
  with and without the agent's list.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.{LaunchOperation, Repo, TestSupport}
  alias AutolaunchWeb.Components.AgentSetFields

  @safe "0x" <> String.duplicate("5a", 20)
  @key "0x" <> String.duplicate("e0", 20)
  @contract "0x" <> String.duplicate("c0", 20)
  @signer "0x" <> String.duplicate("ab", 20)
  @warning "I accept these problems, and wish to continue with EOA ownership of the token."

  setup_all do
    [clean_up, sweep, drop] =
      for {version, name} <- [
            {20_261_112_173_000, "safe_only_revstake_drafts"},
            {20_261_112_173_010, "sweep_safe_only_revstake_drafts"},
            {20_261_112_173_021, "drop_launch_draft_treasury_kind"}
          ] do
        [{migration, _bytecode}] =
          Code.require_file("priv/repo/migrations/#{version}_#{name}.exs")

        {version, migration}
      end

    %{clean_up: clean_up, sweep: sweep, drop: drop}
  end

  setup do
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)
  end

  # SAFE_ONLY_STORED_DRAFTS: a draft or launch review whose agent's list named
  # the treasury kind crashed the create page once that kind was gone, and any
  # save to such a draft was refused (review of the money-path fixes, 12 Nov
  # 2026). It fails if a stored draft's page does not open or take a Safe once
  # the columns are dropped, if a review's list cannot be named, if a single key
  # or contract treasury is kept, or if the second run changes anything.
  test "SAFE_ONLY_STORED_DRAFTS: drafts and reviews stored before every treasury was a Safe open and take a Safe, and a second run changes nothing",
       %{conn: conn, clean_up: clean_up, sweep: sweep, drop: drop} do
    # The columns as the release before the clean-up has them, then empty tables.
    migrate(drop, :down)
    migrate(clean_up, :up)

    drafts = %{
      agent_safe: old_draft!(@safe, "safe", nil, ~w(name treasury treasury_path)),
      agent_kind: old_draft!(@safe, "safe", nil, ~w(treasury_path)),
      person_key: old_draft!(@key, "eoa", @warning, ~w(name)),
      agent_contract: old_draft!(@contract, "contract", nil, ~w(symbol treasury treasury_path)),
      person_safe: old_draft!(@safe, "safe", nil, [])
    }

    reviews = %{
      agent_set:
        review!(drafts.agent_safe, %{"agent_set_fields" => ~w(name treasury treasury_path)}),
      agent_none: review!(drafts.person_safe, %{"agent_set_fields" => []}),
      before_agents: review!(drafts.person_safe, %{})
    }

    {before, _facts} = stored(drafts, reviews)

    migrate(clean_up, :up)
    {after_drafts, after_reviews} = settled = stored(drafts, reviews)

    assert %{
             agent_safe: {@safe, "safe", nil, ~w(name treasury), before.agent_safe.saved_at},
             agent_kind: {@safe, "safe", nil, [], before.agent_kind.saved_at},
             person_key: {nil, "safe", nil, ~w(name), before.person_key.saved_at},
             agent_contract: {nil, "safe", nil, ~w(symbol), before.agent_contract.saved_at},
             person_safe: {@safe, "safe", nil, [], before.person_safe.saved_at}
           } ==
             Map.new(after_drafts, fn {name, row} ->
               {name, {row.treasury, row.kind, row.warning, row.agent_set, row.saved_at}}
             end)

    assert AgentSetFields.labels(after_reviews.agent_set["agent_set_fields"]) ==
             ["Name", "Treasury address"]

    assert after_reviews.agent_none == reviews.agent_none.review["facts"]
    assert after_reviews.before_agents == reviews.before_agents.review["facts"]

    # A machine of the release before the clean-up saves on while both run.
    late = old_draft!(@contract, "contract", nil, ~w(treasury treasury_path))

    migrate(sweep, :up)
    assert stored(drafts, reviews) == settled
    assert %{treasury: nil, kind: "safe", warning: nil, agent_set: []} = row(late)

    migrate(drop, :up)

    for {_name, draft} <- Map.put(drafts, :late, late) do
      actor = %Human{human_account_id: draft.human_account_id}
      session = signed_in_session(draft.human_account_id)

      {:ok, view, _html} =
        conn
        |> Phoenix.ConnTest.init_test_session(session)
        |> connects_with(session)
        |> live("/agent-business")

      view
      |> form("#launch-treasury-details", launch_draft: %{treasury: @safe})
      |> render_change()

      assert {:ok, [%{treasury: @safe}]} = Autolaunch.list_my_launch_drafts(actor: actor)
    end
  end

  defp migrate({version, migration}, direction) do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      version,
      migration,
      :forward,
      direction,
      direction,
      log: false,
      prefix: Repo.config()[:migration_default_prefix]
    )
  end

  # A person's draft as it was stored before every treasury was a Safe.
  defp old_draft!(treasury, kind, warning, agent_set) do
    account = TestSupport.register_creator!()
    draft = Autolaunch.create_launch_draft!(%{}, actor: %Human{human_account_id: account.id})

    {1, _rows} =
      Repo.update_all(from(d in "launch_drafts", where: d.id == type(^draft.id, Ecto.UUID)),
        set: [
          treasury: treasury,
          treasury_path: kind,
          eoa_acknowledgement: warning,
          agent_set_fields: agent_set
        ]
      )

    draft
  end

  # Each draft's row and each review's facts, as stored.
  defp stored(drafts, reviews) do
    {Map.new(drafts, fn {name, draft} -> {name, row(draft)} end),
     Map.new(reviews, fn {name, review} -> {name, facts(review)} end)}
  end

  defp row(%{id: id}) do
    Repo.one!(
      from d in "launch_drafts",
        where: d.id == type(^id, Ecto.UUID),
        select: %{
          treasury: d.treasury,
          kind: d.treasury_path,
          warning: d.eoa_acknowledgement,
          agent_set: d.agent_set_fields,
          saved_at: d.updated_at
        }
    )
  end

  # A launch review saved for `draft`, its facts carrying `facts` besides its own.
  defp review!(draft, facts) do
    LaunchOperation
    |> Ash.Changeset.for_create(
      :prepare,
      %{
        action_id: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
        review: %{
          "chain" => %{"chain_id" => 8453, "name" => "Base"},
          "signer" => @signer,
          "step" => %{"kind" => "transaction", "step" => "launch", "to" => @safe, "data" => "0x"},
          "facts" => Map.merge(%{"draft_id" => draft.id, "name" => "Open Research"}, facts)
        },
        signer: @signer,
        step: :launch,
        human_account_id: draft.human_account_id,
        launch_draft_id: draft.id
      },
      actor: %System{}
    )
    |> Ash.create!(actor: %System{})
  end

  defp facts(%{id: id}), do: Ash.get!(LaunchOperation, id, actor: %System{}).review["facts"]
end
