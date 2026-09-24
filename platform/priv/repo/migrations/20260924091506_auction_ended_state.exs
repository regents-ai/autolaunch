defmodule Autolaunch.Repo.Migrations.AuctionEndedState do
  @moduledoc """
  Records whether each auction's raise has met its minimum. A graduated
  auction always met it, so existing graduated rows start true; every other
  row starts false until the market feed reads it.

  The column was generated with `mix ash_postgres.generate_migrations`; the
  backfill is hand-written.
  """

  use Ecto.Migration

  def up do
    alter table(:auctions) do
      add :minimum_reached, :boolean, null: false, default: false
    end

    # The tables live in the schema the migration runs in, which is not `public`
    # in production, so the hand-written SQL names it explicitly.
    execute ~s(UPDATE "#{prefix()}".auctions SET minimum_reached = true WHERE state = 'graduated')
  end

  def down do
    alter table(:auctions) do
      remove :minimum_reached
    end
  end
end
