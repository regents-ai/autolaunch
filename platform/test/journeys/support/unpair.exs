# The person unpairs their agent as regents.sh does it, through the shared
# pairing library on the shared database (`RegentAgents.unpair_agent/2`), so the
# journeys can check what Autolaunch does once an agent is unpaired elsewhere.
# Run with the journey site's settings: JOURNEY_PERSON (a Privy id) and
# JOURNEY_AGENT (the agent's wallet).
{:ok, _apps} = Application.ensure_all_started([:postgrex, :ash, :phoenix_pubsub])

{:ok, _pid} =
  Supervisor.start_link(
    [{Autolaunch.Repo, pool_size: 1}, {Phoenix.PubSub, name: Autolaunch.PubSub}],
    strategy: :one_for_one
  )

person = %RegentAgents.Person{privy_user_id: System.fetch_env!("JOURNEY_PERSON")}
wallet = System.fetch_env!("JOURNEY_AGENT")
{:ok, agents} = RegentAgents.list_my_agents(actor: person)
:ok = agents |> Enum.find(&(&1.wallet == wallet)) |> RegentAgents.unpair_agent(actor: person)
IO.puts("unpaired #{wallet}")
