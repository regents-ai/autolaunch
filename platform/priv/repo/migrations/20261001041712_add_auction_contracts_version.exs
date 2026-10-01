defmodule Autolaunch.Repo.Migrations.AddAuctionContractsVersion do
  @moduledoc """
  Records which Memestake contracts each launch runs on. Every launch made on
  the first Memestake launchpads (Base 0x1d36…Cac2, Robinhood 0x6356…EF6e,
  the same addresses on the practice chains) is `v1`; every other row is `v2`.
  """

  use Ecto.Migration

  def up do
    alter table(:auctions) do
      add :contracts_version, :text, null: false, default: "v2"
    end

    execute("""
    UPDATE "#{prefix()}".auctions SET contracts_version = 'v1'
    WHERE kind = 'stocks'
      AND lower(treasury_address) IN (
        '0x1d36a95112835f81b1b499a808e556020c64cac2',
        '0x635615ccef2ef24d0655fc2ebc47a14e005fef6e'
      )
    """)
  end

  def down do
    alter table(:auctions) do
      remove :contracts_version
    end
  end
end
