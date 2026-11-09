defmodule Autolaunch.Repo.Migrations.ResolveLeftUnlistedMemestockLaunches do
  @moduledoc """
  Sends back to `pending` the Base Memestock launches an early resolve pass left
  unlisted for want of a matching review. Every Base Memestock launch is listed
  now (`Autolaunch.Stocks.ChainLaunch`), so the resolve trigger no longer needs
  its own clause to take them again; the next pass lists them. Launches hidden
  by an operator keep their own reason and stay unlisted. No row is deleted.

  Hand-written; no resource changes shape.
  """

  use Ecto.Migration

  def up do
    execute ~s"""
    UPDATE "#{prefix()}".launch_discoveries
    SET state = 'pending'
    WHERE launchpad = 'base_memestock'
    AND state = 'unlisted'
    AND reason = 'no_matching_review'
    """
  end

  def down, do: :ok
end
