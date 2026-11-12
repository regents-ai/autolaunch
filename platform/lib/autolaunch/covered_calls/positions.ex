defmodule Autolaunch.CoveredCalls.Positions do
  @moduledoc """
  What one wallet has on a covered-call market, read now at the latest block:
  the listings it sold, the calls it may still exercise and the stock it may
  claim, each with its listing (`claimable`, which for a seller includes the
  stock due back once the window has closed), the bids it made with what
  `refundBid` would send it now (`refundable`), and the stock in the wallet
  itself (`balance`), the most it can list now: stock already listed is held by
  the contract. A sale into a bid opens a listing like any other, so it is the
  seller's sold listing and the bidder's held calls here.

  Every listing and bid that can still change is read at one block, never from
  the shared book, so anything made or changed a moment ago is here and every
  figure agrees; the settled ones come from the book's table
  (`Autolaunch.CoveredCalls.Book.settled/3`). The wallet's place is then asked
  only of the listings it can have one on: those it sold, and those some of
  which was bought (`Chain.holdings/5`). A bid stopped with nothing sold and
  nothing left to refund is finished and left out.
  """

  alias Autolaunch.CoveredCalls.{Book, Chain, Deployment}

  @spec read(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def read(symbol, wallet) do
    with {:ok, config} <- Deployment.current(),
         {:ok, %{contract: contract} = market} <- Deployment.market(symbol),
         {:ok, block, opts} <- Chain.latest(config.lab),
         {:ok, book} <- Chain.book(market, block, opts, &Book.settled?(contract, &1, &2)),
         sold = Book.settled(contract, :listing, wallet) ++ own(book.listings, :seller, wallet),
         bought = Book.settled(contract, :listing, :exercised) ++ book.listings,
         placed = Enum.filter(bought, &(&1.seller == wallet or &1.filled > 0)),
         {:ok, holdings} <- Chain.holdings(market, placed, wallet, block, opts),
         {:ok, bids} <-
           Chain.refundables(market, own(book.bids, :bidder, wallet), block, opts),
         {:ok, balance} <- Chain.balance(market.stock, wallet, block, opts) do
      listings = Map.new(placed, &{&1.id, &1})

      {:ok,
       %{
         wallet: wallet,
         market: market,
         unit: book.unit,
         now: block.timestamp,
         read_at: DateTime.utc_now(),
         sold: Enum.sort_by(sold, & &1.id),
         holdings: Enum.map(holdings, &Map.put(&1, :listing, listings[&1.listing_id])),
         bids:
           (Enum.map(Book.settled(contract, :bid, wallet), &Map.put(&1, :refundable, 0)) ++ bids)
           |> Enum.reject(&match?(%{amount: 0, refundable: 0}, &1))
           |> Enum.sort_by(& &1.id),
         balance: balance
       }}
    end
  end

  defp own(records, owner, wallet), do: Enum.filter(records, &(Map.fetch!(&1, owner) == wallet))
end
