# The launch reviews the site keeps for one draft (scripts/agent-journeys.sh),
# oldest first: who prepared each (the person's page or their paired agent),
# its state, and the review exactly as saved (chain, signer, step and facts).
# Prints them as JSON. Run with the journey site's settings: JOURNEY_KIND
# (revstake or memestock) and JOURNEY_DRAFT, the draft's id.
Logger.configure(level: :warning)
{:ok, _apps} = Application.ensure_all_started([:postgrex, :ash, :phoenix_pubsub, :req])

{:ok, _pid} =
  Supervisor.start_link(
    [{Autolaunch.Repo, pool_size: 2}, {Phoenix.PubSub, name: Autolaunch.PubSub}],
    strategy: :one_for_one
  )

table =
  case System.fetch_env!("JOURNEY_KIND") do
    "revstake" -> "launch_operations"
    "memestock" -> "stock_launch_operations"
  end

%{rows: rows} =
  Autolaunch.Repo.query!(
    """
    SELECT prepared_by, state, envelope
    FROM autolaunch_app.#{table} WHERE launch_draft_id = $1
    ORDER BY inserted_at, id
    """,
    [Ecto.UUID.dump!(System.fetch_env!("JOURNEY_DRAFT"))]
  )

IO.puts(
  "JOURNEY_RESULT " <>
    Jason.encode!(
      Enum.map(rows, fn [prepared_by, state, review] ->
        %{prepared_by: prepared_by, state: state, review: review}
      end)
    )
)
