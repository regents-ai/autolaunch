defmodule Autolaunch.ChainClient do
  @moduledoc """
  The Base reads a bid is shown and reviewed from.

  `balances/1` answers what a wallet can bid with: the auction's own currency,
  the wallet's balance of it and, on a Stocks auction that takes USDC, its
  USDC. It reads nothing about the auction's bidding window, so a balance shows
  before an auction opens.

  `snapshot/1` answers the whole reviewed question at once: the auction's own
  currency, the wallet's balance of it, both allowances that stand between it
  and the auction, and the bounded predecessor tick the canonical call needs.
  There is no partial answer: a review is derived from one snapshot or from none.
  """

  @callback balances(map()) :: {:ok, map()} | {:error, atom()}
  @callback snapshot(map()) :: {:ok, map()} | {:error, atom()}

  def module do
    case Application.fetch_env(:autolaunch, :autolaunch_bid_chain_client) do
      {:ok, module} ->
        module

      :error ->
        Autolaunch.LabBidChainClient
    end
  end
end
