defmodule Autolaunch.Repo.Migrations.AuctionChainIdentity do
  @moduledoc """
  Gives every auction its chain, so one contract address on one chain is one
  row and the same address on another chain is another auction.

  Existing rows take their chain only from evidence this server recorded: the
  chain id inside the envelope of a verified launch operation whose result
  named the same auction address. A row with no such operation, or with
  operations naming more than one chain, stops the migration; nothing is
  guessed and nothing is changed.

  The column, index and address constraint were generated with
  `mix ash_postgres.generate_migrations`; the backfill is hand-written.
  """

  use Ecto.Migration

  def up do
    alter table(:auctions) do
      add :chain_id, :bigint
    end

    # The tables live in the schema the migration runs in, which is not `public`
    # in production, so the hand-written SQL names it explicitly.
    schema = ~s("#{prefix()}")

    execute """
    UPDATE #{schema}.auctions AS auction
    SET chain_id = evidence.chain_id
    FROM (
      SELECT lower(result ->> 'auction') AS auction_address,
             min((envelope ->> 'chain_id')::bigint) AS chain_id
      FROM (
        SELECT result, envelope FROM #{schema}.launch_operations WHERE state = 'chain_verified'
        UNION ALL
        SELECT result, envelope FROM #{schema}.stock_launch_operations WHERE state = 'chain_verified'
      ) AS verified
      WHERE result ? 'auction' AND envelope ? 'chain_id'
      GROUP BY lower(result ->> 'auction')
      HAVING count(DISTINCT (envelope ->> 'chain_id')) = 1
    ) AS evidence
    WHERE lower(auction.auction_address) = evidence.auction_address
    """

    flush()

    %{rows: [[unresolved, ids]]} =
      repo().query!("""
      SELECT count(*), coalesce(string_agg(id::text, ', ' ORDER BY id), '')
      FROM #{schema}.auctions WHERE chain_id IS NULL
      """)

    if unresolved > 0 do
      raise "#{unresolved} auction row(s) have no single verified launch operation naming their chain; " <>
              "left unchanged: #{ids}"
    end

    alter table(:auctions) do
      modify :chain_id, :bigint, null: false
    end

    create unique_index(:auctions, [:chain_id, :auction_address],
             name: "auctions_chain_auction_index"
           )

    alter table(:auctions) do
      modify :auction_address, :text, null: false
    end
  end

  def down do
    alter table(:auctions) do
      modify :auction_address, :text, null: true
    end

    drop_if_exists unique_index(:auctions, [:chain_id, :auction_address],
                     name: "auctions_chain_auction_index"
                   )

    alter table(:auctions) do
      remove :chain_id
    end
  end
end
