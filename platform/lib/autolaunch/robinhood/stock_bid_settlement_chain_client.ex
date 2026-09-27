defmodule Autolaunch.Robinhood.StockBidSettlementChainClient do
  @moduledoc """
  The one chain read settling a bid on a Robinhood memestock auction needs:
  one snapshot before review.

  `snapshot/1` pins one block on Robinhood, reads the auction's schedule, its
  STOCK and that STOCK's admitted decimals from the launchpad, the bid's own
  record, and asks the auction what settling would do through
  `Autolaunch.Chain.CcaSettlement`: the exit that returns unspent STOCK (a
  plain exit, or a partial exit with checkpoint hints when the bid was only
  partly filled) and the claim that delivers the launch tokens.
  """

  alias Autolaunch.Chain.{CcaSettlement, Rpc}

  alias Autolaunch.{LabAbi, LabRpc}
  alias Autolaunch.Robinhood.Lab
  alias RegentChain.Address

  @doc "Everything the review states about one bid, read and simulated at one block."
  @spec snapshot(map()) :: {:ok, map()} | {:error, atom()}
  def snapshot(%{auction: auction, bid_id: bid_id, signer: signer})
      when is_integer(bid_id) and bid_id >= 0 do
    with {:ok, auction} <- Address.normalize(auction),
         {:ok, config} <- Lab.current(),
         opts <- Lab.rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         :ok <- LabRpc.ensure_contract(auction, block, opts),
         venue <- venue(config, block, opts),
         {:ok, end_block} <- call_uint(venue, auction, "endBlock()"),
         {:ok, claim_block} <- call_uint(venue, auction, "claimBlock()"),
         {:ok, stock} <-
           Rpc.call_address(auction, LabAbi.encode(venue.abi, "currency()", []), block, opts),
         {:ok, decimals} <- stock_decimals(config, stock, block, opts),
         {:ok, bid} <- CcaSettlement.bid(venue, auction, bid_id),
         {:ok, simulated} <- CcaSettlement.simulate(venue, auction, bid, end_block) do
      {:ok,
       Map.merge(simulated, %{
         auction: auction,
         block: block,
         end_block: end_block,
         claim_block: claim_block,
         stock: stock,
         stock_decimals: decimals,
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

  # `stockAdmission(stock)`: admitted, decimals, route. A revoked stock keeps
  # the decimals it was admitted with, so a settlement still formats correctly.
  defp stock_decimals(config, stock, block, opts) do
    with {:ok, [_admitted, decimals, _route]} <-
           Rpc.call_words(
             Lab.address!(config, :stocks_launchpad),
             LabAbi.encode(Lab.abi!(config, :stocks_launchpad), "stockAdmission(address)", [stock]),
             block,
             3,
             opts
           ),
         true <- decimals in 0..255 do
      {:ok, decimals}
    else
      {:error, reason} -> {:error, reason}
      _malformed -> {:error, :invalid_chain_response}
    end
  end

  defp call_uint(venue, address, signature),
    do: Rpc.call_uint(address, LabAbi.encode(venue.abi, signature, []), venue.block, venue.opts)
end
