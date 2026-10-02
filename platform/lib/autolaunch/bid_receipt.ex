defmodule Autolaunch.BidReceipt do
  @moduledoc """
  One bid as the auction contract holds it now: who owns it, what it put in,
  and how much of that the auction has used.

  A bid whose maximum is above the clearing price has bought at every block
  since it was placed, so its use is exact: the auction's own `calculateFill`
  over the checkpoints from the bid's first block to the one `checkpoint()`
  would record now. A bid at or below the clearing price stopped buying fully
  at some earlier checkpoint; its split is worked out when it is withdrawn,
  so it is left unstated here rather than guessed.

  Unspent money is never called withdrawable: it comes back when the bid is
  withdrawn, which the auction allows only once bidding has ended, or earlier
  once the price has passed the bid's maximum and the auction has recorded it.
  """

  alias Autolaunch.{AuctionBook, BidPrice, LabAbi}
  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab

  @q96 Integer.pow(2, 96)
  @q192 Integer.pow(2, 192)
  @mps 10_000_000

  @doc "Bid `bid_id` on a Base auction, read at the latest block."
  @spec base(map(), non_neg_integer()) :: {:ok, map()} | {:error, atom()}
  def base(%{auction_address: address, quote_token_decimals: decimals} = auction, bid_id)
      when is_binary(address) and is_integer(bid_id) and bid_id >= 0 do
    with {:ok, opts} <- AuctionBook.base_opts(auction),
         {:ok, block} <- Rpc.latest_block(opts),
         do: read(address, decimals, bid_id, block, opts)
  end

  @doc "Bid `bid_id` on the Robinhood auction at `address`, read at the latest block."
  @spec robinhood(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, map()} | {:error, atom()}
  def robinhood(address, decimals, bid_id)
      when is_binary(address) and is_integer(bid_id) and bid_id >= 0 do
    with {:ok, config} <- RobinhoodLab.current(),
         opts = RobinhoodLab.rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         do: read(address, decimals, bid_id, block, opts)
  end

  defp read(address, decimals, bid_id, block, opts) do
    with {:ok, next_id} <- uint(address, "nextBidId()", block, opts),
         :ok <- placed(bid_id, next_id),
         {:ok, bid} <- bid(address, bid_id, block, opts),
         {:ok, now} <- checkpoint(address, "checkpoint()", block, opts),
         {:ok, start} <- stored_checkpoint(address, bid.start_block, block, opts),
         {:ok, finish} <- uint(address, "endBlock()", block, opts) do
      {:ok,
       bid
       |> Map.merge(%{
         id: bid_id,
         block: block.number,
         bidding_ended?: block.number >= finish,
         deposited: Rpc.format_units(div(bid.amount_q96, @q96), decimals),
         max_price: BidPrice.decimal(bid.max_price_q96, decimals),
         standing: AuctionBook.standing(bid.max_price_q96, %{clearing_q96: now.clearing})
       })
       |> Map.merge(use(bid, start, now, decimals))}
    end
  end

  defp placed(bid_id, next_id) when bid_id < next_id, do: :ok
  defp placed(_bid_id, _next_id), do: {:error, :bid_not_found}

  defp bid(address, bid_id, block, opts) do
    data = LabAbi.selector("bids(uint256)") <> word(bid_id)

    with {:ok, [start, start_mps, exited, max_price, owner, amount_q96, filled]} <-
           Rpc.call_words(address, data, block, 7, opts),
         {:ok, owner} <- Abi.word_address(owner) do
      {:ok,
       %{
         start_block: start,
         start_mps: start_mps,
         exited_block: if(exited > 0, do: exited),
         max_price_q96: max_price,
         owner: owner,
         amount_q96: amount_q96,
         tokens_filled: filled
       }}
    else
      :error -> {:error, :invalid_chain_response}
      error -> error
    end
  end

  defp stored_checkpoint(address, block_number, block, opts),
    do: checkpoint(address, "checkpoints(uint64)", block, opts, word(block_number))

  defp checkpoint(address, signature, block, opts, argument \\ "") do
    case Rpc.call_words(address, LabAbi.selector(signature) <> argument, block, 6, opts) do
      {:ok, [clearing, _raised, per_price, cumulative_mps, _prev, _next]} ->
        {:ok, %{clearing: clearing, per_price: per_price, cumulative_mps: cumulative_mps}}

      error ->
        error
    end
  end

  # A withdrawn bid's amounts are the auction's own, from its exit.
  defp use(%{exited_block: exited}, _start, _now, _decimals) when is_integer(exited),
    do: %{state: :withdrawn}

  # Still above the price: `calculateFill` from the bid's first checkpoint to now.
  defp use(%{max_price_q96: max} = bid, start, %{clearing: clearing} = now, decimals)
       when max > clearing do
    remaining = @mps - bid.start_mps
    spent_q96 = ceil_div(bid.amount_q96 * (now.cumulative_mps - start.cumulative_mps), remaining)
    tokens = div(bid.amount_q96 * (now.per_price - start.per_price), @q192 * remaining)
    spent = ceil_div(spent_q96, @q96)
    amount = div(bid.amount_q96, @q96)

    %{
      state: :buying,
      used: Rpc.format_units(spent, decimals),
      unspent: Rpc.format_units(max(amount - spent, 0), decimals),
      tokens: Rpc.format_units(tokens, 18)
    }
  end

  defp use(_bid, _start, _now, _decimals), do: %{state: :stopped}

  defp ceil_div(a, b), do: div(a + b - 1, b)

  defp uint(address, signature, block, opts),
    do: Rpc.call_uint(address, LabAbi.selector(signature), block, opts)

  defp word(value), do: value |> Integer.to_string(16) |> String.pad_leading(64, "0")
end
