defmodule Autolaunch.Chain.CcaLists do
  @moduledoc """
  Walks of the two lists a Continuous Clearing Auction stores, shared by Base
  and Robinhood: its ticks, the prices bid at, linked from the floor upward;
  and its checkpoints, one for each block that recorded the clearing price,
  linked in block order, each priced no lower than the one before.

  Each walk reads through functions the chain's client gives it, all at the
  client's one pinned block, and follows at most `reads/0` entries of a list
  in one request. Reaching that never refuses a bid for being in a long list:

    * A new bid names a tick below its own maximum price. Any price the
      auction holds below it will do, and the auction walks on from there
      itself. The walk starts at the lowest price above the clearing price
      when that is below the maximum, else at the floor, and hands back the
      highest price it reached.
    * A settlement names the checkpoint where the clearing price crossed the
      bid's maximum. Every bid stores a checkpoint at its own block, and a
      later bid's is never priced lower, so the auction's bids are halved to
      the last one before the crossing (two reads for each halving), then the
      checkpoints after that bid's are followed: only checkpoints no bid wrote
      lie on that stretch. The last checkpoint a walk reached before the
      crossing is kept for half an hour (`cache/0`), so a stretch longer than
      the budget is read across several requests, each going on from where
      the one before stopped, and a review built again soon after reads only
      the crossing.

  A settlement crossing therefore reads at most 2·⌈log2(n + 1)⌉ + `reads/0` +
  1 entries, `n` being the number of bids placed after the bid, and a new
  bid's tick at most `reads/0`. A read that fails ends the walk with the
  read's own reason, which the page shows as the chain being unreadable just
  now; nothing is kept from it.
  """

  @last_block Integer.pow(2, 64) - 1
  @reads 256

  @typedoc "The `next` of tick `price`: `0` where the auction holds no such tick."
  @type read_tick :: (non_neg_integer() -> {:ok, non_neg_integer()} | {:error, atom()})

  @typedoc """
  What a settlement walk reads: the start block of bid `id`; the price and
  `next` of the checkpoint at a block (`next` is `0` where none is stored);
  the auction's last bid id; and `key`, naming the auction, the bid's maximum
  and the crossing, under which the walk keeps where it reached.
  """
  @type checkpoint_reads :: %{
          bid_start: (non_neg_integer() -> {:ok, non_neg_integer()} | {:error, atom()}),
          checkpoint: (non_neg_integer() -> {:ok, checkpoint()} | {:error, atom()}),
          last_bid: non_neg_integer(),
          key: term()
        }

  @type checkpoint :: %{price: non_neg_integer(), next: non_neg_integer()}
  @type bid :: %{id: non_neg_integer(), start_block: non_neg_integer()}
  @type below :: (non_neg_integer() -> boolean())

  @doc "The cache that keeps where each settlement walk reached."
  def cache, do: __MODULE__

  @doc "The most entries of a list one walk follows in one request."
  def reads, do: @reads

  @doc """
  A tick the auction holds below `max_price`, for a new bid's `prevTickPrice`:
  the one just below it when the walk reaches it within `reads/0`, else the
  highest one the walk reached. Refused when the floor is not below the
  maximum or the list does not climb.
  """
  @spec tick_hint(read_tick(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def tick_hint(read_next, floor, next_active, max_price) when floor < max_price do
    start = if next_active < max_price, do: max(next_active, floor), else: floor
    ticks(read_next, start, max_price, @reads)
  end

  def tick_hint(_read_next, _floor, _next_active, _max_price),
    do: {:error, :bid_preparation_unavailable}

  defp ticks(_read_next, current, _max_price, 0), do: {:ok, current}

  defp ticks(read_next, current, max_price, left) do
    with {:ok, next} <- read_next.(current) do
      cond do
        next >= max_price -> {:ok, current}
        next > current -> ticks(read_next, next, max_price, left - 1)
        true -> {:error, :bid_preparation_unavailable}
      end
    end
  end

  @doc """
  Where the clearing price, from `bid`'s own checkpoint on, stops passing
  `below?`: the last checkpoint whose price passes it, and the block of the
  one after it, or `:final` when none is stored after it.

  The bid's own checkpoint must pass `below?`. A walk the budget stops is
  refused as `:price_history_long`; the next request goes on from there.
  """
  @spec crossing(checkpoint_reads(), bid(), below()) ::
          {:ok, {non_neg_integer(), non_neg_integer() | :final}} | {:error, atom()}
  def crossing(reads, %{id: id, start_block: start}, below?) do
    with {:ok, from} <- last_bid_below(reads, {id, start}, reads.last_bid, below?) do
      key = {reads.key, from}

      case walk(reads, reached(key, from), below?, key) do
        {:error, :bid_needs_partial_exit_hints_unavailable} = refused ->
          Cachex.del(cache(), key)
          refused

        result ->
          result
      end
    end
  end

  # The start block of the last bid in `lo..hi` whose own checkpoint passes
  # `below?`, given that bid `lo`'s does: the bids' checkpoints are priced in
  # bid order, so halving finds it.
  defp last_bid_below(_reads, {lo, start}, hi, _below?) when lo >= hi, do: {:ok, start}

  defp last_bid_below(reads, {lo, _start} = low, hi, below?) do
    mid = div(lo + hi + 1, 2)

    with {:ok, mid_start} <- reads.bid_start.(mid),
         {:ok, %{price: price}} <- reads.checkpoint.(mid_start) do
      if below?.(price),
        do: last_bid_below(reads, {mid, mid_start}, hi, below?),
        else: last_bid_below(reads, low, mid - 1, below?)
    end
  end

  defp reached(key, from) do
    case Cachex.get(cache(), key) do
      {:ok, block} when is_integer(block) -> block
      _none -> from
    end
  end

  defp walk(reads, block, below?, key) do
    with {:ok, checkpoint} <- reads.checkpoint.(block) do
      if checkpoint.next != 0 and below?.(checkpoint.price),
        do: follow(reads, block, checkpoint.next, below?, key, @reads),
        else: {:error, :bid_needs_partial_exit_hints_unavailable}
    end
  end

  # `block` passes `below?` and `next` is the block stored after it.
  defp follow(_reads, block, @last_block, _below?, key, _left),
    do: kept(key, block, {:ok, {block, :final}})

  defp follow(_reads, block, _next, _below?, key, 0),
    do: kept(key, block, {:error, :price_history_long})

  defp follow(reads, block, next, below?, key, left) when next > block do
    with {:ok, checkpoint} <- reads.checkpoint.(next) do
      cond do
        not below?.(checkpoint.price) -> kept(key, block, {:ok, {block, next}})
        checkpoint.next == 0 -> {:error, :bid_needs_partial_exit_hints_unavailable}
        true -> follow(reads, next, checkpoint.next, below?, key, left - 1)
      end
    end
  end

  defp follow(_reads, _block, _next, _below?, _key, _left),
    do: {:error, :bid_needs_partial_exit_hints_unavailable}

  defp kept(key, block, result) do
    Cachex.put(cache(), key, block)
    result
  end
end
