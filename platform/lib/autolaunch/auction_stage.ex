defmodule Autolaunch.AuctionStage do
  @moduledoc """
  Where an auction is in its life, and the separate facts a bidder acts on.

  The stage is one of: `:created` (bidding has not opened), `:open`,
  `:finishing` (bidding has ended and the auction is not yet finished into a
  pool), `:pool_ready` (the record says it graduated and its pool reads back
  from the chain) and `:failed` (it ended below its minimum). A graduated
  record whose pool cannot be read stays `:finishing`: the pool is ready only
  once the chain shows it.

  The facts are independent of the stage and of each other:

    * `minimum_reached` - the currency raised, read from the auction, is at
      least its minimum;
    * `claims_open` - the pool is ready and the auction clock has reached the
      claim block;
    * `refunds_open` - the auction failed, so every bid comes back whole;
    * `liquidity_locked` - every position of the ready pool is held by the
      locker; nil until the pool is ready.

  Every block is on the auction's own clock (`Autolaunch.AuctionSnapshot`).
  """

  @type stage :: :created | :open | :finishing | :pool_ready | :failed

  @doc """
  The stage and facts of an auction from its record's `state`, a snapshot's
  `clock` and `blocks`, its minimum in the currency's smallest unit, and its
  pool's reading (`Autolaunch.Pool.read/1` or `Autolaunch.Robinhood.Pool.read/1`).
  """
  @spec read(atom(), map(), non_neg_integer(), {:ok, map()} | {:error, atom()}) :: map()
  def read(state, %{clock: clock, blocks: blocks}, required, pool) do
    stage = stage(state, clock, blocks, pool)

    %{
      stage: stage,
      facts: %{
        minimum_reached: blocks.raised >= required,
        claims_open: stage == :pool_ready and clock >= blocks.claim,
        refunds_open: stage == :failed,
        liquidity_locked: locked(stage, pool)
      }
    }
  end

  defp stage(:failed, _clock, _blocks, _pool), do: :failed
  defp stage(_state, clock, %{start: start}, _pool) when clock < start, do: :created
  defp stage(_state, clock, %{end: finish}, _pool) when clock < finish, do: :open
  defp stage(:graduated, _clock, _blocks, {:ok, _pool}), do: :pool_ready
  defp stage(_state, _clock, _blocks, _pool), do: :finishing

  defp locked(:pool_ready, {:ok, %{positions: positions}}),
    do: positions != [] and Enum.all?(positions, & &1.locked?)

  defp locked(_stage, _pool), do: nil
end
