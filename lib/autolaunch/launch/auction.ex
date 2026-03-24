defmodule Autolaunch.Launch.Auction do
  @moduledoc false
  use Autolaunch.Schema

  schema "autolaunch_auctions" do
    field :source_job_id, :string
    field :agent_id, :string
    field :agent_name, :string
    field :ens_name, :string
    field :owner_address, :string
    field :auction_address, :string
    field :token_address, :string
    field :network, :string, default: "ethereum-mainnet"
    field :chain_id, :integer, default: 1
    field :status, :string, default: "active"
    field :started_at, :utc_datetime_usec
    field :ends_at, :utc_datetime_usec
    field :claim_at, :utc_datetime_usec
    field :bidders, :integer, default: 0
    field :raised_currency, :string, default: "0 USDC"
    field :target_currency, :string, default: "150,000 USDC"
    field :progress_percent, :integer, default: 0
    field :metrics_updated_at, :utc_datetime_usec
    field :notes, :string
    field :uniswap_url, :string
    field :world_network, :string, default: "world"
    field :world_registered, :boolean, default: false
    field :world_human_id, :string

    timestamps()
  end

  def changeset(auction, attrs) do
    auction
    |> cast(attrs, [
      :source_job_id,
      :agent_id,
      :agent_name,
      :ens_name,
      :owner_address,
      :auction_address,
      :token_address,
      :network,
      :chain_id,
      :status,
      :started_at,
      :ends_at,
      :claim_at,
      :bidders,
      :raised_currency,
      :target_currency,
      :progress_percent,
      :metrics_updated_at,
      :notes,
      :uniswap_url,
      :world_network,
      :world_registered,
      :world_human_id
    ])
    |> validate_required([
      :agent_id,
      :agent_name,
      :owner_address,
      :auction_address,
      :network,
      :chain_id,
      :status,
      :started_at
    ])
  end
end
