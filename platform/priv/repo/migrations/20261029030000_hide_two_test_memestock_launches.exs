defmodule Autolaunch.Repo.Migrations.HideTwoTestMemestockLaunches do
  @moduledoc """
  Keeps the two test launches on Base's Memestock launchpad (launches 1 and 2,
  "V2 AUTOLAUNCH TEST", made by the team's own wallet before the site opened)
  off the site now that every Memestock launch on Base is listed (Sean,
  29 Oct 2026, "Hide both"). Their discoveries become unlisted with the reason
  `operator_hidden`, which no resolve pass takes again. No row is deleted, and
  a database without them (a lab, a fork) is left as it is.

  Hand-written; no resource changes shape.
  """

  use Ecto.Migration

  @launchpad "0x1d4bc582a9193061d53c4bfa429d366ed38eed0b"

  def up do
    # The table lives in the schema the migration runs in, which is not `public`
    # in production, so the hand-written SQL names it explicitly.
    execute ~s"""
    UPDATE "#{prefix()}".launch_discoveries
    SET state = 'unlisted', reason = 'operator_hidden'
    WHERE chain_id = 8453 AND lower(contract) = '#{@launchpad}' AND launch_id IN (1, 2)
    """
  end

  def down, do: :ok
end
