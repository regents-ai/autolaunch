defmodule Autolaunch.Repo.Migrations.DropWalletPressTables do
  @moduledoc """
  Drops the four wallet-press tables A02 stops writing (founder decision 8, answer a).
  Their rows are exported to an archive file before this migration runs in production.

  Generated with `mix ash.codegen`; wallet_attempts is dropped first because it holds the
  foreign keys to the other three.
  """

  use Ecto.Migration

  def up do
    drop table(:wallet_attempts)

    drop table(:bid_operations)

    drop table(:bid_settlement_operations)

    drop table(:subject_wallet_operations)
  end

  def down do
    # The rows live on in the archive export; the tables are not recreated.
  end
end
