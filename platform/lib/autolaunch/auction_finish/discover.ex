defmodule Autolaunch.AuctionFinish.Discover do
  @moduledoc """
  Records every launch created since the last run, on every configured
  launchpad, with its auction, migration block and state as the chain has them.
  """

  alias Autolaunch.Actors.System
  alias Autolaunch.AuctionFinish.Launchpads
  alias Autolaunch.Chain.Rpc

  def run(_input, _context) do
    Enum.reduce_while(Launchpads.configured(), :ok, fn pad, :ok ->
      case discover(pad) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp discover(pad) do
    with {:ok, block} <- Rpc.latest_block(pad.opts),
         {:ok, last} <- Launchpads.last_launch_id(pad, block),
         {:ok, known} <- known(pad),
         do: record_new(pad, (known + 1)..last//1, block)
  end

  defp record_new(pad, launch_ids, block) do
    Enum.reduce_while(launch_ids, :ok, fn launch_id, :ok ->
      case record(pad, launch_id, block) do
        {:ok, _finish} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp known(pad) do
    case Autolaunch.latest_auction_finish(pad.chain_id, pad.contract, actor: %System{}) do
      {:ok, nil} -> {:ok, 0}
      {:ok, finish} -> {:ok, finish.launch_id}
      {:error, reason} -> {:error, reason}
    end
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
