defmodule Autolaunch.Chain.CcaSettlement do
  @moduledoc """
  What settling one bid on a Continuous Clearing Auction would do right now,
  asked of the auction itself, and how a settlement receipt is read back.

  Base and Robinhood run the same auction contract behind different doors, so
  the questions live here once; each chain's client names only its venue: the
  auction ABI, the RPC door and its HTTP client, the pinned block and the read
  options.

  `simulate/4` runs, in one simulated block on top of the pinned one and in
  the order a settlement really runs, the auction's own `checkpoint()` (which
  finalises the clearing price and the raise exactly as the first settlement
  transaction would), `isGraduated()`, `clearingPrice()`, then `exitBid(bidId)`
  and `claimTokens(bidId)` from the bid's owner. Each call either succeeds with
  its own event, whose amounts the review states, or reverts with the auction's
  own error, which becomes the reason code. A bid whose maximum price is not
  strictly above the final clearing price needs `exitPartiallyFilledBid` with
  checkpoint hints; those are found in the auction's stored `checkpoints`
  (`Autolaunch.Chain.CcaLists.crossing/3`) and simulated the same way.

  While bidding is still open, a graduated auction whose clearing price is
  above a bid's maximum returns that bid's unspent money early through
  `exitPartiallyFilledBid`, but only against a stored checkpoint priced above
  the maximum. Until the auction has stored one, the exit is refused as
  `:price_not_recorded`: anyone's `checkpoint()` stores the current price, and
  the exit is accepted from then on. `return_status/1` reads, from one
  snapshot, when a bid's unspent money can come back.

  `exited/5` and `claimed/5` decode `BidExited` and `TokensClaimed` from a
  canonical receipt's logs and check they name the bid's owner, the wallet the
  auction pays whoever sent the step.
  """

  alias Autolaunch.Chain.{Abi, CcaLists, Rpc}

  alias Autolaunch.{LabAbi, LabRpc}
  alias RegentChain.Address

  @q96 79_228_162_514_264_337_593_543_950_336
  @simulate_timeout 15_000
  @bid_record_words 7

  @bid_exited "BidExited(uint256,address,uint256,uint256)"
  @tokens_claimed "TokensClaimed(uint256,address,uint256)"

  # The auction's own errors, by selector, as the reason a step is refused.
  @errors %{
    "AuctionIsNotOver()" => :auction_not_ended,
    "BidAlreadyExited()" => :already_exited,
    "CannotExitBid()" => :bid_needs_partial_exit,
    "NotClaimable()" => :claim_not_open,
    "NotGraduated()" => :nothing_to_claim,
    "BidNotExited()" => :bid_not_exited,
    "AuctionNotStarted()" => :auction_not_started,
    "InvalidLastFullyFilledCheckpointHint()" => :bid_needs_partial_exit_hints_unavailable,
    "InvalidOutbidBlockCheckpointHint()" => :bid_needs_partial_exit_hints_unavailable,
    "CannotPartiallyExitBidBeforeEndBlock()" => :auction_not_ended,
    "CannotPartiallyExitBidBeforeGraduation()" => :auction_not_ended
  }

  @typedoc "One chain's door to its auctions, pinned to one block."
  @type venue :: %{
          abi: [map()],
          rpc_url: String.t(),
          client_key: atom(),
          block: %{number: non_neg_integer(), hash: String.t()},
          opts: keyword()
        }

  @type bid :: %{
          id: non_neg_integer(),
          start_block: non_neg_integer(),
          exited_block: non_neg_integer(),
          max_price_q96: non_neg_integer(),
          owner: String.t(),
          amount: non_neg_integer(),
          tokens_filled: non_neg_integer()
        }

  def tokens_claimed_signature, do: @tokens_claimed

  @doc """
  `bids(bidId)` at the venue's block: startBlock, startCumulativeMps,
  exitedBlock, maxPrice, owner, amountQ96, tokensFilled. An unknown id answers
  with a zero owner and is refused as `:bid_not_found`.
  """
  @spec bid(venue(), String.t(), non_neg_integer()) :: {:ok, bid()} | {:error, atom()}
  def bid(venue, auction, bid_id) do
    with {:ok, [start_block, _start_mps, exited_block, max_price, owner_word, amount_q96, filled]} <-
           call_words(venue, auction, "bids(uint256)", [bid_id], @bid_record_words),
         {:ok, owner} <- Abi.word_address(owner_word) do
      {:ok,
       %{
         id: bid_id,
         start_block: start_block,
         exited_block: exited_block,
         max_price_q96: max_price,
         owner: owner,
         amount: div(amount_q96, @q96),
         tokens_filled: filled
       }}
    else
      :error -> {:error, :bid_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Whether the auction has graduated as its next checkpoint settles it: its
  own `checkpoint()` then `isGraduated()`, in one simulated block on top of
  `block`, the order `exitBid` runs them in. Once bidding has ended that
  checkpoint is the final one, so `false` means every bid comes back in full;
  while bidding is open only `true` is final, since the raise only grows.
  """
  @spec graduated(String.t(), %{number: non_neg_integer()}, keyword()) ::
          {:ok, boolean()} | {:error, atom()}
  def graduated(auction, block, opts) do
    venue = %{rpc_url: opts[:rpc_url], client_key: opts[:client_key], block: block}

    calls = [
      %{to: auction, data: LabAbi.selector("checkpoint()")},
      %{to: auction, data: LabAbi.selector("isGraduated()")}
    ]

    with {:ok, [_checkpoint, graduated]} <- simulate_calls(venue, calls),
         do: returned_bool(graduated)
  end

  @doc """
  What the auction would do for this bid right now: whether it graduated, its
  final clearing price, the exit step (`exitBid`, or `exitPartiallyFilledBid`
  with hints) or why it is refused, and the claim step or why it is refused.
  """
  @spec simulate(venue(), String.t(), bid(), non_neg_integer()) :: {:ok, map()} | {:error, atom()}
  def simulate(venue, auction, bid, end_block) do
    exit_data = LabAbi.encode(venue.abi, "exitBid(uint256)", [bid.id])
    claim_data = LabAbi.encode(venue.abi, "claimTokens(uint256)", [bid.id])

    calls = [
      %{to: auction, data: LabAbi.encode(venue.abi, "checkpoint()", [])},
      %{to: auction, data: LabAbi.encode(venue.abi, "isGraduated()", [])},
      %{to: auction, data: LabAbi.encode(venue.abi, "clearingPrice()", [])},
      %{to: auction, data: LabAbi.encode(venue.abi, "currencyRaised()", [])},
      %{to: auction, data: exit_data, from: bid.owner},
      %{to: auction, data: claim_data, from: bid.owner}
    ]

    with {:ok, [_checkpoint, graduated, clearing, raised, exit_call, claim_call]} <-
           simulate_calls(venue, calls),
         {:ok, graduated?} <- returned_bool(graduated),
         {:ok, clearing_price} <- returned_uint(clearing),
         {:ok, currency_raised} <- returned_uint(raised) do
      base = %{
        graduated?: graduated?,
        final_clearing_price_q96: clearing_price,
        currency_raised: currency_raised,
        claim: claim_outcome(venue.abi, auction, claim_call, claim_data)
      }

      case exit_outcome(venue.abi, auction, exit_call) do
        {:ok, event} ->
          {:ok, Map.put(base, :exit, exit_step("exitBid(uint256)", exit_data, nil, event))}

        {:refused, :bid_needs_partial_exit} ->
          terms = %{clearing_price: clearing_price, final_block: end_block}
          partial_exit(venue, auction, bid, terms, base)

        {:refused, :auction_not_ended}
        when graduated? and clearing_price > bid.max_price_q96 ->
          terms = %{clearing_price: clearing_price, final_block: nil}
          partial_exit(venue, auction, bid, terms, base)

        {:refused, reason} ->
          {:ok, Map.put(base, :exit, {:refused, reason})}
      end
    end
  end

  @doc """
  When the unspent money of a bid still in the auction can come back, from one
  `simulate/4` snapshot:

    * `:now`: the auction accepts the exit now (always so once bidding ended);
    * `{:minimum, raised}`: the auction has not reached its minimum, of which
      `raised` (in the currency's smallest unit) is raised so far;
    * `:record`: the price has passed the bid's maximum, but the auction
      accepts the exit only once that price is recorded, which `checkpoint()`
      does;
    * `:buying`: the maximum equals the price, so the bid is still buying and
      comes back after bidding ends;
    * `:in`: the maximum is above the price;
    * `{:refused, reason}`: the auction's own reason, such as an exited bid.
  """
  @spec return_status(map()) ::
          :now | {:minimum, non_neg_integer()} | :record | :buying | :in | {:refused, atom()}
  def return_status(%{exit: %{}}), do: :now
  def return_status(%{exit: {:refused, :price_not_recorded}}), do: :record

  def return_status(%{exit: {:refused, :auction_not_ended}, graduated?: false} = snapshot),
    do: {:minimum, snapshot.currency_raised}

  def return_status(%{
        exit: {:refused, :auction_not_ended},
        final_clearing_price_q96: price,
        bid: %{max_price_q96: price}
      }),
      do: :buying

  def return_status(%{exit: {:refused, :auction_not_ended}}), do: :in
  def return_status(%{exit: {:refused, reason}}), do: {:refused, reason}

  @doc """
  The auction's own `BidExited` for this bid and this owner, or `:unverified`
  when the receipt records something else.
  """
  @spec exited([map()], [map()], String.t(), non_neg_integer(), String.t()) ::
          {:ok, map()} | :unverified | {:error, atom()}
  def exited(abi, logs, auction, bid_id, owner) do
    with {:ok, block} <- LabRpc.block_from_logs(logs),
         {:ok, {[^bid_id, owner_word], [tokens_filled, refunded]}} <-
           LabAbi.event_words(abi, @bid_exited, logs, auction),
         {:ok, logged} <- Abi.word_address(owner_word),
         true <- Address.equal?(logged, owner) do
      {:ok, %{tokens_filled: tokens_filled, currency_refunded: refunded, block: block}}
    else
      false -> :unverified
      :error -> :unverified
      {:ok, _other_bid} -> :unverified
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The auction's own `TokensClaimed` for this bid and this owner, or
  `:unverified` when the receipt records something else.
  """
  @spec claimed([map()], [map()], String.t(), non_neg_integer(), String.t()) ::
          {:ok, map()} | :unverified | {:error, atom()}
  def claimed(abi, logs, auction, bid_id, owner) do
    with {:ok, block} <- LabRpc.block_from_logs(logs),
         {:ok, {[^bid_id, owner_word], [tokens]}} <-
           LabAbi.event_words(abi, @tokens_claimed, logs, auction),
         {:ok, logged} <- Abi.word_address(owner_word),
         true <- Address.equal?(logged, owner) do
      {:ok, %{tokens_claimed: tokens, block: block}}
    else
      false -> :unverified
      :error -> :unverified
      {:ok, _other_bid} -> :unverified
      {:error, reason} -> {:error, reason}
    end
  end

  # A bid at or below the clearing price: the last fully filled checkpoint is
  # the last stored one whose clearing price is below the bid's maximum, and the
  # outbid block is the first whose clearing price is above it (none when the
  # final price equals the maximum). Both are checked by the auction itself in
  # the same simulation before anything is reviewed.
  defp partial_exit(venue, auction, bid, terms, base) do
    claim_data = LabAbi.encode(venue.abi, "claimTokens(uint256)", [bid.id])

    with {:ok, hints} <- checkpoint_hints(venue, auction, bid, terms),
         data <-
           LabAbi.encode(venue.abi, "exitPartiallyFilledBid(uint256,uint64,uint64)", [
             bid.id,
             hints.last_fully_filled_block,
             hints.outbid_block
           ]),
         {:ok, [_checkpoint, exit_call, claim_call]} <-
           simulate_calls(venue, [
             %{to: auction, data: LabAbi.encode(venue.abi, "checkpoint()", [])},
             %{to: auction, data: data, from: bid.owner},
             %{to: auction, data: claim_data, from: bid.owner}
           ]) do
      exit =
        case exit_outcome(venue.abi, auction, exit_call) do
          {:ok, event} ->
            exit_step("exitPartiallyFilledBid(uint256,uint64,uint64)", data, hints, event)

          {:refused, :already_exited} ->
            {:refused, :already_exited}

          {:refused, _reason} ->
            {:refused, :bid_needs_partial_exit_hints_unavailable}
        end

      {:ok,
       Map.merge(base, %{
         exit: exit,
         claim: claim_outcome(venue.abi, auction, claim_call, claim_data)
       })}
    else
      {:error, reason}
      when reason in [
             :bid_needs_partial_exit_hints_unavailable,
             :price_history_long,
             :price_not_recorded
           ] ->
        {:ok, Map.put(base, :exit, {:refused, reason})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The last fully filled checkpoint is the last one priced below the bid's
  # maximum.
  defp checkpoint_hints(venue, auction, bid, terms) do
    max = bid.max_price_q96

    with {:ok, next_bid_id} <-
           Rpc.call_uint(auction, LabAbi.selector("nextBidId()"), venue.block, venue.opts),
         reads = checkpoint_reads(venue, auction, next_bid_id - 1),
         {:ok, filled} <-
           CcaLists.crossing(%{reads | key: {reads.key, max, :filled}}, bid, &(&1 < max)),
         {:ok, outbid_block} <- outbid_block(reads, filled, bid, terms) do
      {:ok, %{last_fully_filled_block: filled.last, outbid_block: outbid_block}}
    end
  end

  # None when the final price equals the maximum. Otherwise the first stored
  # checkpoint priced above it, walked to from the last fully filled one, or
  # the final one: once bidding has ended (`final_block` is the end block)
  # the settlement itself writes it; while bidding is open (`final_block` is
  # `nil`) the current price is not recorded yet.
  defp outbid_block(_reads, _filled, %{max_price_q96: price}, %{clearing_price: price}),
    do: {:ok, 0}

  defp outbid_block(reads, filled, %{max_price_q96: max}, %{final_block: final_block}) do
    from = %{id: filled.bid, start_block: filled.last}

    case CcaLists.crossing(%{reads | key: {reads.key, max, :outbid}}, from, &(&1 <= max)) do
      {:ok, %{following: :final}} when is_nil(final_block) -> {:error, :price_not_recorded}
      {:ok, %{following: :final}} -> {:ok, final_block}
      {:ok, %{following: outbid}} -> {:ok, outbid}
      {:error, reason} -> {:error, reason}
    end
  end

  # The auction's bids and checkpoints at the venue's block, for
  # `CcaLists.crossing/3`.
  defp checkpoint_reads(venue, auction, last_bid) do
    %{
      bid_start: fn id ->
        with {:ok, [start | _rest]} <-
               call_words(venue, auction, "bids(uint256)", [id], @bid_record_words),
             do: {:ok, start}
      end,
      checkpoint: fn block ->
        with {:ok, [price, _raised, _mps_per_price, _mps, _prev, next]} <-
               call_words(venue, auction, "checkpoints(uint64)", [block], 6),
             do: {:ok, %{price: price, next: next}}
      end,
      last_bid: last_bid,
      at: venue.block.number,
      key: {:erlang.phash2(venue.rpc_url), auction}
    }
  end

  defp exit_step(signature, data, hints, event) do
    %{
      signature: signature,
      data: data,
      hints: hints,
      tokens_filled: event.tokens_filled,
      currency_refunded: event.currency_refunded
    }
  end

  defp exit_outcome(abi, auction, %{"status" => "0x1", "logs" => logs}) do
    case LabAbi.event_words(abi, @bid_exited, logs, auction) do
      {:ok, {[_bid_id, _owner], [tokens_filled, refunded]}} ->
        {:ok, %{tokens_filled: tokens_filled, currency_refunded: refunded}}

      :error ->
        {:refused, :invalid_chain_response}
    end
  end

  defp exit_outcome(_abi, _auction, call), do: {:refused, reverted_reason(call)}

  # A successful claim with no event is a bid that had nothing to claim.
  defp claim_outcome(abi, auction, %{"status" => "0x1", "logs" => logs}, data) do
    case LabAbi.event_words(abi, @tokens_claimed, logs, auction) do
      {:ok, {[_bid_id, _owner], [tokens]}} when tokens > 0 ->
        %{data: data, tokens_claimed: tokens}

      _none ->
        {:refused, :nothing_to_claim}
    end
  end

  defp claim_outcome(_abi, _auction, call, _data), do: {:refused, reverted_reason(call)}

  defp reverted_reason(call) do
    case revert_data(call) do
      "0x" <> selector when byte_size(selector) >= 8 ->
        error_reason("0x" <> binary_part(selector, 0, 8))

      _none ->
        :settlement_reverted
    end
  end

  defp error_reason(selector) do
    Enum.find_value(@errors, :settlement_reverted, fn {signature, reason} ->
      if LabAbi.selector(signature) == selector, do: reason
    end)
  end

  # Base and Robinhood nodes return a refused call's error in `error.data`;
  # an anvil fork returns it as the call's `returnData`.
  defp revert_data(%{"error" => %{"data" => data}}) when is_binary(data), do: data
  defp revert_data(%{"returnData" => data}), do: data
  defp revert_data(_call), do: nil

  defp returned_bool(%{"status" => "0x1", "returnData" => data}) do
    with {:ok, [word]} <- LabAbi.decode_words(data), do: {:ok, word != 0}
  end

  defp returned_bool(_call), do: {:error, :invalid_chain_response}

  defp returned_uint(%{"status" => "0x1", "returnData" => data}) do
    with {:ok, [word]} <- LabAbi.decode_words(data), do: {:ok, word}
  end

  defp returned_uint(_call), do: {:error, :invalid_chain_response}

  # `eth_simulateV1`: one block of calls executed in order on top of the anchor
  # block, each answered with its status, return data and logs. The node's own
  # error message is never shown; a malformed answer is an unavailable chain.
  defp simulate_calls(venue, calls) do
    client = Application.get_env(:autolaunch, venue.client_key, Req)

    request = %{
      jsonrpc: "2.0",
      id: 1,
      method: "eth_simulateV1",
      params: [
        %{blockStateCalls: [%{calls: calls}], validation: false, traceTransfers: false},
        "0x" <> Integer.to_string(venue.block.number, 16)
      ]
    }

    case client.post(venue.rpc_url,
           json: request,
           connect_options: [transport_opts: [inet6: true]],
           receive_timeout: @simulate_timeout,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"result" => [%{"calls" => results}]}}}
      when length(results) == length(calls) ->
        {:ok, results}

      {:ok, _other} ->
        {:error, :chain_unavailable}

      {:error, _reason} ->
        {:error, :chain_unavailable}
    end
  rescue
    # Finch raises, not returns, when no pooled connection frees up in time.
    _error -> {:error, :chain_unavailable}
  end

  defp call_words(venue, address, signature, arguments, count) do
    Autolaunch.Chain.Rpc.call_words(
      address,
      LabAbi.encode(venue.abi, signature, arguments),
      venue.block,
      count,
      venue.opts
    )
  end
end
