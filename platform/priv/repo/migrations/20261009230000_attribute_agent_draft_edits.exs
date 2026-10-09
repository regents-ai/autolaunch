defmodule Autolaunch.Repo.Migrations.AttributeAgentDraftEdits do
  use Ecto.Migration

  def change do
    alter table(:launch_drafts) do
      add :last_agent_pairing_id, :uuid
    end

    alter table(:stock_launch_drafts) do
      add :last_agent_pairing_id, :uuid
    end
  end
end
