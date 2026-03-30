defmodule Autolaunch.Launch.Bid do
  @moduledoc false
  use Autolaunch.Schema

  @primary_key {:bid_id, :string, autogenerate: false}
  @sepolia_network "ethereum-sepolia"
  @sepolia_chain_id 11_155_111

  schema "autolaunch_bids" do
    field :privy_user_id, :string
    field :owner_address, :string
    field :auction_id, :string
    field :auction_address, :string
    field :chain_id, :integer, default: @sepolia_chain_id
    field :agent_id, :string
    field :agent_name, :string
    field :network, :string, default: @sepolia_network
    field :onchain_bid_id, :string
    field :submit_tx_hash, :string
    field :submit_block_number, :integer
    field :exit_tx_hash, :string
    field :claim_tx_hash, :string
    field :amount, :decimal
    field :max_price, :decimal
    field :current_clearing_price, :decimal
    field :current_status, :string, default: "active"
    field :estimated_tokens_if_end_now, :decimal
    field :estimated_tokens_if_no_other_bids_change, :decimal
    field :inactive_above_price, :decimal
    field :quote_snapshot, :map
    field :exited_at, :utc_datetime_usec
    field :claimed_at, :utc_datetime_usec

    timestamps()
  end

  def create_changeset(bid, attrs) do
    bid
    |> cast(attrs, [
      :bid_id,
      :privy_user_id,
      :owner_address,
      :auction_id,
      :auction_address,
      :chain_id,
      :agent_id,
      :agent_name,
      :network,
      :onchain_bid_id,
      :submit_tx_hash,
      :submit_block_number,
      :exit_tx_hash,
      :claim_tx_hash,
      :amount,
      :max_price,
      :current_clearing_price,
      :current_status,
      :estimated_tokens_if_end_now,
      :estimated_tokens_if_no_other_bids_change,
      :inactive_above_price,
      :quote_snapshot,
      :exited_at,
      :claimed_at
    ])
    |> validate_required([
      :bid_id,
      :owner_address,
      :auction_id,
      :chain_id,
      :agent_id,
      :network,
      :amount,
      :max_price,
      :current_clearing_price,
      :current_status
    ])
    |> validate_inclusion(:network, [@sepolia_network])
    |> validate_inclusion(:chain_id, [@sepolia_chain_id])
  end

  def update_changeset(bid, attrs) do
    cast(bid, attrs, [
      :current_status,
      :quote_snapshot,
      :submit_tx_hash,
      :submit_block_number,
      :exit_tx_hash,
      :claim_tx_hash,
      :exited_at,
      :claimed_at
    ])
  end
end
