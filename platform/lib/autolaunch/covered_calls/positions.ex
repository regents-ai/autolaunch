defmodule Autolaunch.CoveredCalls.Positions do
  @moduledoc """
  What one wallet has on a covered-call market, read now at the latest block:
  the listings it sold, on every listing the calls it may still exercise and
  the stock it may claim (`claimable`, which for a seller includes the stock
  due back once the window has closed), the bids it made with what `refundBid`
  would send it now (`refundable`), and the stock in the wallet itself
  (`balance`), the most it can list now: stock already listed is held by the
  contract. A sale into a bid opens a listing like any other, so it is the
  seller's sold listing and the bidder's held calls here. The listings, bids
  and this wallet's place on each are read at the same block, never from the
  shared book, so anything made or changed a moment ago is here and every
  figure agrees.
  """

  alias Autolaunch.CoveredCalls.{Chain, Deployment}

  @spec read(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def read(symbol, wallet) do
    with {:ok, config} <- Deployment.current(),
         {:ok, market} <- Deployment.market(symbol),
         {:ok, block, opts} <- Chain.latest(config.lab),
         {:ok, book} <- Chain.book(market, block, opts),
         book = Map.merge(book, %{market: market, read_at: DateTime.utc_now()}),
         {:ok, holdings} <- Chain.holdings(market, book.listings, wallet, block, opts),
         {:ok, bids} <- Chain.own_bids(market, book.bids, wallet, block, opts),
         {:ok, balance} <- Chain.balance(market.stock, wallet, block, opts) do
      {:ok,
       %{
         wallet: wallet,
         now: block.timestamp,
         read_at: DateTime.utc_now(),
         sold: Enum.filter(book.listings, &(&1.seller == wallet)),
         holdings: holdings,
         bids: bids,
         balance: balance,
         book: book
       }}
    end
  end
end
