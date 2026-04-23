defmodule Autolaunch.Repo.Migrations.AddAutolaunchHotPathIndexes do
  use Ecto.Migration

  def change do
    create_if_not_exists index(
                           :autolaunch_jobs,
                           [:chain_id, :subject_id, :status, :updated_at],
                           name: :autolaunch_jobs_subject_ready_lookup_idx,
                           where: "status = 'ready'"
                         )

    create_if_not_exists index(
                           :autolaunch_auctions,
                           [:chain_id, :inserted_at],
                           name: :autolaunch_auctions_chain_inserted_idx
                         )

    create_if_not_exists index(
                           :autolaunch_auctions,
                           [:chain_id, :source_job_id],
                           name: :autolaunch_auctions_chain_source_job_idx
                         )

    create_if_not_exists index(
                           :autolaunch_bids,
                           [:owner_address, :chain_id, :inserted_at],
                           name: :autolaunch_bids_owner_chain_inserted_idx
                         )

    create_if_not_exists index(
                           :xmtp_membership_commands,
                           [:room_id, :status, :inserted_at, :id],
                           name: :xmtp_membership_commands_pending_lease_idx,
                           where: "status = 'pending'"
                         )
  end
end
