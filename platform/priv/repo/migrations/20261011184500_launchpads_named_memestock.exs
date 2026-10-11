defmodule Autolaunch.Repo.Migrations.LaunchpadsNamedMemestock do
  @moduledoc """
  Memestake is now Memestock. Saved launch discoveries and auction finishes
  name their launchpad `base_memestock` or `robinhood_memestock`, and the
  every-minute Memestock discovery job waiting to run carries its new worker
  name. No row is deleted.

  Hand-written; the attribute change needs no generated migration.
  """

  use Ecto.Migration

  def up do
    # The tables live in the schema the migration runs in, which is not `public`
    # in production, so the hand-written SQL names it explicitly.
    for table <- ["launch_discoveries", "auction_finishes"] do
      execute ~s"""
      UPDATE "#{prefix()}".#{table}
      SET launchpad = replace(launchpad, '_memestake', '_memestock')
      WHERE launchpad IN ('base_memestake', 'robinhood_memestake')
      """
    end

    execute ~s"""
    UPDATE "#{prefix()}".oban_jobs
    SET worker = 'Autolaunch.LaunchDiscovery.Workers.DiscoverMemestock'
    WHERE worker = 'Autolaunch.LaunchDiscovery.Workers.DiscoverMemestake'
    AND state IN ('available', 'scheduled', 'retryable')
    """
  end

  def down, do: :ok
end
