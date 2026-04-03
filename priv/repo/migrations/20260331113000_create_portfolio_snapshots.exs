defmodule Autolaunch.Repo.Migrations.CreatePortfolioSnapshots do
  use Ecto.Migration

  def change do
    create table(:autolaunch_portfolio_snapshots) do
      add :human_id, references(:autolaunch_human_users, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      add :launched_tokens_payload, {:array, :map}, null: false, default: []
      add :staked_tokens_payload, {:array, :map}, null: false, default: []
      add :refreshed_at, :utc_datetime_usec
      add :refresh_started_at, :utc_datetime_usec
      add :next_manual_refresh_at, :utc_datetime_usec
      add :error_message, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:autolaunch_portfolio_snapshots, [:human_id])
    create index(:autolaunch_portfolio_snapshots, [:status])
  end
end
