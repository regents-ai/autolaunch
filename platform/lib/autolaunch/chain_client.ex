defmodule Autolaunch.ChainClient do
  @moduledoc """
  The one Base boundary a bid has: one snapshot before review, one read after each hash.

  `snapshot/1` answers the whole reviewed question at once — the auction's own
  currency, the wallet's REGENT, both allowances that stand between it and the
  auction, and the bounded predecessor tick the canonical call needs. There is no
  partial answer: a review is derived from one snapshot or from none.

  `verify/3` is read-only. The browser reports a hash and stops; whether that hash
  confirmed, reverted or contradicted its own review is decided here.
  """

  @type outcome :: %{outcome: :pending | :confirmed | :reverted | :unverified}

  @callback snapshot(map()) :: {:ok, map()} | {:error, atom()}
  @callback verify(map(), atom(), String.t()) :: {:ok, outcome()} | {:error, atom()}

  def module do
    case Application.fetch_env(:autolaunch, :autolaunch_bid_chain_client) do
      {:ok, module} ->
        module

      :error ->
        if Autolaunch.Lab.enabled?(),
          do: Autolaunch.LabBidChainClient,
          else: Autolaunch.RpcClient
    end
  end
end
