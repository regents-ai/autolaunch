# The walk's person has four paired agents, paired the way an agent pairs, so the
# account menu has more than its three to choose from (account_menu.spec.ts): the
# first, Spare Agent, is the one the menu leaves out. Run by test/browser/walk.sh
# once the run's database is made; it refuses any database but a walk's own local one.
repo = Autolaunch.Repo.config()

unless to_string(repo[:hostname]) in ["127.0.0.1", "::1"] and
         Regex.match?(~r/\Aautolaunch_browser_\d+_test\z/, to_string(repo[:database])),
       do: raise("the browser walk pairs agents only on its own local database")

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Autolaunch.PubSub)
{:ok, _} = Autolaunch.Repo.start_link(pool_size: 2)

person = %RegentAgents.Person{privy_user_id: "did:privy:verified"}

for {name, digit} <- [
      {"Spare Agent", "f"},
      {"Walk Agent", "c"},
      {"Desktop Agent", "d"},
      {"Phone Agent", "e"}
    ] do
  code = RegentAgents.issue_pairing_code!(actor: person)

  RegentAgents.pair_agent!(code.code, name, :hermes,
    actor: %RegentAgents.Agent{wallet: "0x" <> String.duplicate(digit, 40)}
  )
end
