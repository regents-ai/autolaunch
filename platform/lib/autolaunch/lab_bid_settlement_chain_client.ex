defmodule Autolaunch.LabBidSettlementChainClient do
  @moduledoc """
  The one fork boundary a bid settlement has: one snapshot before review, one
  read after each hash.

  `snapshot/1` asks the auction itself what settling this bid would do right
  now. The fork simulates, in one block and in order, the auction's own
  `checkpoint()` (which finalises the clearing price and the raise exactly as
  the first settlement transaction would), `isGraduated()`, `clearingPrice()`,
  then `exitBid(bidId)` and `claimTokens(bidId)` from the bid's owner. Each
  call either succeeds with its own event, whose amounts the review states, or
  reverts with the auction's own error, which becomes the reason code. A bid
  whose maximum price is not strictly above the final clearing price needs
  `exitPartiallyFilledBid` with checkpoint hints; those are derived by a
  bounded walk over the auction's stored `checkpoints` and simulated the same
  way, and refused when the walk cannot find them.

  `verify/3` decodes `BidExited` and `TokensClaimed` from the canonical receipt
  and checks the owner is the reviewed signer.
  """

  alias Autolaunch.Chain.{Abi, Address, Envelope, Rpc}
  alias Autolaunch.{Lab, LabAbi, LabRpc}

  @binding_keys [:regent]
  @max_checkpoint_walk 256
  @max_block_number Integer.pow(2, 64) - 1
  @q96 79_228_162_514_264_337_593_543_950_336
  @simulate_timeout 15_000

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

  def binding_keys, do: @binding_keys

  @doc "Everything the review states about one bid position, read and simulated at one block."
  @spec snapshot(map()) :: {:ok, map()} | {:error, atom()}
  def snapshot(%{auction: auction, bid_id: bid_id, signer: signer})
      when is_integer(bid_id) and bid_id >= 0 do
    with {:ok, auction} <- Address.normalize(auction),
         {:ok, config, block, opts} <- LabRpc.current(@binding_keys),
         :ok <- LabRpc.ensure_contract(auction, block, opts),
         abi <- Lab.abi!(config, :auction),
         {:ok, end_block} <- call_uint(abi, auction, "endBlock()", [], block, opts),
         {:ok, claim_block} <- call_uint(abi, auction, "claimBlock()", [], block, opts),
         {:ok, currency} <-
           Rpc.call_address(auction, LabAbi.encode(abi, "currency()", []), block, opts),
         {:ok, bid} <- bid(abi, auction, bid_id, block, opts),
         {:ok, simulated} <-
           simulate_settlement(config, abi, auction, bid, bid_id, end_block, block, opts) do
      {:ok,
       Map.merge(simulated, %{
         auction: auction,
         block: block,
         end_block: end_block,
         claim_block: claim_block,
         currency: currency,
         bid: bid,
         signer: signer,
         lab_binding: Lab.binding(config, @binding_keys)
       })}
    else
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_chain_response}
    end
  end

  @spec verify(map(), :exit | :claim, String.t()) :: {:ok, map()} | {:error, atom()}
  def verify(envelope, step, hash) do
    with {:ok, result} <- verify_with_evidence(envelope, step, hash),
         do: {:ok, Map.delete(result, :receipt)}
  end

  def verify_with_evidence(envelope, step, hash) when step in [:exit, :claim] do
    with true <-
           Envelope.valid_for_confirmation?(envelope,
             resource: "autolaunch_bid",
             chain_id: Lab.chain_id()
           ),
         true <- Lab.binding_matches?(envelope["metadata"]["lab"], @binding_keys),
         {:ok, config} <- Lab.current(),
         %{} = current <- current_step(envelope, step),
         {:ok, evidence} <- LabRpc.canonical_outcome_evidence(config, envelope, current, hash),
         {:ok, result} <- settled(evidence.outcome, envelope, step, config) do
      {:ok, Map.put(result, :receipt, evidence.receipt)}
    else
      false -> {:error, :lab_config_changed}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_chain_response}
    end
  end

  # `bids(bidId)`: startBlock, startCumulativeMps, exitedBlock, maxPrice, owner,
  # amountQ96, tokensFilled. An unknown id answers with a zero owner.
  defp bid(abi, auction, bid_id, block, opts) do
    with {:ok, [start_block, _start_mps, exited_block, max_price, owner_word, amount_q96, filled]} <-
           call_words(abi, auction, "bids(uint256)", [bid_id], 7, block, opts),
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

  # One simulated block, on top of the block the review is anchored to, in the
  # order a settlement really runs: finalise, read, exit, claim.
  defp simulate_settlement(config, abi, auction, bid, bid_id, end_block, block, opts) do
    exit_data = LabAbi.encode(abi, "exitBid(uint256)", [bid_id])
    claim_data = LabAbi.encode(abi, "claimTokens(uint256)", [bid_id])

    calls = [
      %{to: auction, data: LabAbi.encode(abi, "checkpoint()", [])},
      %{to: auction, data: LabAbi.encode(abi, "isGraduated()", [])},
      %{to: auction, data: LabAbi.encode(abi, "clearingPrice()", [])},
      %{to: auction, data: exit_data, from: bid.owner},
      %{to: auction, data: claim_data, from: bid.owner}
    ]

    with {:ok, [_checkpoint, graduated, clearing, exit_call, claim_call]} <-
           simulate(config, block, calls),
         {:ok, graduated?} <- returned_bool(graduated),
         {:ok, clearing_price} <- returned_uint(clearing) do
      base = %{
        graduated?: graduated?,
        final_clearing_price_q96: clearing_price,
        claim: claim_outcome(abi, auction, claim_call, claim_data)
      }

      case exit_outcome(abi, auction, exit_call) do
        {:ok, event} ->
          {:ok, Map.put(base, :exit, exit_step("exitBid(uint256)", exit_data, nil, event))}

        {:refused, :bid_needs_partial_exit} ->
          terms = %{bid_id: bid_id, clearing_price: clearing_price, end_block: end_block}
          partial_exit(config, abi, auction, bid, terms, block, opts, base)

        {:refused, reason} ->
          {:ok, Map.put(base, :exit, {:refused, reason})}
      end
    end
  end

  # A bid at or below the final clearing price: the last fully filled checkpoint
  # is the last stored one whose clearing price is below the bid's maximum, and
  # the outbid block is the first whose clearing price is above it (none when
  # the final price equals the maximum). Both are checked by the auction itself
  # in the same simulation before anything is reviewed.
  defp partial_exit(config, abi, auction, bid, terms, block, opts, base) do
    %{bid_id: bid_id, clearing_price: clearing_price, end_block: end_block} = terms
    claim_data = LabAbi.encode(abi, "claimTokens(uint256)", [bid_id])

    with {:ok, hints} <-
           checkpoint_hints(abi, auction, bid, clearing_price, end_block, block, opts),
         data <-
           LabAbi.encode(abi, "exitPartiallyFilledBid(uint256,uint64,uint64)", [
             bid_id,
             hints.last_fully_filled_block,
             hints.outbid_block
           ]),
         {:ok, [_checkpoint, exit_call, claim_call]} <-
           simulate(config, block, [
             %{to: auction, data: LabAbi.encode(abi, "checkpoint()", [])},
             %{to: auction, data: data, from: bid.owner},
             %{to: auction, data: claim_data, from: bid.owner}
           ]) do
      exit =
        case exit_outcome(abi, auction, exit_call) do
          {:ok, event} ->
            exit_step("exitPartiallyFilledBid(uint256,uint64,uint64)", data, hints, event)

          {:refused, _reason} ->
            {:refused, :bid_needs_partial_exit_hints_unavailable}
        end

      {:ok,
       Map.merge(base, %{exit: exit, claim: claim_outcome(abi, auction, claim_call, claim_data)})}
    else
      {:error, :bid_needs_partial_exit_hints_unavailable} ->
        {:ok, Map.put(base, :exit, {:refused, :bid_needs_partial_exit_hints_unavailable})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp checkpoint_hints(abi, auction, bid, clearing_price, end_block, block, opts) do
    with {:ok, last_full, outbid} <-
           walk_checkpoints(abi, auction, bid.start_block, bid.max_price_q96, block, opts, nil, 0) do
      outbid_block =
        cond do
          clearing_price == bid.max_price_q96 -> 0
          is_integer(outbid) -> outbid
          true -> end_block
        end

      {:ok, %{last_fully_filled_block: last_full, outbid_block: outbid_block}}
    end
  end

  # Follows `checkpoints(block).next` from the bid's own start checkpoint. The
  # walk returns the last block whose clearing price is below the maximum and
  # the first stored block whose price is above it, or `:final` when only the
  # checkpoint the settlement itself writes at the end block crosses it.
  defp walk_checkpoints(
         _abi,
         _auction,
         _current,
         _max,
         _block,
         _opts,
         _last,
         @max_checkpoint_walk
       ),
       do: {:error, :bid_needs_partial_exit_hints_unavailable}

  defp walk_checkpoints(abi, auction, current, max_price, block, opts, last_full, hops) do
    with {:ok, [price, _raised, _mps_per_price, _mps, _prev, next]} <-
           call_words(abi, auction, "checkpoints(uint64)", [current], 6, block, opts) do
      cond do
        price < max_price and next == @max_block_number ->
          {:ok, current, :final}

        price < max_price ->
          walk_checkpoints(abi, auction, next, max_price, block, opts, current, hops + 1)

        price == max_price and is_integer(last_full) and next == @max_block_number ->
          {:ok, last_full, :final}

        price == max_price and is_integer(last_full) ->
          walk_checkpoints(abi, auction, next, max_price, block, opts, last_full, hops + 1)

        price > max_price and is_integer(last_full) ->
          {:ok, last_full, current}

        true ->
          {:error, :bid_needs_partial_exit_hints_unavailable}
      end
    end
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

  defp reverted_reason(%{"returnData" => "0x" <> selector}) when byte_size(selector) >= 8 do
    Enum.find_value(@errors, :settlement_reverted, fn {signature, reason} ->
      if LabAbi.selector(signature) == "0x" <> binary_part(selector, 0, 8), do: reason
    end)
  end

  defp reverted_reason(_call), do: :settlement_reverted

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
  defp simulate(config, block, calls) do
    client = Application.get_env(:autolaunch, :autolaunch_lab_http_client, Req)

    request = %{
      jsonrpc: "2.0",
      id: 1,
      method: "eth_simulateV1",
      params: [
        %{blockStateCalls: [%{calls: calls}], validation: false, traceTransfers: false},
        "0x" <> Integer.to_string(block.number, 16)
      ]
    }

    case client.post(config.rpc_url,
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
    _error -> {:error, :chain_unavailable}
  end

  defp settled(:pending, _envelope, _step, _config), do: {:ok, %{outcome: :pending}}
  defp settled(:reverted, _envelope, _step, _config), do: {:ok, %{outcome: :reverted}}

  # Only the auction's own `BidExited` for this bid and this owner confirms the
  # exit; the refund and fill are adopted from it.
  defp settled({:success, logs}, envelope, :exit, config) do
    arguments = envelope["arguments"]
    bid_id = String.to_integer(arguments["onchain_bid_id"])

    with {:ok, block} <- LabRpc.block_from_logs(logs),
         {:ok, {[^bid_id, owner_word], [tokens_filled, refunded]}} <-
           LabAbi.event_words(Lab.abi!(config, :auction), @bid_exited, logs, envelope["to"]),
         {:ok, owner} <- Abi.word_address(owner_word),
         true <- Address.equal?(owner, envelope["expected_signer"]) do
      decimals = String.to_integer(arguments["currency_decimals"])

      {:ok,
       %{
         outcome: :confirmed,
         result: %{
           "onchain_bid_id" => arguments["onchain_bid_id"],
           "exited" => true,
           "tokens_filled" => Integer.to_string(tokens_filled),
           "tokens_filled_units" => Rpc.format_units(tokens_filled, 18),
           "currency_refunded" => Integer.to_string(refunded),
           "currency_refunded_units" => Rpc.format_units(refunded, decimals),
           "local_block_hash" => block.hash
         }
       }}
    else
      false -> {:ok, %{outcome: :unverified}}
      :error -> {:ok, %{outcome: :unverified}}
      {:ok, _other_bid} -> {:ok, %{outcome: :unverified}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp settled({:success, logs}, envelope, :claim, config) do
    arguments = envelope["arguments"]
    bid_id = String.to_integer(arguments["onchain_bid_id"])

    with {:ok, block} <- LabRpc.block_from_logs(logs),
         {:ok, {[^bid_id, owner_word], [tokens]}} <-
           LabAbi.event_words(Lab.abi!(config, :auction), @tokens_claimed, logs, envelope["to"]),
         {:ok, owner} <- Abi.word_address(owner_word),
         true <- Address.equal?(owner, envelope["expected_signer"]) do
      {:ok,
       %{
         outcome: :confirmed,
         result: %{
           "onchain_bid_id" => arguments["onchain_bid_id"],
           "claimed" => true,
           "tokens_claimed" => Integer.to_string(tokens),
           "tokens_claimed_units" => Rpc.format_units(tokens, 18),
           "local_block_hash" => block.hash
         }
       }}
    else
      false -> {:ok, %{outcome: :unverified}}
      :error -> {:ok, %{outcome: :unverified}}
      {:ok, _other_bid} -> {:ok, %{outcome: :unverified}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp call_uint(abi, address, signature, arguments, block, opts),
    do: Rpc.call_uint(address, LabAbi.encode(abi, signature, arguments), block, opts)

  defp call_words(abi, address, signature, arguments, count, block, opts),
    do: Rpc.call_words(address, LabAbi.encode(abi, signature, arguments), block, count, opts)

  defp current_step(envelope, step) do
    name = Atom.to_string(step)
    Enum.find(envelope["arguments"]["steps"], &(&1["step"] == name))
  end
end
