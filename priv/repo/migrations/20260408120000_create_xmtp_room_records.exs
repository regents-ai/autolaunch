defmodule Autolaunch.Repo.Migrations.CreateXmtpRoomRecords do
  use Ecto.Migration

  def change do
    create table(:xmtp_rooms) do
      add :room_key, :string, null: false
      add :conversation_id, :string, null: false
      add :agent_wallet_address, :string, null: false
      add :agent_inbox_id, :string, null: false
      add :status, :string, null: false, default: "active"
      add :capacity, :integer, null: false, default: 200
      add :room_name, :string, null: false
      add :description, :text
      add :app_data, :string
      add :created_at_ns, :bigint, null: false
      add :last_activity_ns, :bigint, null: false
      add :snapshot, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:xmtp_rooms, [:room_key])
    create unique_index(:xmtp_rooms, [:conversation_id])

    create table(:xmtp_room_memberships) do
      add :room_id, references(:xmtp_rooms, on_delete: :delete_all), null: false
      add :wallet_address, :string, null: false
      add :inbox_id, :string, null: false
      add :principal_kind, :string, null: false, default: "human"
      add :display_name, :string
      add :membership_state, :string, null: false, default: "joined"
      add :last_seen_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:xmtp_room_memberships, [:room_id, :wallet_address])
    create unique_index(:xmtp_room_memberships, [:room_id, :inbox_id])
    create index(:xmtp_room_memberships, [:membership_state])

    create table(:xmtp_message_logs) do
      add :room_id, references(:xmtp_rooms, on_delete: :delete_all), null: false
      add :xmtp_message_id, :string, null: false
      add :conversation_id, :string, null: false
      add :sender_inbox_id, :string, null: false
      add :sender_wallet, :string
      add :sender_kind, :string
      add :sender_label, :string
      add :body, :text, null: false
      add :sent_at, :utc_datetime_usec, null: false
      add :website_visibility_state, :string, null: false, default: "visible"
      add :moderator_wallet, :string
      add :moderated_at, :utc_datetime_usec
      add :message_snapshot, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:xmtp_message_logs, [:xmtp_message_id])
    create index(:xmtp_message_logs, [:room_id, :sent_at])
    create index(:xmtp_message_logs, [:website_visibility_state])
  end
end
