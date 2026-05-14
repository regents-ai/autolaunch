defmodule Autolaunch.Repo.Migrations.AddTechtreeEvidenceRefToPrelaunchPlans do
  use Ecto.Migration

  def up do
    alter table(:autolaunch_prelaunch_plans) do
      add :techtree_evidence_packet_ref, :text
    end

    create index(:autolaunch_prelaunch_plans, [:agent_id, :techtree_evidence_packet_ref],
             where: "techtree_evidence_packet_ref IS NOT NULL"
           )
  end

  def down do
    raise "hard cutover only"
  end
end
