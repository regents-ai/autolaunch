config = Autolaunch.Repo.config()
partition = System.fetch_env!("MIX_TEST_PARTITION")

unless Mix.env() == :test and is_nil(config[:url]) and
         config[:hostname] in ["localhost", "127.0.0.1"] and
         config[:database] == System.fetch_env!("PGDATABASE") and
         String.length(partition) > 1 and String.contains?(config[:database], partition) do
  raise "Public-tool fixtures require the prepared isolated local test database"
end

{:ok, _} = Application.ensure_all_started(:autolaunch)
Logger.configure(level: :warning)
Ecto.Adapters.SQL.Sandbox.checkout(Autolaunch.Repo, sandbox: false)

alias Autolaunch.Actors.System
alias Autolaunch.TestSupport

active =
  TestSupport.project_auction(
    id: "a12ee155-c71b-4107-87fd-dab8c7e00001",
    title: "Public tool fixture",
    state: :active,
    opened_at: ~U[2026-09-05 00:00:00Z],
    current_clearing_price: "2.5"
  )

closed =
  TestSupport.project_auction(
    id: "a12ee155-c71b-4107-87fd-dab8c7e00002",
    title: "Closed public tool fixture",
    state: :graduated,
    current_clearing_price: "2.5"
  )

TestSupport.project_token(
  auction_id: closed.id,
  name: "Public fixture token",
  symbol: "TEST",
  graduated_at: ~U[2026-09-05 00:00:00Z]
)

report =
  Autolaunch.TestAutolaunchTreasuryChainClient.seed_verified!(
    "0x9999999999999999999999999999999999999999"
  )

Autolaunch.set_auction_treasury_security_report!(active, report.id, actor: %System{})
TestSupport.project_launch(job_id: "launch:webmcp-qa", auction_id: active.id)
IO.puts("Public-tool synthetic fixtures ready")
