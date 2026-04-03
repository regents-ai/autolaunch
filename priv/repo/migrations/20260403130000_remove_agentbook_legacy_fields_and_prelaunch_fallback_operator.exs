defmodule Autolaunch.Repo.Migrations.RemoveAgentbookLegacyFieldsAndPrelaunchFallbackOperator do
  use Ecto.Migration

  def change do
    alter table(:autolaunch_agentbook_sessions) do
      remove :allow_legacy_proofs
      remove :preset
    end

    alter table(:autolaunch_prelaunch_plans) do
      remove :fallback_operator_wallet
    end
  end
end
