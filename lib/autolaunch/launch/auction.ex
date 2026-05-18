defmodule Autolaunch.Launch.Auction do
  @moduledoc false
  use Autolaunch.Schema

  @supported_networks Enum.map(Autolaunch.BaseChain.chains(), & &1.key)
  @supported_chain_ids Autolaunch.BaseChain.supported_chain_ids()

  schema "autolaunch_auctions" do
    field :source_job_id, :string
    field :agent_id, :string
    field :agent_name, :string
    field :ens_name, :string
    field :owner_address, :string
    field :auction_address, :string
    field :token_address, :string
    field :minimum_raise_quote, :string
    field :minimum_raise_quote_raw, :string
    field :auction_quote_token_address, :string
    field :auction_quote_token_symbol, :string, default: "REGENT"
    field :auction_quote_token_decimals, :integer, default: 18
    field :revenue_usdc_token_address, :string
    field :revenue_usdc_token_symbol, :string, default: "USDC"
    field :revenue_usdc_token_decimals, :integer, default: 6
    field :network, :string, default: "base-mainnet"
    field :chain_id, :integer, default: 8_453
    field :status, :string, default: "active"
    field :started_at, :utc_datetime_usec
    field :ends_at, :utc_datetime_usec
    field :claim_at, :utc_datetime_usec
    field :bidders, :integer, default: 0
    field :raised_currency, :string, default: "0 REGENT"
    field :target_currency, :string, default: "Not published"
    field :progress_percent, :integer, default: 0
    field :metrics_updated_at, :utc_datetime_usec
    field :chain_state, :string, default: "open"
    field :onchain_currency_raised_raw, :string
    field :onchain_required_currency_raised_raw, :string
    field :onchain_clearing_price_q96, :string
    field :onchain_start_block, :integer
    field :onchain_end_block, :integer
    field :onchain_claim_block, :integer
    field :onchain_graduated, :boolean, default: false
    field :onchain_block_number, :integer
    field :onchain_synced_at, :utc_datetime_usec
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
      :minimum_raise_quote,
      :minimum_raise_quote_raw,
      :auction_quote_token_address,
      :auction_quote_token_symbol,
      :auction_quote_token_decimals,
      :revenue_usdc_token_address,
      :revenue_usdc_token_symbol,
      :revenue_usdc_token_decimals,
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
      :chain_state,
      :onchain_currency_raised_raw,
      :onchain_required_currency_raised_raw,
      :onchain_clearing_price_q96,
      :onchain_start_block,
      :onchain_end_block,
      :onchain_claim_block,
      :onchain_graduated,
      :onchain_block_number,
      :onchain_synced_at,
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
    |> validate_inclusion(:network, @supported_networks)
    |> validate_inclusion(:chain_id, @supported_chain_ids)
    |> validate_inclusion(:chain_state, ~w(open graduated failed_minimum))
  end
end
