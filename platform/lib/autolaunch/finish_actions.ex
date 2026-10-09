defmodule Autolaunch.FinishActions do
  @moduledoc """
  Finishing an ended auction from a person's own wallet.

  An auction does not finish itself: once its launch's migration block has
  passed, anyone may call `migrate`, which graduates the launch into its pool
  or fails it so every bid comes back whole (`Autolaunch.AuctionFinish`). The
  auction page offers that call to whoever is looking. It is read here at the
  latest block of the auction's own chain, from the launchpad the auction runs
  on, first or second (`Autolaunch.AuctionFinish.Launchpads.for_auction/1`).
  Nothing is stored: the market feeds record the outcome from the chain.
  """

  alias Autolaunch.AuctionFinish.Launchpads
  alias Autolaunch.Chain.Rpc

  @doc """
  Where the launch of `auction` stands now: its `state` (`:running`,
  `:graduated` or `:failed`), its `migration_block` and the `clock` the
  launchpad compares it with, the `chain` a review names, and the `call` that
  finishes it.
  """
  @spec read(map()) :: {:ok, map()} | {:error, :chain_unavailable}
  def read(auction) do
    with {:ok, pad} <- Launchpads.for_auction(auction),
         {:ok, block} <- Rpc.latest_block(pad.opts),
         {:ok, clock} <- Launchpads.clock(pad, block),
         {:ok, launch} <- Launchpads.launch_of_auction(pad, auction.auction_address, block) do
      {:ok,
       %{
         state: launch.state,
         migration_block: launch.migration_block,
         clock: clock,
         chain: pad.chain,
         call: Launchpads.migrate_call(pad, launch)
       }}
    else
      {:error, _reason} -> {:error, :chain_unavailable}
    end
  end
end
