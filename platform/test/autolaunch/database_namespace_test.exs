defmodule Autolaunch.DatabaseNamespaceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Indexer.Ledger
  alias Autolaunch.Release
  alias Autolaunch.Repo

  setup do
    unless Repo.config()[:database] ==
             "autolaunch" <> System.fetch_env!("MIX_TEST_PARTITION") <> "_test" do
      raise "Namespace tests require the prepared disposable database"
    end

    original = Application.fetch_env!(:autolaunch, Repo)
    on_exit(fn -> Application.put_env(:autolaunch, Repo, original) end)

    Application.put_env(
      :autolaunch,
      Repo,
      Keyword.put(original, :default_prefix, "autolaunch_app")
    )

    dynamic = start_supervised!({Repo, name: nil, pool_size: 2})
    Repo.put_dynamic_repo(dynamic)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(dynamic)

    Repo.query!("CREATE SCHEMA autolaunch_app")

    for table <-
          ~w(human_accounts linked_identities session_authorities indexer_cursors indexer_sources schema_migrations) do
      Repo.query!("CREATE TABLE autolaunch_app.#{table} (LIKE public.#{table} INCLUDING ALL)")
    end

    Repo.query!(
      "INSERT INTO autolaunch_app.schema_migrations SELECT * FROM public.schema_migrations"
    )

    # Release validation requires a direct URL even while this test's already
    # started dynamic Repo owns the disposable connection.
    for {name, value} <- [
          {"AUTOLAUNCH_DEPLOYMENT_ROLE", "staging"},
          {"DATABASE_DIRECT_URL", "postgres://fixture:fixture@127.0.0.1/#{original[:database]}"}
        ] do
      prior = System.get_env(name)
      System.put_env(name, value)
      on_exit(fn -> if prior, do: System.put_env(name, prior), else: System.delete_env(name) end)
    end

    :ok
  end

  test "session bulk seeding and Ash transitions stay in the product namespace" do
    wallet = "0x" <> String.duplicate("1", 40)

    account =
      Autolaunch.Accounts.register_verified!("did:privy:namespace", wallet, [wallet],
        actor: %Autolaunch.Actors.System{}
      )

    claim = SessionAuthority.bootstrap()
    assert {:ok, :bind, bound} = SessionAuthority.sign_in(claim, account.id)
    assert SessionAuthority.exact(bound) == {:ok, account.id}
    assert SessionAuthority.exact(claim) == {:error, :superseded}

    assert [[0]] ==
             Repo.query!("SELECT count(*) FROM public.human_accounts WHERE id=$1", [
               account.id
             ]).rows

    assert [[1]] == Repo.query!("SELECT count(*) FROM autolaunch_app.session_authorities").rows
  end

  test "ledger bulk insertion and subsequent Ash reads use the same namespace" do
    address = "0x" <> String.duplicate("a", 40)
    assert {:ok, source} = Ledger.admit_source(8453, address, 10)
    assert {:ok, same} = Ledger.admit_source(8453, address, 10)
    assert source.id == same.id
    assert [read] = Ledger.sources(8453)
    assert read.id == source.id
    assert {:ok, lease} = Ledger.acquire(8453, 1000)
    assert {:ok, _} = Ledger.release(lease)

    assert [[0]] ==
             Repo.query!("SELECT count(*) FROM public.indexer_sources WHERE id=$1", [
               Ecto.UUID.dump!(source.id)
             ]).rows

    assert [[1]] == Repo.query!("SELECT count(*) FROM autolaunch_app.indexer_cursors").rows
  end

  test "release preserves the selected schema and reads its ledger" do
    config = Release.migration_config!()
    assert config[:default_prefix] == "autolaunch_app"
    assert config[:migration_default_prefix] == "autolaunch_app"
    Repo.query!("DELETE FROM public.schema_migrations")
    assert capture_io(&Release.pending_migrations/0) == "none\n"
    assert {:ok, [], _} = Release.migrate()
    assert [[0]] == Repo.query!("SELECT count(*) FROM public.schema_migrations").rows
  end

  test "incomplete imported history cannot replay migrations into the shared database" do
    Repo.query!("DELETE FROM autolaunch_app.schema_migrations")
    public = Repo.query!("SELECT version FROM public.schema_migrations ORDER BY version").rows

    assert_raise RuntimeError, ~r/Import the complete Autolaunch schema/, fn ->
      Release.migrate()
    end

    assert public ==
             Repo.query!("SELECT version FROM public.schema_migrations ORDER BY version").rows

    assert [[0]] == Repo.query!("SELECT count(*) FROM autolaunch_app.schema_migrations").rows
  end
end
