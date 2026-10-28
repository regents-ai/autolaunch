# Drops the agent journeys' own database (scripts/agent-journeys.sh), before a run
# starts and once it ends, even while the run's server is still connected to it.
# It refuses any database but one of the journeys' own (named after their checkout,
# scripts/agent-journeys.sh), on this machine.
repo = Autolaunch.Repo.config()

unless to_string(repo[:hostname]) in ["127.0.0.1", "::1"] and
         Regex.match?(~r/\Aautolaunch_agents_[0-9a-f]{6}_test\z/, to_string(repo[:database])),
       do: raise("the agent journeys drop only their own local database")

case Ecto.Adapters.Postgres.storage_down(Keyword.put(repo, :force_drop, true)) do
  :ok -> :ok
  {:error, :already_down} -> :ok
  {:error, reason} -> raise("#{repo[:database]} is left: #{inspect(reason)}")
end
