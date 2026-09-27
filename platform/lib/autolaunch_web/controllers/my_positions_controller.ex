defmodule AutolaunchWeb.MyPositionsController do
  @moduledoc """
  The signed-in person's own bids and launched tokens, for the page tool that
  reads them (`autolaunch_my_positions`). The session names the account, and
  only the wallets it has verified are read, as on /portfolio. Everything is
  read now, from the site's records and the chain; a read that fails refuses
  the whole answer rather than leave part of it out.
  """

  use AutolaunchWeb, :controller

  alias Autolaunch.Actors.Human
  alias Autolaunch.{AuctionBook, TokenHoldings}
  alias Autolaunch.Robinhood.Positions, as: RobinhoodPositions
  alias AutolaunchWeb.{ApiError, BidSettlementComponent, Paths, PublicDocuments}

  @read_ms 30_000

  def show(%{assigns: %{current_human_account: nil}} = conn, _params),
    do:
      ApiError.send(
        conn,
        :unauthorized,
        "authentication_required",
        "Nobody is signed in on this site in this browser."
      )

  def show(%{assigns: %{current_human_account: account}} = conn, _params) do
    actor = %Human{human_account_id: account.id}

    reads = [
      fn -> Autolaunch.list_my_bid_positions(actor: actor) end,
      fn -> RobinhoodPositions.read(actor) end,
      fn -> TokenHoldings.read(actor) end
    ]

    case reads |> Enum.map(&Task.async/1) |> Task.await_many(@read_ms) do
      [{:ok, base}, {:ok, robinhood}, {:ok, holdings}] ->
        books = books(base)

        json(conn, %{
          data: %{
            bids: Enum.map(base, &base_bid(&1, books)) ++ Enum.map(robinhood, &robinhood_bid/1),
            tokens: Enum.map(holdings, &token/1)
          }
        })

      _unavailable ->
        ApiError.send(
          conn,
          :service_unavailable,
          "chain_unavailable",
          "Your bids and tokens could not be read just now."
        )
    end
  end

  # The price books of the auctions still taking bids that the Base bids are
  # in; a book that cannot be read leaves its bids' standing unread.
  defp books(positions) do
    auctions =
      for %{status: "active", auction: %{state: :active} = auction} <- positions,
          uniq: true,
          do: auction

    for auction <- auctions,
        {:ok, book} <- [AuctionBook.base(auction)],
        into: %{},
        do: {auction.id, book}
  end

  defp base_bid(position, books) do
    auction = position.auction
    {standing, can} = base_standing(position, Map.get(books, auction.id))

    %{
      bid: position.bid_id,
      chain: "base",
      name: auction.title,
      symbol: auction.token_symbol,
      currency: auction.quote_token_symbol,
      amount: position.amount,
      max_price: position.max_price,
      standing: standing,
      can: can,
      page: PublicDocuments.url(Paths.auction(auction))
    }
  end

  defp base_standing(%{status: "active", auction: %{state: :active}}, nil),
    do: {"bidding_open", nil}

  defp base_standing(%{status: "active", auction: %{state: :active} = auction} = position, book),
    do: live_standing(AuctionBook.bid_standing(position, auction, book))

  defp base_standing(%{status: "active"}, _book), do: {"bidding_ended", nil}

  defp base_standing(%{status: "returnable"} = position, _book) do
    if BidSettlementComponent.spent?(position),
      do: {"claim_ready", "claim"},
      else: {"withdraw_ready", "withdraw"}
  end

  defp base_standing(%{status: "claimable"}, _book), do: {"claim_ready", "claim"}

  defp base_standing(%{status: "returned", tokens_filled: filled}, _book)
       when is_binary(filled) and filled not in ["", "0"],
       do: {"claim_later", nil}

  defp base_standing(_settled, _book), do: {"done", nil}

  defp robinhood_bid(position) do
    {standing, can} = robinhood_standing(position.standing)

    %{
      bid: String.downcase("#{position.auction}:#{position.bid_id}"),
      chain: "robinhood",
      name: position.name,
      symbol: position.symbol,
      currency: position.stock_symbol,
      amount: position.committed,
      max_price: position.max_price,
      standing: standing,
      can: can,
      page: position.listing && PublicDocuments.url(Paths.auction(position.listing))
    }
  end

  defp robinhood_standing(standing) when standing in [:in, :sharing, :outbid],
    do: live_standing(standing)

  defp robinhood_standing(:ended), do: {"bidding_ended", nil}

  defp robinhood_standing(standing) when standing in [:refundable, :graduated],
    do: {"withdraw_ready", "withdraw"}

  defp robinhood_standing(:filled), do: {"claim_later", nil}
  defp robinhood_standing(:claimable), do: {"claim_ready", "claim"}
  defp robinhood_standing(_settled), do: {"done", nil}

  # A bid while bidding is open, against the auction's price. One that is not
  # buying may take its unspent money back early; its card says when.
  defp live_standing(:in), do: {"buying", nil}
  defp live_standing(:sharing), do: {"sharing_price", "early_return"}
  defp live_standing(:outbid), do: {"outbid", "early_return"}

  defp token(holding) do
    %{
      name: holding.name,
      symbol: holding.symbol,
      chain: Atom.to_string(holding.chain),
      held: holding.held,
      staked: holding.staked,
      claimable: holding.claimable,
      page: holding.token && PublicDocuments.url(Paths.token(holding.token.auction))
    }
  end
end
