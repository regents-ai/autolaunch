defmodule Autolaunch.Repo.Migrations.AddAuctionSyncStateAndRevsplitTokens do
  use Ecto.Migration

  def up do
    alter table(:autolaunch_auctions) do
      add :chain_state, :string, null: false, default: "open"
      add :onchain_currency_raised_raw, :text
      add :onchain_required_currency_raised_raw, :text
      add :onchain_clearing_price_q96, :text
      add :onchain_start_block, :bigint
      add :onchain_end_block, :bigint
      add :onchain_claim_block, :bigint
      add :onchain_graduated, :boolean, null: false, default: false
      add :onchain_block_number, :bigint
      add :onchain_synced_at, :utc_datetime_usec
    end

    create index(:autolaunch_auctions, [:chain_id, :chain_state, :updated_at],
             name: :autolaunch_auctions_chain_state_updated_idx
           )

    create table(:autolaunch_revsplit_tokens) do
      add :chain_id, :integer, null: false
      add :token_address, :string, null: false
      add :source_auction_id, :string, null: false
      add :source_job_id, :string
      add :auction_address, :string, null: false
      add :agent_id, :string, null: false
      add :agent_name, :string, null: false
      add :token_symbol, :string
      add :subject_id, :string
      add :splitter_address, :string
      add :pool_id, :string
      add :uniswap_url, :text
      add :graduated_at, :utc_datetime_usec
      add :graduation_block, :bigint
      add :auction_raise_raw, :text
      add :auction_raise_quote, :string
      add :required_raise_raw, :text
      add :required_raise_quote, :string
      add :clearing_price_quote, :string
      add :price_quote, :string
      add :price_source, :string
      add :price_updated_at, :utc_datetime_usec
      add :fdv_quote, :string
      add :revsplit_status, :string, null: false, default: "active"
      add :last_synced_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:autolaunch_revsplit_tokens, [:chain_id, :token_address],
             name: :autolaunch_revsplit_tokens_chain_token_unique
           )

    create index(:autolaunch_revsplit_tokens, [:chain_id, :graduated_at],
             name: :autolaunch_revsplit_tokens_chain_graduated_idx
           )

    create index(:autolaunch_revsplit_tokens, [:agent_id],
             name: :autolaunch_revsplit_tokens_agent_id_idx
           )

    create index(:autolaunch_revsplit_tokens, [:source_auction_id],
             name: :autolaunch_revsplit_tokens_source_auction_idx
           )
  end

  def down do
    raise "hard cutover only"
  end
end
