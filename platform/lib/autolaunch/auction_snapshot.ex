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

  The release schedule is the one the auction was created with, read from the
  contract that stores it: each step releases `mps` millionths of a tenth of
  the supply per block (ten million in all) for a number of blocks.
  """

  alias Autolaunch.{AuctionBook, BidPrice, LabAbi}
  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.Robinhood.BlockClock
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab

  @q96 Integer.pow(2, 96)
  @mps 10_000_000
  @no_tick Integer.pow(2, 256) - 1
  # The lens reads at most this many prices; the ladder says when it stopped.
  @max_ticks 1_000

  @doc "A Base auction's snapshot, read at the latest block."
  @spec base(map()) :: {:ok, map()} | {:error, atom()}
  def base(%{auction_address: address, quote_token_decimals: decimals} = auction)
      when is_binary(address) do
    with {:ok, opts} <- AuctionBook.base_opts(auction),
         {:ok, block} <- Rpc.latest_block(opts),
         do: read(address, decimals, {block, block.number}, opts)
  end

  def base(_auction), do: {:error, :no_auction_contract}

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
      read(address, decimals, {block, clock}, opts)
    end
  end

  @doc """
  The further demand, in the auction's currency, before the clearing price
  would reach `price_q96`: what the auction still has to release at that
  price, less the demand already bidding at or above it. Nil below the
  ladder's lowest price, where no further demand is needed.
  """
  @spec needed_at(non_neg_integer(), map()) :: String.t() | nil
  def needed_at(price_q96, %{ladder: %{state: state, rungs: rungs}, decimals: decimals})
      when is_integer(price_q96) do
    if price_q96 > state.clearing_q96 do
      at_or_above =
        rungs
        |> Enum.filter(&(&1.price_q96 >= price_q96))
        |> Enum.map(& &1.demand_q96)
        |> Enum.sum()

      price_q96 |> needed_q96(at_or_above, state) |> currency(decimals)
    end
  end

  def needed_at(_price_q96, _snapshot), do: nil

  defp read(address, decimals, {block, clock}, opts) do
    with {:ok, book} <- AuctionBook.read(address, decimals, block, opts),
         {:ok, blocks} <- blocks(address, block, opts),
         {:ok, schedule} <- schedule(address, blocks.start, block, opts),
         {:ok, ladder} <- ladder(address, block, opts) do
      {:ok,
       Map.merge(book, %{
         address: address,
         clock: clock,
         blocks: blocks,
         schedule: schedule,
         ladder: ladder_view(ladder, decimals)
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
  defp ladder(address, block, opts) do
    with {:ok, next} <- uint(address, "nextActiveTickPrice()", block, opts),
         {:ok, checkpoint_block} <- uint(address, "lastCheckpointedBlock()", block, opts),
         {:ok, [clearing, _raised, _per_price, cumulative_mps, _prev, _next]} <-
           Rpc.call_words(address, LabAbi.selector("latestCheckpoint()"), block, 6, opts),
         {:ok, remaining_supply} <- uint(address, "remainingSupplyQ96X7()", block, opts),
         {:ok, above} <- uint(address, "sumCurrencyDemandAboveClearingQ96()", block, opts),
         {:ok, rungs, complete?} <- walk(address, next, block, opts, []) do
      {:ok,
       %{
         state: %{
           checkpoint_block: checkpoint_block,
           clearing_q96: clearing,
           remaining_mps: @mps - cumulative_mps,
           remaining_supply_q96x7: remaining_supply,
           demand_above_q96: above
         },
         rungs: rungs,
         complete?: complete?
       }}
    end
  end

  defp walk(_address, @no_tick, _block, _opts, rungs), do: {:ok, Enum.reverse(rungs), true}

  defp walk(_address, _price, _block, _opts, rungs) when length(rungs) == @max_ticks,
    do: {:ok, Enum.reverse(rungs), false}

  defp walk(address, price, block, opts, rungs) do
    data = LabAbi.selector("ticks(uint256)") <> word(price)

    case Rpc.call_words(address, data, block, 2, opts) do
      {:ok, [next, demand]} ->
        walk(address, next, block, opts, [%{price_q96: price, demand_q96: demand} | rungs])

      error ->
        error
    end
  end

  # Each price with the demand still bidding there and the demand the price
  # needs, lowest first, as the lens lists them.
  defp ladder_view(%{state: state, rungs: rungs, complete?: complete?}, decimals) do
    {rungs, _running} =
      Enum.map_reduce(rungs, state.demand_above_q96, fn rung, running ->
        view = %{
          price_q96: rung.price_q96,
          price: BidPrice.decimal(rung.price_q96, decimals),
          demand_q96: rung.demand_q96,
          bidding: currency(div(rung.demand_q96 * state.remaining_mps, @mps), decimals),
          needed: rung.price_q96 |> needed_q96(running, state) |> currency(decimals)
        }

        {view, max(running - rung.demand_q96, 0)}
      end)

    %{state: state, rungs: rungs, complete?: complete?}
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
