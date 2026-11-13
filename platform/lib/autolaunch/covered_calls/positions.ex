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

  Every listing and bid that can still change for this wallet is read at one
  block, never from the shared book, so anything made or changed a moment ago
  is here and every figure agrees. The rest come as the book's table keeps
  them (`Autolaunch.CoveredCalls.Book.kept/3`): who made a listing or bid never
  changes, so of the bids only the wallet's own are read again, and a listing
  of someone else's that stopped or whose window has closed is read once,
  since nothing a holder has on it changes after that but by the holder's own
  claim. Any listing or bid the table does not hold yet is read and kept. The
  wallet's place is then asked only of the listings it can have one on: those
  it sold, and those some of which was bought (`Chain.holdings/5`). A bid
  stopped with nothing sold and nothing left to refund is finished and left
  out.
  """

  alias Autolaunch.CoveredCalls.{Book, Chain, Deployment}

  @spec read(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def read(symbol, wallet) do
    with {:ok, config} <- Deployment.current(),
         {:ok, %{contract: contract} = market} <- Deployment.market(symbol),
         {:ok, block, opts} <- Chain.latest(config.lab),
         {:ok, book} <- Chain.book(market, block, opts, &read_again?(contract, wallet, &1, &2)),
         :ok <- Book.keep(contract, book),
         sold =
           with_kept(
             own(book.listings, :seller, wallet),
             Book.settled(contract, :listing, wallet)
           ),
         bought = with_kept(book.listings, Book.bought(contract, wallet)),
         placed = Enum.filter(bought, &(&1.seller == wallet or &1.filled > 0)),
         {:ok, holdings} <- Chain.holdings(market, placed, wallet, block, opts),
         {:ok, bids} <-
           Chain.refundables(market, own(book.bids, :bidder, wallet), block, opts),
         {:ok, balance} <- Chain.balance(market.stock, wallet, block, opts) do
      listings = Map.new(placed, &{&1.id, &1})
      settled_bids = Enum.map(Book.settled(contract, :bid, wallet), &Map.put(&1, :refundable, 0))

      {:ok,
       %{
         wallet: wallet,
         market: market,
         unit: book.unit,
         now: block.timestamp,
         read_at: DateTime.utc_now(),
         sold: sold,
         holdings: Enum.map(holdings, &Map.put(&1, :listing, listings[&1.listing_id])),
         bids:
           bids
           |> with_kept(settled_bids)
           |> Enum.reject(&match?(%{amount: 0, refundable: 0}, &1)),
         balance: balance
       }}
    end
  end

  # The records just read with the kept ones, by id; one both read now and
  # kept (it was kept while this read) is as read now.
  defp with_kept(read, kept), do: (read ++ kept) |> Enum.uniq_by(& &1.id) |> Enum.sort_by(& &1.id)

  # A listing or bid is read for `wallet` the first time, and again while it
  # can change for `wallet`: its own while not settled, and someone else's
  # listing while it is open, sold out or in its window.
  defp read_again?(contract, wallet, kind, id) do
    case {kind, Book.kept(contract, kind, id)} do
      {_kind, nil} -> true
      {_kind, {_owner, :settled, _record}} -> false
      {_kind, {^wallet, _state, _record}} -> true
      {:listing, {_seller, state, _record}} -> state == :live
      {:bid, {_bidder, _state, _record}} -> false
    end
  end

  defp own(records, owner, wallet), do: Enum.filter(records, &(Map.fetch!(&1, owner) == wallet))
end
