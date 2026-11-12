defmodule Autolaunch.AuctionFinish.Discover do
  @moduledoc """
  Records every launch the site has not recorded yet, on every configured
  launchpad, with its auction, migration block and state as the chain has them.

  A launch that cannot be read or recorded is one warning line and is left
  out: the launches after it, and the other launchpads, are still recorded. A
  launchpad whose head or count cannot be read is left out the same way. The
  run then fails naming each one, and the next run reads them again, since it
  looks for every launch id up to the launchpad's count that has no record.

  This only decides which launches the finisher knows of. What is sent to
  finish one, and from which wallet, is `Autolaunch.AuctionFinish.Finish` and
  `Autolaunch.AuctionFinish.Sender`.
  """

  require Logger

  alias Autolaunch.Actors.System
  alias Autolaunch.AuctionFinish.Launchpads
  alias Autolaunch.Chain.Rpc

  def run(_input, _context) do
    case Enum.flat_map(Launchpads.configured(), &discover/1) do
      [] -> :ok
      unrecorded -> {:error, {:launches_not_recorded, unrecorded}}
    end
  end

  # What `pad` has that could not be recorded this run: launch ids, or the
  # launchpad itself.
  defp discover(pad) do
    with {:ok, block} <- Rpc.latest_block(pad.opts),
         {:ok, last} <- Launchpads.last_launch_id(pad, block),
         {:ok, recorded} <- recorded(pad) do
      for launch_id <- 1..last//1,
          launch_id not in recorded,
          {:error, reason} <- [record(pad, launch_id, block)],
          do: unrecorded(pad, launch_id, reason)
    else
      {:error, reason} -> [unrecorded(pad, :launchpad, reason)]
    end
  end

  defp unrecorded(pad, which, reason) do
    Logger.warning(
      "Auction finisher: #{pad.launchpad} #{name(which)} on chain #{pad.chain_id} not recorded: #{inspect(reason)}"
    )

    {pad.launchpad, pad.chain_id, which}
  end

  defp name(:launchpad), do: "launchpad"
  defp name(launch_id), do: "launch #{launch_id}"

  defp recorded(pad) do
    with {:ok, finishes} <-
           Autolaunch.recorded_auction_finishes(pad.chain_id, pad.contract, actor: %System{}),
         do: {:ok, MapSet.new(finishes, & &1.launch_id)}
  end

  defp record(pad, launch_id, block) do
    with {:ok, launch} <- Launchpads.launch(pad, launch_id, block) do
      Autolaunch.record_auction_finish(
        %{
          launchpad: pad.launchpad,
          chain_id: pad.chain_id,
          contract: pad.contract,
          launch_id: launch_id,
          auction: launch.auction,
          migration_block: launch.migration_block,
          state: launch.state
        },
        actor: %System{}
      )
    end
  end
end
