defmodule Autolaunch.ChainClient do
  @moduledoc """
  The one Base read a bid is reviewed from.

  `snapshot/1` answers the whole reviewed question at once — the auction's own
  currency, the wallet's REGENT, both allowances that stand between it and the
  auction, and the bounded predecessor tick the canonical call needs. There is no
  partial answer: a review is derived from one snapshot or from none.
  """

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
