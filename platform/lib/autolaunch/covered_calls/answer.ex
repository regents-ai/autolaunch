defmodule Autolaunch.CoveredCalls.Answer do
  @moduledoc """
  The covered-call answers every agent surface gives, built once by the
  operations they run (`Autolaunch.CoveredCalls.Market`'s `:book_answer`,
  `:positions_answer` and `:prepare_answer`): the HTTP routes send them as their
  `data`, and the hosted MCP tools as their result. The figures come unchanged
  from the readings: stock amounts in raw token units, prices and USDC in
  micro-USDC (6 decimals), times in Unix seconds. A book answers with at most
  fifty open listings and fifty open bids, each best first, beside how many of
  each are open in all (`Autolaunch.CoveredCalls.Book`). Each answer names the stock
  its calls are on (`market`: symbol, issuer, chain and the exact addresses of
  the stock and of its covered-calls contract).

  A step the chain's own state makes certain to fail is not a refusal: it is
  answered with `blocked` naming the reason, in code and words, beside the steps
  themselves. A refusal is an `Autolaunch.CoveredCalls.Refused` naming its reason.
  """

  alias Autolaunch.CoveredCalls
  alias Autolaunch.CoveredCalls.{Deployment, Refused, Terms}

  @blocked %{
    corporate_action:
      "A change to the stock's share count is scheduled before the exercise window closes, so the contract takes no new listings, purchases, bids or sales into bids until it has happened.",
    not_enough_stock: "This wallet holds less of the stock than this step locks.",
    approve_first:
      "Approve the amount first; the next step can be sent once the approval is on the chain.",
    fills_closed: "This listing has reached its expiry, so it can no longer be bought.",
    sold_out: "Less is left on this listing than the amount asked for.",
    not_enough_usdc: "This wallet holds less USDC than this step pays.",
    exercise_not_open:
      "Calls can be exercised only in the 24 hours after their Friday expiry, which hasn't come yet.",
    exercise_closed:
      "The 24 hours after this listing's expiry have passed; its calls have lapsed.",
    more_than_held: "This wallet holds fewer calls on this listing than the amount asked for.",
    not_seller: "Only the wallet that made this listing can do this.",
    nothing_to_cancel: "Nothing is left unsold to cancel.",
    nothing_to_claim: "This wallet has no stock to claim on this listing right now.",
    nothing_to_collect: "No strike payment is waiting to be collected on this listing.",
    not_bidder: "Only the wallet that made this bid can do this.",
    bid_expired: "This bid has reached its expiry, so it can no longer be raised or sold into.",
    more_than_bid: "This bid asks for less than the amount to sell.",
    below_minimum_sale:
      "A sale into this bid must be at least its minimum sale, unless it sells all that is left.",
    nothing_to_refund: "No refund is waiting on this bid right now."
  }

  @doc "A market's book as every agent surface answers it."
  def book({:ok, book}) do
    {:ok,
     %{
       symbol: book.market.symbol,
       market: Deployment.identity(book.market),
       block: book.block,
       now: book.now,
       read_at: book.read_at,
       unit: book.unit,
       multiplier: book.multiplier,
       multiplier_change_at: book.effective_at,
       reference_price: book.price,
       listings: Enum.map(book.listings, &listing(&1, book.now)),
       listings_total: book.listings_total,
       bids: Enum.map(book.bids, &bid(&1, book.now)),
       bids_total: book.bids_total
     }}
  end

  def book({:error, error}), do: refused(error)

  @doc "A wallet's listings and holdings on a market as every agent surface answers them."
  def positions({:ok, positions}) do
    {:ok,
     %{
       symbol: positions.market.symbol,
       market: Deployment.identity(positions.market),
       wallet: positions.wallet,
       now: positions.now,
       read_at: positions.read_at,
       unit: positions.unit,
       sold: Enum.map(positions.sold, &listing(&1, positions.now)),
       holdings: Enum.map(positions.holdings, &holding(&1, positions.now)),
       bids:
         Enum.map(
           positions.bids,
           &(&1 |> bid(positions.now) |> Map.put(:refundable, &1.refundable))
         ),
       balance: positions.balance
     }}
  end

  def positions({:error, error}), do: refused(error)

  @doc "One action's wallet steps as every agent surface answers them."
  def prepare({:ok, prepared}) do
    {:ok,
     %{
       kind: prepared.kind,
       signer: prepared.signer,
       market: prepared.market,
       chain: prepared.chain,
       steps: prepared.steps,
       approved: prepared.approved,
       blocked: blocked(prepared.blocked),
       facts: prepared.facts
     }}
  end

  def prepare({:error, error}), do: refused(error)

  # A refusal the reading names keeps its reason.
  defp refused(error), do: {:error, Refused.exception(reason: CoveredCalls.reason(error))}

  defp blocked(nil), do: nil
  defp blocked(reason), do: %{code: reason, message: Map.fetch!(@blocked, reason)}

  defp listing(listing, now) do
    listing
    |> Map.take([
      :id,
      :seller,
      :expiry,
      :amount,
      :filled,
      :exercised,
      :strike_per_token,
      :premium_per_token,
      :stock_returned
    ])
    |> Map.merge(%{
      stage: Terms.stage(listing, now),
      available: Terms.available(listing),
      exercise_closes_at: listing.expiry + Terms.exercise_window(),
      strike_due: Terms.strike_due(listing)
    })
  end

  # Calls held, with the terms a holder acts on: the strike to pay, and the
  # one day they may be exercised in.
  defp holding(%{listing: listing} = holding, now) do
    holding
    |> Map.take([:listing_id, :held, :claimable])
    |> Map.merge(%{
      strike_per_token: listing.strike_per_token,
      expiry: listing.expiry,
      exercise_closes_at: listing.expiry + Terms.exercise_window(),
      stage: Terms.stage(listing, now)
    })
  end

  defp bid(bid, now) do
    bid
    |> Map.take([
      :id,
      :bidder,
      :expiry,
      :amount,
      :filled,
      :strike_per_token,
      :premium_per_token,
      :min_sale
    ])
    |> Map.merge(%{stage: Terms.bid_stage(bid, now), available: Terms.available(bid)})
  end
end
