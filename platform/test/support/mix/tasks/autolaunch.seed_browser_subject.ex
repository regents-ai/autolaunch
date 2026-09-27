defmodule Mix.Tasks.Autolaunch.SeedBrowserSubject do
  use Mix.Task

  @shortdoc "Seeds, or removes, the deterministic subject the browser suite can open"

  @moduledoc """
  Seeds one public subject the launchpad browser spec can open.

  The browser proof and `mix test` share one local test database, and a public
  subject that outlived a browser run would change what the ordinary suite sees
  listed. So this subject exists only for the life of the browser server: the
  seed removes any earlier one before creating its own, and `--remove` takes it
  away again when that server stops.
  """

  alias Autolaunch.TestSupport

  @subject_id "subject:browser:wallet"

  @impl true
  def run(args) do
    env = Mix.env()
    Mix.Task.run("app.config")
    validate_target!(env, Autolaunch.Repo.config())
    Mix.Task.run("app.start")

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Autolaunch.Repo, fn ->
      if "--remove" in args, do: remove!(), else: seed!()
    end)
  end

  @doc "The subject identity the browser suite visits."
  @spec subject_id() :: String.t()
  def subject_id, do: @subject_id

  @doc "Replaces any earlier browser subject with a fresh one."
  @spec seed!() :: :ok
  def seed! do
    remove!()

    TestSupport.project_subject(
      subject_id: @subject_id,
      subject_kind: "agent",
      chain_id: 8453,
      token_address: Autolaunch.SubjectWalletFixture.token(),
      splitter_address: Autolaunch.SubjectWalletFixture.splitter(),
      treasury_address: Autolaunch.SubjectWalletFixture.treasury(),
      creator_address: Autolaunch.SubjectWalletFixture.wallet(),
      canonical_receiver_address: Autolaunch.SubjectWalletFixture.receiver()
    )

    :ok
  end

  @doc "Takes the browser subject, and anything it owns, back out of the shared database."
  @spec remove!() :: :ok
  def remove! do
    delete!("DELETE FROM subject_wallet_operations WHERE subject_id = $1")

    delete!("""
    DELETE FROM subject_actions
     WHERE subject_id IN (SELECT id FROM subjects WHERE subject_id = $1)
    """)

    delete!("DELETE FROM tokens WHERE subject_id = $1")
    delete!("DELETE FROM subjects WHERE subject_id = $1")
    :ok
  end

  @doc "Refuses any database that is not a local test database."
  def validate_target!(env, repo_config) when is_list(repo_config) do
    database = to_string(repo_config[:database])
    hostname = to_string(repo_config[:hostname])

    if env == :test and String.ends_with?(database, "_test") and
         hostname in ["127.0.0.1", "localhost"] do
      :ok
    else
      raise "browser Autolaunch subject seed refused unsafe database target"
    end
  end

  defp delete!(sql), do: Ecto.Adapters.SQL.query!(Autolaunch.Repo, sql, [@subject_id])
end
