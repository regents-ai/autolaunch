defmodule Autolaunch.LabBidSettlementChainClient do
  @moduledoc """
  The one fork boundary a Base bid settlement has: one snapshot before review.

  `snapshot/1` pins one block on the Base fork, reads the auction's schedule,
  currency and the bid's own record, and asks the auction what settling would
  do through `Autolaunch.Chain.CcaSettlement`, which simulates the auction's
  own `checkpoint()`, `isGraduated()`, `clearingPrice()`, then the exit and
  the claim from the bid's owner, deriving `exitPartiallyFilledBid` hints when
  the bid needs them.

  What a sent step did is read from its receipt by
  `Autolaunch.BidSettlementActions.result/3`.
  """

  alias Autolaunch.Chain.{CcaSettlement, Rpc}

  alias Autolaunch.{Lab, LabAbi, LabRpc}
  alias RegentChain.Address

  @binding_keys [:regent]

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
         signer: signer
       })}
    else
      :error -> {:error, :invalid_chain_response}
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

  defp call_uint(venue, address, signature),
    do: Rpc.call_uint(address, LabAbi.encode(venue.abi, signature, []), venue.block, venue.opts)
end
