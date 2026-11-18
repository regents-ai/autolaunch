defmodule Autolaunch.Repo.Migrations.RevstakeAuctionsNameTheirToken do
  @moduledoc """
  Gives each Revstake auction the token it sells, the subject its launch job
  recorded beside it. Revstake launches wrote it on the launch job and the
  subject alone, so the auction's token page, the token lists and the launch's
  contracts named no token (`Autolaunch.LabProjection` now writes it on the
  auction too). No row is deleted.

  Hand-written; no resource changes shape.
  """

  use Ecto.Migration

  def up do
    execute ~s"""
    UPDATE "#{prefix()}".auctions AS auction
    SET token_address = launch.token_address
    FROM "#{prefix()}".launch_jobs AS launch
    WHERE launch.auction_id = auction.id
    AND auction.kind = 'agent'
    AND auction.token_address IS NULL
    AND launch.token_address IS NOT NULL
    """
  end

  def down, do: :ok
end
