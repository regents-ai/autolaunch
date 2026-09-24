defmodule Autolaunch.Auction.MarketState do
  @moduledoc """
  One state model for every launch type, read from the chain.

  The launch lifecycle the launchpad (or the Revstake strategy) records is the
  only evidence of a finished launch: 2 is Graduated and 3 is Failed, and both
  are set only inside `migrate`, which creates the pool. Before that the
  auction's own schedule decides, against the block the contracts keep time
  by: before the start block the auction is `:created`, before the end block it
  is `:active`, and after it `:ended` (bidding is over, waiting to finish).

  The auction's `isGraduated()` only says the raise has met its minimum. It can
  turn true mid-auction, so it never decides the state; it is stored as
  `minimum_reached`.
  """

  @type t :: :created | :active | :ended | :graduated | :failed

  @graduated 2
  @failed 3

  @rank %{created: 0, active: 1, ended: 2, graduated: 3, failed: 3}

  @doc "The state a lifecycle and schedule describe at one clock reading."
  @spec observed(non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          t()
  def observed(@graduated, _clock, _start_block, _end_block), do: :graduated
  def observed(@failed, _clock, _start_block, _end_block), do: :failed
  def observed(_lifecycle, clock, start_block, _end_block) when clock < start_block, do: :created
  def observed(_lifecycle, clock, _start_block, end_block) when clock < end_block, do: :active
  def observed(_lifecycle, _clock, _start_block, _end_block), do: :ended

  @doc """
  The stored state after an observation: a finished state never changes, and
  otherwise the state only moves forward (created, active, ended, finished).
  """
  @spec join(t(), t()) :: t()
  def join(current, _observed) when current in [:graduated, :failed], do: current

  def join(current, observed),
    do: if(@rank[observed] >= @rank[current], do: observed, else: current)
end
