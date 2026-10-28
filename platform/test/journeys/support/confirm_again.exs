# One launch per review (scripts/agent-journeys.sh): the launch the page just
# confirmed is confirmed again, eight times at once, half as the page's own
# confirmation of its review and half as launch discovery finding it on the
# chain, against the copy of Base. Prints, as JSON, every answer, how many
# auction rows carry the launch's auction, and the review's state. Run with the
# journey site's settings: JOURNEY_LAUNCHER, JOURNEY_SYMBOL, JOURNEY_LAUNCH_HASH.
Logger.configure(level: :warning)
{:ok, _apps} = Application.ensure_all_started([:postgrex, :ash, :phoenix_pubsub, :req])

{:ok, _pid} =
  Supervisor.start_link(
    [{Autolaunch.Repo, pool_size: 4}, {Phoenix.PubSub, name: Autolaunch.PubSub}],
    strategy: :one_for_one
  )

alias Autolaunch.{LaunchReviews, Repo}

launcher = System.fetch_env!("JOURNEY_LAUNCHER")
hash = System.fetch_env!("JOURNEY_LAUNCH_HASH")
chain_id = 31_337

{:ok, reviews} =
  Autolaunch.list_stocks_launch_reviews_for_signer(launcher, chain_id,
    actor: %Autolaunch.Actors.System{}
  )

review =
  Enum.find(reviews, &(&1.review["facts"]["symbol"] == System.fetch_env!("JOURNEY_SYMBOL")))

answers =
  1..8
  |> Task.async_stream(
    fn
      turn when rem(turn, 2) == 0 ->
        LaunchReviews.confirm(:stocks_launch, review.action_id, hash)

      _turn ->
        LaunchReviews.recover(:stocks_launch, %{
          chain_id: chain_id,
          launcher: launcher,
          transaction_hash: hash
        })
    end,
    max_concurrency: 8,
    timeout: 60_000
  )
  |> Enum.map(fn {:ok, {:listed, account_id, result}} ->
    %{account: account_id, auction: result["auction"]}
  end)

[%{auction: auction} | _] = answers

%{rows: [[rows]]} =
  Repo.query!(
    "SELECT count(*) FROM autolaunch_app.auctions WHERE lower(auction_address) = lower($1)",
    [auction]
  )

%{rows: [[state]]} =
  Repo.query!("SELECT state FROM autolaunch_app.stock_launch_operations WHERE id = $1", [
    Ecto.UUID.dump!(review.id)
  ])

IO.puts(
  "JOURNEY_RESULT " <> Jason.encode!(%{answers: answers, auction_rows: rows, review_state: state})
)
