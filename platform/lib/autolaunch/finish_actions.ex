defmodule Autolaunch.FinishActions do
  @moduledoc """
  Finishing an ended auction from a person's own wallet.

  An auction does not finish itself: once its launch's migration block has
  passed, anyone may call `migrate`, which graduates the launch into its pool
  or fails it so every bid comes back whole (`Autolaunch.AuctionFinish`). The
  auction page offers that call to whoever is looking, and a paired agent has
  it prepared for its person's wallet (`Autolaunch.AgentFinish`); both read it
  here, by one rule. It is read at the latest block of the auction's own
  chain, from the launchpad the auction runs on, first or second
  (`Autolaunch.AuctionFinish.Launchpads.for_auction/1`). Nothing is stored:
  the auction's reading job records the outcome from the chain
  (`Autolaunch.AuctionMarket`).
  """

  alias Autolaunch.AuctionFinish.Launchpads
  alias Autolaunch.Chain.Rpc
  alias RegentChain.Review

  @doc """
  Where the launch of `auction` stands now: its `state` (`:running`,
  `:graduated` or `:failed`), the latest `block` it was read at, its
  `migration_block` and the `clock` the launchpad compares it with, the `chain`
  a review names, the one `finish` step that finishes it (`steps`, its data
  ending with the site's Builder Code), and why `migrate` is certain to revert
  now (`blocked`): `:finish_not_open` while even the clock's next step is
  before the migration block, `:auction_finished` once the launch is
  finished, otherwise `nil`.
  """
  @spec read(map()) :: {:ok, map()} | {:error, :chain_unavailable}
  def read(auction) do
    with {:ok, pad} <- Launchpads.for_auction(auction),
         {:ok, block} <- Rpc.latest_block(pad.opts),
         {:ok, clock} <- Launchpads.clock(pad, block),
         {:ok, launch} <- Launchpads.launch_of_auction(pad, auction.auction_address, block) do
      call = Launchpads.migrate_call(pad, launch)

      {:ok,
       %{
         state: launch.state,
         block: block.number,
         migration_block: launch.migration_block,
         clock: clock,
         chain: pad.chain,
         steps: [Review.step("finish", call.to, call.data)],
         blocked: blocked(launch, clock)
       }}
    else
      {:error, _reason} -> {:error, :chain_unavailable}
    end
  end

  # Every launchpad's `migrate` reverts while its clock is before the launch's
  # migration block: the block itself on Base, the rollup block on Robinhood
  # Chain. That clock never runs back, and a finish sent now lands at the clock
  # as it is or later: it is certain to revert while even the clock's next
  # step is before the migration block, or once the launch is finished. One
  # step before the migration block it may land in time.
  defp blocked(%{state: :running, migration_block: migration_block}, clock)
       when clock + 1 < migration_block,
       do: :finish_not_open

  defp blocked(%{state: :running}, _clock), do: nil
  defp blocked(%{state: _finished}, _clock), do: :auction_finished
end
