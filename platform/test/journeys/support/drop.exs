# Drops the agent journeys' own database (scripts/agent-journeys.sh), before a run
# starts and once it ends, even while the run's server is still connected to it.
# It refuses any database but that one, on this machine.
repo = Autolaunch.Repo.config()

unless to_string(repo[:hostname]) in ["127.0.0.1", "::1"] and
         to_string(repo[:database]) == "autolaunch_agents_test",
       do: raise("the agent journeys drop only their own local database")

case Ecto.Adapters.Postgres.storage_down(Keyword.put(repo, :force_drop, true)) do
  :ok -> :ok
  {:error, :already_down} -> :ok
  {:error, reason} -> raise("#{repo[:database]} is left: #{inspect(reason)}")
end
