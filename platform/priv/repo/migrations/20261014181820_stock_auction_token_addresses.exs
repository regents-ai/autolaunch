defmodule Autolaunch.Repo.Migrations.StockAuctionTokenAddresses do
  @moduledoc """
  A Base Memestock auction now records the token its launch created. Rows
  written before have none, so each takes the token from the confirmed launch
  review that wrote it. Hand-written; no resource changes.
  """

  use Ecto.Migration

  def up do
    # The tables live in the schema the migration runs in, which is not `public`
    # in production, so the hand-written SQL names it explicitly.
    execute ~s"""
    UPDATE "#{prefix()}".auctions AS auction
    SET token_address = operation.result->>'new_token'
    FROM "#{prefix()}".stock_launch_operations AS operation
    WHERE auction.kind = 'stocks'
      AND auction.token_address IS NULL
      AND operation.state = 'chain_verified'
      AND lower(operation.result->>'auction') = lower(auction.auction_address)
      AND operation.result->>'new_token' IS NOT NULL
    """
  end

  def down, do: :ok
end
