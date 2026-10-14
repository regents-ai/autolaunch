defmodule Autolaunch.AuctionSnapshot do
  @moduledoc """
  Everything the auction page shows about an open or finished auction, read
  from the auction contract at one block: the price now and the price to beat
  (`Autolaunch.AuctionBook`), the price ladder, the release schedule and the auction's key blocks, with
  the block the auction keeps time by (`clock`): the chain's own on Base, the
  rollup block on Robinhood (`Autolaunch.Robinhood.BlockClock`).

  The ladder mirrors the pinned auction's `TickDataLens`: starting at the
  lowest price still above the clearing price, it walks the auction's list of
  maximum prices and reads, for each, the demand still bidding there and the
  further demand needed before the clearing price reaches it. Both come from
  the auction's stored state, which the auction brings up to date at its last
  recorded checkpoint (every bid records one), so the ladder names that block.
  The walk asks the chain once for each price, so it stops at the lens's count
  of prices or after three seconds, and the ladder says it stopped
  (`complete?`). A feed that holds the ladder it read last hands it back
  (`pages/4`): while the auction's stored state has not moved, a whole ladder
  is not read again and one that stopped is carried on from where it stopped.

  A ladder lists the hundred prices nearest the clearing price (`rungs`) and
  says how many it read beyond them (`more`) and the highest of them all
  (`highest_q96`). Every price it read stays with it, packed as one binary
  (`prices`: each price and the demand there, 32 bytes apiece, lowest first),
  which is what the demand needed at a drafted price counts (`needed_at/2`)
  and what the next walk starts from. Every page showing the auction holds
  its own copy of the listed prices and shares the one binary.

  The release schedule is the one the auction was created with, read from the
  contract that stores it: each step releases `mps` millionths of a tenth of
  the supply per block (ten million in all) for a number of blocks.
  """

  require Logger

  alias Autolaunch.Auction.MarketState
  alias Autolaunch.{AuctionBook, AuctionStage, BidPrice, LabAbi, MarketReadings, Pool}
  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.Robinhood.BlockClock
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab

  @q96 Integer.pow(2, 96)
  @mps 10_000_000
  @no_tick Integer.pow(2, 256) - 1
  # The lens reads at most this many prices; the ladder says when it stopped.
  @max_ticks 1_000
  # A ladder lists this many of them, the nearest above the clearing price.
  @listed 100
  # The longest one walk of the prices takes; the ladder says when it stopped.
  @walk_budget_ms 3_000
  # A feed reads this many pages at once, each for at most this long.
  @page_concurrency 8
  @page_budget_ms 6_000
  @book [
    :block,
    :clearing_q96,
    :clearing,
    :decimals,
    :tick_spacing_q96,
    :max_bid_price_q96,
    :price_to_beat_q96,
    :price_to_beat
  ]

  @doc """
  Everything a Base auction's own page shows from the chain, read at `block`
  with the options a market feed already reads with: the snapshot, the
  auction's stage (`Autolaunch.AuctionStage`) and the amount raised. `state`
  is the state the auction's row takes from the same pass, and `pool` its
  pool's reading at the same block.
  """
  @spec page(map(), atom(), {:ok, map()} | {:error, atom()}, map(), keyword(), map() | nil) ::
          {:ok, map()} | {:error, atom()}
  def page(auction, state, pool, block, opts, held_ladder \\ nil)

  def page(
        %{auction_address: address, quote_token_decimals: decimals} = auction,
        state,
        pool,
        block,
        opts,
        held_ladder
      )
      when is_binary(address) and is_integer(decimals) do
    with {:ok, snapshot} <- read(address, decimals, {block, block.number}, opts, held_ladder) do
      required = String.to_integer(auction.required_currency_raised)

      {:ok,
       Map.merge(snapshot, %{
         stage: AuctionStage.read(state, snapshot, required, pool),
         raised: Rpc.format_units(snapshot.blocks.raised, decimals)
       })}
    end
  end

  def page(_auction, _state, _pool, _block, _opts, _held_ladder),
    do: {:error, :no_auction_contract}

  @doc """
  A market feed's pass over its auctions' pages, after their figures: each
  `{auction, state}` read with `page/6` at `block`, apart from the figures and
  on its own budget, with the ladder the feed holds for it. Answers each
  address's `{:ok, page}`, or `:error` for a page that could not be read or
  was not done in six seconds, so a slow page costs its auction's figures, and
  every other auction, nothing.
  """
  @spec pages([{map(), atom()}], map(), map(), keyword()) :: %{
          String.t() => {:ok, map()} | :error
        }
  def pages(auctions, config, block, opts) do
    Autolaunch.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      auctions,
      fn {auction, state} -> feed_page(auction, state, config, block, opts) end,
      max_concurrency: @page_concurrency,
      ordered: false,
      timeout: @page_budget_ms,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Map.new(fn
      {:ok, {address, {:ok, page}}} -> {address, {:ok, page}}
      {:ok, {address, {:error, reason}}} -> unread_page(address, reason)
      {:exit, {{auction, _state}, reason}} -> unread_page(auction.auction_address, reason)
    end)
  end

  defp feed_page(auction, state, config, block, opts) do
    state = MarketState.join(auction.state, state)
    pool = Pool.read_at(%{auction | state: state}, config, block, opts)

    {String.downcase(auction.auction_address),
     auction |> page(state, pool, block, opts, held(auction)) |> counted()}
  end

  # A ladder that keeps stopping (more prices than it lists, or a chain too
  # slow to read them in a pass) shows here without anyone opening its page.
  defp counted({:ok, %{ladder: %{complete?: false}}} = page) do
    :telemetry.execute([:autolaunch, :auction_page, :ladder_stopped], %{count: 1}, %{})
    page
  end

  defp counted(page), do: page

  defp held(auction) do
    case MarketReadings.page(auction.auction_address) do
      {:ok, %{reading: %{ladder: ladder}}} -> ladder
      _none -> nil
    end
  end

  defp unread_page(address, reason) do
    Logger.warning("market feed could not read the page of #{address}: #{inspect(reason)}")
    {String.downcase(address), :error}
  end

  @doc "The book a snapshot was built on (`Autolaunch.AuctionBook`), for a caller that shows only that."
  @spec book(map()) :: map()
  def book(snapshot), do: Map.take(snapshot, @book)

  @doc "A Robinhood auction's snapshot by its address, read at the latest block."
  @spec robinhood(String.t()) :: {:ok, map()} | {:error, atom()}
  def robinhood(address) when is_binary(address) do
    with {:ok, config} <- RobinhoodLab.current(),
         opts = RobinhoodLab.rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, currency} <- uint(address, "currency()", block, opts),
         {:ok, currency} <- word_address(currency),
         {:ok, decimals} <- uint(currency, "decimals()", block, opts),
         {:ok, clock} <- BlockClock.read(block, opts) do
      read(address, decimals, {block, clock}, opts, nil)
    end
  end

  @doc """
  The further demand, in the auction's currency, before the clearing price
  would reach `price_q96`: what the auction still has to release at that
  price, less the demand already bidding at or above it. Nil below the
  ladder's lowest price, where no further demand is needed.
  """
  @spec needed_at(non_neg_integer(), map()) :: String.t() | nil
  def needed_at(price_q96, %{ladder: %{state: state, prices: prices}, decimals: decimals})
      when is_integer(price_q96) do
    if price_q96 > state.clearing_q96 do
      at_or_above =
        for <<price::256, demand::256 <- prices>>, price >= price_q96, reduce: 0 do
          sum -> sum + demand
        end

      price_q96 |> needed_q96(at_or_above, state) |> currency(decimals)
    end
  end

  def needed_at(_price_q96, _snapshot), do: nil

  defp read(address, decimals, {block, clock}, opts, held_ladder) do
    with {:ok, book} <- AuctionBook.read(address, decimals, {block, clock}, opts),
         {:ok, blocks} <- blocks(address, block, opts),
         {:ok, schedule} <- schedule(address, blocks.start, block, opts),
         {:ok, ladder} <- ladder(address, decimals, block, opts, held_ladder) do
      {:ok,
       Map.merge(book, %{
         address: address,
         clock: clock,
         blocks: blocks,
         schedule: schedule,
         ladder: ladder
       })}
    end
  end

  defp blocks(address, block, opts) do
    with {:ok, start} <- uint(address, "startBlock()", block, opts),
         {:ok, finish} <- uint(address, "endBlock()", block, opts),
         {:ok, claim} <- uint(address, "claimBlock()", block, opts),
         {:ok, supply} <- uint(address, "totalSupply()", block, opts),
         {:ok, cleared} <- uint(address, "totalCleared()", block, opts),
         {:ok, raised} <- uint(address, "currencyRaised()", block, opts) do
      {:ok,
       %{
         start: start,
         end: finish,
         claim: claim,
         supply: supply,
         cleared: cleared,
         raised: raised
       }}
    end
  end

  # The steps stored at `pointer()`: SSTORE2 keeps them after one leading
  # zero byte, eight bytes a step, three for `mps` and five for the block count.
  defp schedule(address, start, block, opts) do
    with {:ok, pointer} <- uint(address, "pointer()", block, opts),
         {:ok, pointer} <- word_address(pointer),
         {:ok, "0x00" <> hex} <-
           Rpc.request(
             "eth_getCode",
             [pointer, "0x" <> Integer.to_string(block.number, 16)],
             opts
           ),
         {:ok, bytes} <- Base.decode16(hex, case: :mixed) do
      {steps, _end} =
        Enum.map_reduce(for(<<mps::24, blocks::40 <- bytes>>, do: {mps, blocks}), start, fn
          {mps, blocks}, from -> {%{from: from, to: from + blocks, mps: mps}, from + blocks}
        end)

      {:ok, steps}
    else
      {:ok, _other} -> {:error, :invalid_chain_response}
      :error -> {:error, :invalid_chain_response}
      error -> error
    end
  end

  @doc """
  The share of the supply the schedule has released by `at_block`, in
  millionths of a tenth (ten million is all of it).
  """
  @spec released_mps([map()], non_neg_integer()) :: non_neg_integer()
  def released_mps(steps, at_block) do
    Enum.reduce(steps, 0, fn %{from: from, to: to, mps: mps}, sum ->
      sum + mps * max(min(at_block, to) - from, 0)
    end)
  end

  # The auction's stored state the lens starts from, then its prices from the
  # lowest one above the clearing price upward.
  defp ladder(address, decimals, block, opts, held) do
    with {:ok, next} <- uint(address, "nextActiveTickPrice()", block, opts),
         {:ok, checkpoint_block} <- uint(address, "lastCheckpointedBlock()", block, opts),
         {:ok, [clearing, _raised, _per_price, cumulative_mps, _prev, _next]} <-
           Rpc.call_words(address, LabAbi.selector("latestCheckpoint()"), block, 6, opts),
         {:ok, remaining_supply} <- uint(address, "remainingSupplyQ96X7()", block, opts),
         {:ok, above} <- uint(address, "sumCurrencyDemandAboveClearingQ96()", block, opts) do
      state = %{
        checkpoint_block: checkpoint_block,
        clearing_q96: clearing,
        remaining_mps: @mps - cumulative_mps,
        remaining_supply_q96x7: remaining_supply,
        demand_above_q96: above
      }

      {read, from} = begun(held, state, next)
      left = @max_ticks - length(read)
      until = System.monotonic_time(:millisecond) + @walk_budget_ms

      with {:ok, rungs, complete?} <- walk(address, from, block, opts, read, left, until) do
        {:ok, ladder_view(%{state: state, rungs: rungs, complete?: complete?}, decimals)}
      end
    end
  end

  # What the walk already has, highest first, and the price it reads next.
  #
  # The prices and the demand at each are the auction's stored state. Only a
  # bid adds a price or adds demand to one, and a bid records a checkpoint at
  # its own block and adds to the demand above the clearing price; only a walk
  # of the auction's own moves the lowest price. So the prices a held ladder
  # read at this checkpoint, with this demand above and this lowest price, are
  # the ladder's now: a whole one needs no reading, and one that stopped goes
  # on from its highest price, read again for the price after it.
  defp begun(%{state: state, prices: <<next::256, _rest::binary>> = prices} = held, state, next) do
    [highest | lower] =
      Enum.reverse(
        for <<price::256, demand::256 <- prices>>, do: %{price_q96: price, demand_q96: demand}
      )

    if held.complete?, do: {[highest | lower], @no_tick}, else: {lower, highest.price_q96}
  end

  defp begun(_held, _state, next), do: {[], next}

  defp walk(_address, @no_tick, _block, _opts, rungs, _left, _until),
    do: {:ok, Enum.reverse(rungs), true}

  defp walk(_address, _price, _block, _opts, rungs, 0, _until),
    do: {:ok, Enum.reverse(rungs), false}

  defp walk(address, price, block, opts, rungs, left, until) do
    if System.monotonic_time(:millisecond) < until do
      data = LabAbi.selector("ticks(uint256)") <> word(price)

      case Rpc.call_words(address, data, block, 2, opts) do
        {:ok, [next, demand]} ->
          rung = %{price_q96: price, demand_q96: demand}
          walk(address, next, block, opts, [rung | rungs], left - 1, until)

        error ->
          error
      end
    else
      {:ok, Enum.reverse(rungs), false}
    end
  end

  # The nearest prices, each with the demand still bidding there and the
  # demand the price needs, lowest first, as the lens lists them; and every
  # price the walk read, packed.
  defp ladder_view(%{state: state, rungs: rungs, complete?: complete?}, decimals) do
    {nearest, beyond} = Enum.split(rungs, @listed)

    {listed, _running} =
      Enum.map_reduce(nearest, state.demand_above_q96, fn rung, running ->
        view = %{
          price_q96: rung.price_q96,
          price: BidPrice.decimal(rung.price_q96, decimals),
          bidding: currency(div(rung.demand_q96 * state.remaining_mps, @mps), decimals),
          needed: rung.price_q96 |> needed_q96(running, state) |> currency(decimals)
        }

        {view, max(running - rung.demand_q96, 0)}
      end)

    %{
      state: state,
      complete?: complete?,
      rungs: listed,
      more: length(beyond),
      highest_q96: with(%{price_q96: highest} <- List.last(rungs), do: highest),
      prices:
        for(
          %{price_q96: price, demand_q96: demand} <- rungs,
          into: <<>>,
          do: <<price::256, demand::256>>
        )
    }
  end

  # TickDataLens: the demand a price needs, less the demand at or above it,
  # scaled to what the auction has left to release; rounded up throughout.
  defp needed_q96(_price, _running, %{remaining_mps: 0}), do: 0

  defp needed_q96(price, running, state) do
    required = ceil_div(state.remaining_supply_q96x7 * price, @q96 * state.remaining_mps)
    ceil_div(max(required - running, 0) * state.remaining_mps, @mps)
  end

  # A Q96 currency amount in whole currency, rounded up to its smallest unit.
  defp currency(q96, decimals), do: q96 |> ceil_div(@q96) |> Rpc.format_units(decimals)

  defp ceil_div(a, b), do: div(a + b - 1, b)

  defp uint(address, signature, block, opts),
    do: Rpc.call_uint(address, LabAbi.selector(signature), block, opts)

  defp word(value), do: value |> Integer.to_string(16) |> String.pad_leading(64, "0")

  defp word_address(value) do
    case Abi.word_address(value) do
      {:ok, address} -> {:ok, address}
      :error -> {:error, :invalid_chain_response}
    end
  end
end
