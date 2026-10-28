defmodule Autolaunch.Repo.Migrations.ListBaseMemestockChainLaunches do
  @moduledoc """
  Every Memestock launch on Base is now listed, wherever it was sent
  (`Autolaunch.Stocks.ChainLaunch`). The Base Memestock launches left unlisted
  because no review of this site carried them out go back to pending, so the
  next resolve pass lists them under the wallet that sent them. Revstake
  launches stay as they are. No row is deleted.

  Hand-written; no resource changes shape.
  """

  use Ecto.Migration

  def up do
    # The table lives in the schema the migration runs in, which is not `public`
    # in production, so the hand-written SQL names it explicitly.
    execute ~s"""
    UPDATE "#{prefix()}".launch_discoveries
    SET state = 'pending', reason = NULL
    WHERE launchpad = 'base_memestock' AND state = 'unlisted' AND reason = 'no_matching_review'
    """
  end

  def down, do: :ok
end
