# The end of a browser walk: drop the database made for this run
# (test/browser/walk.sh), even while the walk's server is still connected to it.
# It refuses any database but a walk's own local one.
repo = Autolaunch.Repo.config()

unless to_string(repo[:hostname]) in ["127.0.0.1", "::1"] and
         Regex.match?(~r/\Aautolaunch_browser_\d+_test\z/, to_string(repo[:database])),
       do: raise("the browser walk drops only its own local database")

case Ecto.Adapters.Postgres.storage_down(Keyword.put(repo, :force_drop, true)) do
  :ok -> :ok
  {:error, :already_down} -> :ok
  {:error, reason} -> raise("the walk's database #{repo[:database]} is left: #{inspect(reason)}")
end
