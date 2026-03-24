defmodule Autolaunch.Repo.Migrations.AddLaunchCompletionTracking do
  use Ecto.Migration

  def change do
    alter table(:autolaunch_agentbook_sessions) do
      add :launch_job_id, :string
      add :human_id, :string
    end

    create index(:autolaunch_agentbook_sessions, [:launch_job_id])
    create index(:autolaunch_agentbook_sessions, [:human_id])
  end
end
