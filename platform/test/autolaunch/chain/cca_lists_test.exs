defmodule Autolaunch.Chain.CcaListsTest do
  @moduledoc """
  The two auction lists, held in memory, of every length and with the answer
  anywhere along them: a new bid's tick is always one the auction holds below
  its price, and a settlement's crossings are always the exact ones, found
  within the stated reads in each request however long the history, the
  second going on from the first.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Autolaunch.Chain.CcaLists

  @last_tick Integer.pow(2, 256) - 1
  @last_block Integer.pow(2, 64) - 1

  describe "a new bid's tick" do
    property "is a tick the auction holds below the price, the one just below it when in reach" do
      check all(
              count <- integer(0..1_200),
              gaps <- list_of(integer(1..4), length: count),
              active_at <- integer(0..1_300),
              over <- integer(0..1_300)
            ) do
        floor = 1_000
        ticks = Enum.scan([floor | gaps], &(&1 + &2))
        nexts = Map.new(Enum.zip(ticks, tl(ticks) ++ [@last_tick]))
        next_active = Enum.at(ticks, active_at, @last_tick)
        max_price = floor + 1 + over
        {read, reads} = counted(fn price -> {:ok, Map.get(nexts, price, 0)} end)

        assert {:ok, hint} = CcaLists.tick_hint(read, floor, next_active, max_price)

        assert Map.has_key?(nexts, hint)
        assert hint < max_price
        assert reads.() <= CcaLists.reads()

        below = Enum.filter(ticks, &(&1 < max_price))
        start = if next_active < max_price, do: max(next_active, floor), else: floor
        steps = Enum.count(below, &(&1 > start))
        if steps <= CcaLists.reads(), do: assert(hint == List.last(below))
      end
    end

    test "is refused when the floor is not below the price or the list does not climb" do
      read = fn _price -> {:ok, 0} end

      assert {:error, :bid_preparation_unavailable} = CcaLists.tick_hint(read, 10, 0, 10)
      assert {:error, :bid_preparation_unavailable} = CcaLists.tick_hint(read, 10, 0, 20)
    end

    test "a read that fails is the read's own answer" do
      read = fn _price -> {:error, :chain_unavailable} end
      assert {:error, :chain_unavailable} = CcaLists.tick_hint(read, 10, @last_tick, 20)
    end
  end

  describe "a settlement's crossing" do
    property "is the exact crossing within the stated reads in each request, and a looser one goes on from it" do
      check all(auction <- auction()) do
        %{prices: prices, bids: bids, bid: bid, max: max} = auction
        reads = reads(auction)
        after_it = length(bids) - 1 - bid.id
        bound = 2 * ceil_log2(after_it + 1) + CcaLists.reads() + 1

        filled = Enum.find_index(prices, &(&1 >= max)) || length(prices)
        outbid = Enum.find_index(prices, &(&1 > max)) || length(prices)

        {{:ok, found}, requests} = until_found(reads, bid, &(&1 < max), bound)

        assert {found.last, found.following} == expected(auction, filled)
        assert requests <= div(filled, CcaLists.reads()) + 1

        from = %{id: found.bid, start_block: found.last}
        looser_reads = %{reads | key: make_ref()}
        {{:ok, looser}, requests} = until_found(looser_reads, from, &(&1 <= max), bound)

        assert {looser.last, looser.following} == expected(auction, outbid)
        assert requests <= div(outbid - filled + 1, CcaLists.reads()) + 1
      end
    end

    test "a long stretch no bid wrote is read across requests, each going on from the last" do
      prices = List.duplicate(5, 700) ++ [9]
      auction = auction(prices, [0], 0, 9)
      reads = reads(auction)
      below? = &(&1 < 9)

      assert {:error, :price_history_long} = CcaLists.crossing(reads, auction.bid, below?)
      assert {:error, :price_history_long} = CcaLists.crossing(reads, auction.bid, below?)

      assert {:ok, %{last: last, following: following}} =
               CcaLists.crossing(reads, auction.bid, below?)

      assert {last, following} == {Enum.at(auction.blocks, 699), Enum.at(auction.blocks, 700)}

      # Built again soon after, it reads only the crossing.
      {counted_reads, count} = counted_reads(reads)

      assert {:ok, %{last: ^last, following: ^following}} =
               CcaLists.crossing(counted_reads, auction.bid, below?)

      assert count.() == 2
    end

    # A node behind the others could not read the checkpoint the walk had
    # reached, and the walk forgot it, so the next request started over
    # (review of the money-path fixes, 12 Nov 2026).
    test "a request from a node behind the others leaves where the walk reached as it is" do
      auction = auction(List.duplicate(5, 700) ++ [9], [0], 0, 9)
      reads = reads(auction)
      below? = &(&1 < 9)

      assert {:error, :price_history_long} = CcaLists.crossing(reads, auction.bid, below?)
      assert {:error, :price_history_long} = CcaLists.crossing(reads, auction.bid, below?)

      # Pinned to the 300th block, before the one the walk reached.
      seen =
        reads(%{
          auction
          | prices: Enum.take(auction.prices, 300),
            blocks: Enum.take(auction.blocks, 300)
        })

      behind = %{reads | checkpoint: seen.checkpoint, at: seen.at}
      assert {:error, :price_history_long} = CcaLists.crossing(behind, auction.bid, below?)

      {counted_reads, count} = counted_reads(reads)
      assert {:ok, %{last: last}} = CcaLists.crossing(counted_reads, auction.bid, below?)
      assert last == Enum.at(auction.blocks, 699)
      assert count.() <= 700 - 2 * CcaLists.reads() + 2
    end

    test "a bid whose own checkpoint does not pass has no crossing to give" do
      auction = auction([5, 9, 9], [0, 1], 0, 9)

      assert {:error, :bid_needs_partial_exit_hints_unavailable} =
               CcaLists.crossing(reads(auction), auction.bid, &(&1 < 5))
    end

    test "a read that fails is the read's own answer, and keeps where the walk reached" do
      auction = auction(List.duplicate(5, 400) ++ [9], [0], 0, 9)
      reads = reads(auction)
      below? = &(&1 < 9)

      assert {:error, :price_history_long} = CcaLists.crossing(reads, auction.bid, below?)

      failing = %{reads | checkpoint: fn _block -> {:error, :chain_unavailable} end}
      assert {:error, :chain_unavailable} = CcaLists.crossing(failing, auction.bid, below?)

      {counted_reads, count} = counted_reads(reads)
      assert {:ok, _crossing} = CcaLists.crossing(counted_reads, auction.bid, below?)
      assert count.() <= 400 - CcaLists.reads() + 2
    end
  end

  # An auction's checkpoints at increasing blocks with prices that never fall,
  # bids at some of them in block order, one bid to settle and a maximum
  # above its own checkpoint's price.
  defp auction do
    gen all(
          count <- integer(1..1_500),
          flat <- one_of([constant(6), constant(300)]),
          steps <-
            list_of({integer(1..3), frequency([{flat, constant(0)}, {1, constant(1)}])},
              length: count
            ),
          bids <- one_of([integer(1..3), integer(1..400)]),
          picks <- list_of(integer(0..1_000_000), length: bids),
          pick <- integer(0..1_000_000),
          over <- integer(1..4)
        ) do
      prices = Enum.scan(steps, 7, fn {_gap, rise}, price -> price + rise end)
      at = picks |> Enum.map(&rem(&1, length(prices))) |> Enum.sort()
      bid = rem(pick, length(at))
      auction(prices, at, bid, Enum.at(prices, Enum.at(at, bid)) + over, steps)
    end
  end

  defp auction(prices, at, bid, max, steps \\ nil) do
    gaps = if steps, do: Enum.map(steps, &elem(&1, 0)), else: List.duplicate(1, length(prices))
    blocks = Enum.scan(gaps, 100, &(&1 + &2))
    starts = Enum.map(at, &Enum.at(blocks, &1))

    %{
      prices: prices,
      blocks: blocks,
      bids: starts,
      bid: %{id: bid, start_block: Enum.at(starts, bid)},
      max: max
    }
  end

  defp reads(%{prices: prices, blocks: blocks, bids: bids}) do
    checkpoints =
      blocks
      |> Enum.zip(prices)
      |> Enum.zip(tl(blocks) ++ [@last_block])
      |> Map.new(fn {{block, price}, next} -> {block, %{price: price, next: next}} end)

    starts = bids |> Enum.with_index() |> Map.new(fn {start, id} -> {id, start} end)

    %{
      bid_start: &{:ok, Map.fetch!(starts, &1)},
      checkpoint: &{:ok, Map.get(checkpoints, &1, %{price: 0, next: 0})},
      last_bid: length(bids) - 1,
      at: List.last(blocks),
      key: make_ref()
    }
  end

  # The last checkpoint before index `crossing` and the block of the one at
  # it, or `:final` past the end.
  defp expected(%{blocks: blocks}, crossing),
    do: {Enum.at(blocks, crossing - 1), Enum.at(blocks, crossing, :final)}

  # Requests until the crossing is found, each checked against `bound` reads.
  defp until_found(reads, from, below?, bound, requests \\ 1) do
    {counted_reads, count} = counted_reads(reads)
    result = CcaLists.crossing(counted_reads, from, below?)
    assert count.() <= bound

    case result do
      {:error, :price_history_long} -> until_found(reads, from, below?, bound, requests + 1)
      found -> {found, requests}
    end
  end

  defp counted_reads(reads) do
    {bid_start, starts} = counted(reads.bid_start)
    {checkpoint, checkpoints} = counted(reads.checkpoint)

    {%{reads | bid_start: bid_start, checkpoint: checkpoint},
     fn -> starts.() + checkpoints.() end}
  end

  defp counted(read) do
    counter = :counters.new(1, [])

    {fn argument ->
       :counters.add(counter, 1, 1)
       read.(argument)
     end, fn -> :counters.get(counter, 1) end}
  end

  defp ceil_log2(n) when n <= 1, do: 0
  defp ceil_log2(n), do: ceil_log2(div(n + 1, 2)) + 1
end
