defmodule Autolaunch.LabBidSettlementChainClient do
  @moduledoc """
  The one fork boundary a Base bid settlement has: one snapshot before review,
  one read after each hash.

  `snapshot/1` pins one block on the Base fork, reads the auction's schedule,
  currency and the bid's own record, and asks the auction what settling would
  do through `Autolaunch.Chain.CcaSettlement`, which simulates the auction's
  own `checkpoint()`, `isGraduated()`, `clearingPrice()`, then the exit and
  the claim from the bid's owner, deriving `exitPartiallyFilledBid` hints when
  the bid needs them.

  `verify/3` decodes `BidExited` and `TokensClaimed` from the canonical receipt
  and checks the owner is the reviewed signer. A `record` step (the auction's
  public `checkpoint()`) is confirmed by its own successful receipt: a second
  call in a block the auction has already recorded succeeds without changing
  anything, which is as good.
  """

  alias Autolaunch.Chain.{Address, CcaSettlement, Envelope, Rpc}
  alias Autolaunch.{Lab, LabAbi, LabRpc}

  @binding_keys [:regent]

  def binding_keys, do: @binding_keys

  @doc "Everything the review states about one bid position, read and simulated at one block."
  @spec snapshot(map()) :: {:ok, map()} | {:error, atom()}
  def snapshot(%{auction: auction, bid_id: bid_id, signer: signer})
      when is_integer(bid_id) and bid_id >= 0 do
    with {:ok, auction} <- Address.normalize(auction),
         {:ok, config, block, opts} <- LabRpc.current(@binding_keys),
         :ok <- LabRpc.ensure_contract(auction, block, opts),
         venue <- venue(config, block, opts),
         {:ok, end_block} <- call_uint(venue, auction, "endBlock()"),
         {:ok, claim_block} <- call_uint(venue, auction, "claimBlock()"),
         {:ok, currency} <-
           Rpc.call_address(auction, LabAbi.encode(venue.abi, "currency()", []), block, opts),
         {:ok, bid} <- CcaSettlement.bid(venue, auction, bid_id),
         {:ok, simulated} <- CcaSettlement.simulate(venue, auction, bid, end_block) do
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

  @spec verify(map(), :record | :exit | :claim, String.t()) :: {:ok, map()} | {:error, atom()}
  def verify(envelope, step, hash) do
    with {:ok, result} <- verify_with_evidence(envelope, step, hash),
         do: {:ok, Map.delete(result, :receipt)}
  end

  def verify_with_evidence(envelope, step, hash) when step in [:record, :exit, :claim] do
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

  defp venue(config, block, opts) do
    %{
      abi: Lab.abi!(config, :auction),
      rpc_url: config.rpc_url,
      client_key: :autolaunch_lab_http_client,
      block: block,
      opts: opts
    }
  end

  defp settled(:pending, _envelope, _step, _config), do: {:ok, %{outcome: :pending}}
  defp settled(:reverted, _envelope, _step, _config), do: {:ok, %{outcome: :reverted}}

  defp settled({:success, _logs}, _envelope, :record, _config),
    do: {:ok, %{outcome: :confirmed, result: %{"price_recorded" => true}}}

  # Only the auction's own `BidExited` for this bid and this owner confirms the
  # exit; the refund and fill are adopted from it.
  defp settled({:success, logs}, envelope, :exit, config) do
    arguments = envelope["arguments"]
    bid_id = String.to_integer(arguments["onchain_bid_id"])
    abi = Lab.abi!(config, :auction)

    case CcaSettlement.exited(abi, logs, envelope["to"], bid_id, envelope["expected_signer"]) do
      {:ok, exit} ->
        decimals = String.to_integer(arguments["currency_decimals"])

        {:ok,
         %{
           outcome: :confirmed,
           result: %{
             "onchain_bid_id" => arguments["onchain_bid_id"],
             "exited" => true,
             "tokens_filled" => Integer.to_string(exit.tokens_filled),
             "tokens_filled_units" => Rpc.format_units(exit.tokens_filled, 18),
             "currency_refunded" => Integer.to_string(exit.currency_refunded),
             "currency_refunded_units" => Rpc.format_units(exit.currency_refunded, decimals),
             "local_block_hash" => exit.block.hash
           }
         }}

      :unverified ->
        {:ok, %{outcome: :unverified}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp settled({:success, logs}, envelope, :claim, config) do
    arguments = envelope["arguments"]
    bid_id = String.to_integer(arguments["onchain_bid_id"])
    abi = Lab.abi!(config, :auction)

    case CcaSettlement.claimed(abi, logs, envelope["to"], bid_id, envelope["expected_signer"]) do
      {:ok, claim} ->
        {:ok,
         %{
           outcome: :confirmed,
           result: %{
             "onchain_bid_id" => arguments["onchain_bid_id"],
             "claimed" => true,
             "tokens_claimed" => Integer.to_string(claim.tokens_claimed),
             "tokens_claimed_units" => Rpc.format_units(claim.tokens_claimed, 18),
             "local_block_hash" => claim.block.hash
           }
         }}

      :unverified ->
        {:ok, %{outcome: :unverified}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_uint(venue, address, signature),
    do: Rpc.call_uint(address, LabAbi.encode(venue.abi, signature, []), venue.block, venue.opts)

  defp current_step(envelope, step) do
    name = Atom.to_string(step)
    Enum.find(envelope["arguments"]["steps"], &(&1["step"] == name))
  end
end
