defmodule Autolaunch.Tokens.RevsplitToken do
  @moduledoc false
  use Autolaunch.Schema

  schema "autolaunch_revsplit_tokens" do
    field :chain_id, :integer
    field :token_address, :string
    field :source_auction_id, :string
    field :source_job_id, :string
    field :auction_address, :string
    field :agent_id, :string
    field :agent_name, :string
    field :token_symbol, :string
    field :subject_id, :string
    field :splitter_address, :string
    field :pool_id, :string
    field :uniswap_url, :string
    field :graduated_at, :utc_datetime_usec
    field :graduation_block, :integer
    field :auction_raise_raw, :string
    field :auction_raise_usdc, :string
    field :required_raise_raw, :string
    field :required_raise_usdc, :string
    field :clearing_price_usdc, :string
    field :price_usdc, :string
    field :price_source, :string
    field :price_updated_at, :utc_datetime_usec
    field :fdv_usdc, :string
    field :revsplit_status, :string, default: "active"
    field :last_synced_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [
      :chain_id,
      :token_address,
      :source_auction_id,
      :source_job_id,
      :auction_address,
      :agent_id,
      :agent_name,
      :token_symbol,
      :subject_id,
      :splitter_address,
      :pool_id,
      :uniswap_url,
      :graduated_at,
      :graduation_block,
      :auction_raise_raw,
      :auction_raise_usdc,
      :required_raise_raw,
      :required_raise_usdc,
      :clearing_price_usdc,
      :price_usdc,
      :price_source,
      :price_updated_at,
      :fdv_usdc,
      :revsplit_status,
      :last_synced_at
    ])
    |> validate_required([
      :chain_id,
      :token_address,
      :source_auction_id,
      :auction_address,
      :agent_id,
      :agent_name,
      :revsplit_status
    ])
    |> validate_inclusion(:revsplit_status, ~w(active paused retired))
    |> unique_constraint(:token_address, name: :autolaunch_revsplit_tokens_chain_token_unique)
  end
end
