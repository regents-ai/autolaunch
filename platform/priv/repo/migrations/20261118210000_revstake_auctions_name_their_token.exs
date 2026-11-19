defmodule Autolaunch.Repo.Migrations.RevstakeAuctionsNameTheirToken do
  @moduledoc """
  Gives each Revstake auction stored without the token it sells the token its
  launch job recorded beside it. Revstake launches recorded before
  `Autolaunch.LabProjection` wrote the token on the auction have it only on
  the launch job and the subject, so the auction's token page, the token lists
  and the launch's contracts name no token.

  Only an empty token address is filled, and only from a launch job value that
  is an address (`0x` and 40 hex digits), written in lowercase as new launches
  write it. An auction that already names a token, a Memestock auction, and an
  auction whose launch job holds no address keep what they have. No row is
  deleted.

  Hand-written; no resource changes shape.
  """

  use Ecto.Migration

  def up do
    execute ~s"""
    UPDATE "#{prefix()}".auctions AS auction
    SET token_address = lower(launch.token_address)
    FROM "#{prefix()}".launch_jobs AS launch
    WHERE launch.auction_id = auction.id
    AND auction.kind = 'agent'
    AND auction.token_address IS NULL
    AND launch.token_address ~ '^0x[0-9a-fA-F]{40}$'
    """
  end

  def down, do: :ok
end
