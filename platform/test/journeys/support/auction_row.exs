# The auction row the site keeps for one auction (scripts/agent-journeys.sh):
# where it came from, the account and wallet it names as creator, and whether
# that account is JOURNEY_PERSON's. Prints them as JSON. Run with the journey
# site's settings: JOURNEY_AUCTION, JOURNEY_PERSON.
Logger.configure(level: :warning)
{:ok, _apps} = Application.ensure_all_started([:postgrex, :ash, :phoenix_pubsub, :req])

{:ok, _pid} =
  Supervisor.start_link(
    [{Autolaunch.Repo, pool_size: 2}, {Phoenix.PubSub, name: Autolaunch.PubSub}],
    strategy: :one_for_one
  )

{:ok, person} =
  Autolaunch.Accounts.get_by_privy_did(System.fetch_env!("JOURNEY_PERSON"),
    actor: %Autolaunch.Actors.System{}
  )

%{rows: [[origin, account_id, wallet, image, website]]} =
  Autolaunch.Repo.query!(
    """
    SELECT origin, creator_human_account_id, creator_address, image, website
    FROM autolaunch_app.auctions WHERE lower(auction_address) = lower($1)
    """,
    [System.fetch_env!("JOURNEY_AUCTION")]
  )

IO.puts(
  "JOURNEY_RESULT " <>
    Jason.encode!(%{
      origin: origin,
      creator_account: account_id,
      persons_account: account_id == person.id,
      creator_wallet: wallet,
      image: image,
      website: website
    })
)
