defmodule Autolaunch.Repo.Migrations.EnsNamesKeepTheirWallet do
  @moduledoc """
  Records, for each finished ENS lookup, the wallet its name and picture were
  read for (`named_wallet`). A finished lookup wrote the wallet it read, so the
  row's wallet is that wallet. A lookup still pending or failed may hold a name
  read for an earlier wallet; it shows none until its next lookup. No row is
  deleted.

  Hand-written; runs after the generated migration that adds the column.
  """

  use Ecto.Migration

  def up do
    execute ~s"""
    UPDATE "#{prefix()}".account_ens_identities
    SET named_wallet = wallet_address
    WHERE lookup_state = 'done'
    """
  end

  def down, do: :ok
end
