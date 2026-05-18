defmodule Autolaunch.Repo.Migrations.CutoverAuctionQuoteTokenToRegent do
  use Ecto.Migration

  @regent "0x6f89bca4ea5931edfcb09786267b251dee752b07"
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @usdc_to_regent_raw_scale "1000000000000"

  def up do
    rename_if_present(:autolaunch_prelaunch_plans, :minimum_raise_usdc, :minimum_raise_quote)
    rename_minimum_raise_raw_if_present(:autolaunch_prelaunch_plans, scale?: true)
    rename_if_present(:autolaunch_jobs, :minimum_raise_usdc, :minimum_raise_quote)
    rename_minimum_raise_raw_if_present(:autolaunch_jobs, scale?: true)
    rename_if_present(:autolaunch_auctions, :minimum_raise_usdc, :minimum_raise_quote)
    rename_minimum_raise_raw_if_present(:autolaunch_auctions, scale?: true)

    rename_if_present(:autolaunch_revsplit_tokens, :auction_raise_usdc, :auction_raise_quote)
    rename_if_present(:autolaunch_revsplit_tokens, :required_raise_usdc, :required_raise_quote)
    rename_if_present(:autolaunch_revsplit_tokens, :clearing_price_usdc, :clearing_price_quote)
    rename_if_present(:autolaunch_revsplit_tokens, :price_usdc, :price_quote)
    rename_if_present(:autolaunch_revsplit_tokens, :fdv_usdc, :fdv_quote)

    alter table(:autolaunch_jobs) do
      add :auction_quote_token_address, :string, null: false, default: @regent
      add :auction_quote_token_symbol, :string, null: false, default: "REGENT"
      add :auction_quote_token_decimals, :integer, null: false, default: 18
      add :revenue_usdc_token_address, :string, null: false, default: @usdc
      add :revenue_usdc_token_symbol, :string, null: false, default: "USDC"
      add :revenue_usdc_token_decimals, :integer, null: false, default: 6
    end

    alter table(:autolaunch_auctions) do
      add :auction_quote_token_address, :string, null: false, default: @regent
      add :auction_quote_token_symbol, :string, null: false, default: "REGENT"
      add :auction_quote_token_decimals, :integer, null: false, default: 18
      add :revenue_usdc_token_address, :string, null: false, default: @usdc
      add :revenue_usdc_token_symbol, :string, null: false, default: "USDC"
      add :revenue_usdc_token_decimals, :integer, null: false, default: 6
    end

    alter table(:autolaunch_revsplit_tokens) do
      add :auction_quote_token_address, :string, null: false, default: @regent
      add :auction_quote_token_symbol, :string, null: false, default: "REGENT"
      add :auction_quote_token_decimals, :integer, null: false, default: 18
    end
  end

  def down do
    raise "hard cutover only"
  end

  defp rename_if_present(table, old_name, new_name) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = '#{table}' AND column_name = '#{old_name}'
      ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = '#{table}' AND column_name = '#{new_name}'
      ) THEN
        ALTER TABLE #{table} RENAME COLUMN #{old_name} TO #{new_name};
      END IF;
    END $$;
    """)
  end

  defp rename_minimum_raise_raw_if_present(table, opts) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = '#{table}' AND column_name = 'minimum_raise_usdc_raw'
      ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = '#{table}' AND column_name = 'minimum_raise_quote_raw'
      ) THEN
        ALTER TABLE #{table} RENAME COLUMN minimum_raise_usdc_raw TO minimum_raise_quote_raw;
        #{scale_minimum_raise_raw_sql(table, opts)}
      END IF;
    END $$;
    """)
  end

  defp scale_minimum_raise_raw_sql(table, scale?: true) do
    """

        UPDATE #{table}
        SET minimum_raise_quote_raw =
          ((minimum_raise_quote_raw::numeric * #{@usdc_to_regent_raw_scale})::numeric(78,0))::text
        WHERE minimum_raise_quote_raw ~ '^[0-9]+$';
    """
  end

  defp scale_minimum_raise_raw_sql(_table, scale?: false), do: ""
end
