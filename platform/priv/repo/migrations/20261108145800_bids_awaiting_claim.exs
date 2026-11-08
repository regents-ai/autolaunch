defmodule Autolaunch.Repo.Migrations.BidsAwaitingClaim do
  @moduledoc """
  Gives bids that exited with tokens filled, before their claim block, their
  own status. They were stored as `returned`, the same word as a finished bid
  that filled nothing, and pages told the two apart by the fill. Each one now
  reads `awaiting_claim` (`Autolaunch.Bid`); its auction's next reading moves
  it on to `claimable` or `claimed` as the chain says. No row is deleted.

  Hand-written; the status column keeps its type.
  """

  use Ecto.Migration

  def up do
    execute ~s"""
    UPDATE "#{prefix()}".bids
    SET status = 'awaiting_claim'
    WHERE status = 'returned'
    AND tokens_filled IS NOT NULL
    AND tokens_filled <> ''
    AND tokens_filled::numeric > 0
    """
  end

  def down do
    execute ~s"""
    UPDATE "#{prefix()}".bids SET status = 'returned' WHERE status = 'awaiting_claim'
    """
  end
end
