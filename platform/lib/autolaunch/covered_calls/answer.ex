defmodule Autolaunch.CoveredCalls.Answer do
  @moduledoc """
  The covered-call answers every agent surface gives, built once by the
  operations they run (`Autolaunch.CoveredCalls.Market`'s `:book_answer`,
  `:positions_answer` and `:prepare_answer`): the HTTP routes send them as their
  `data`, and the hosted MCP tools as their result. The figures come unchanged
  from the readings: stock amounts in raw token units, prices and USDC in
  micro-USDC (6 decimals), times in Unix seconds.

  A step the chain's own state makes certain to fail is not a refusal: it is
  answered with `blocked` naming the reason, in code and words, beside the steps
  themselves. A refusal is an `Autolaunch.CoveredCalls.Refused` naming its reason.
  """

  alias Autolaunch.CoveredCalls
  alias Autolaunch.CoveredCalls.{Refused, Terms}

  @blocked %{
    corporate_action:
      "A change to the stock's share count is scheduled before this listing's exercise window closes, so the contract takes no new listings or purchases until it has happened.",
    not_enough_stock: "This wallet holds less of the stock than the amount to list.",
    approve_first:
      "Approve the amount first; the next step can be sent once the approval is on the chain.",
    fills_closed: "This listing has reached its expiry, so it can no longer be bought.",
    sold_out: "Less is left on this listing than the amount asked for.",
    not_enough_usdc: "This wallet holds less USDC than this step pays.",
    outside_exercise_window:
      "Calls can be exercised only in the 24 hours after their Friday expiry.",
    more_than_held: "This wallet holds fewer calls on this listing than the amount asked for.",
    not_seller: "Only the wallet that made this listing can do this.",
    nothing_to_cancel: "Nothing on this listing is left unsold to cancel.",
    nothing_to_claim: "This wallet has no stock to claim on this listing right now.",
    nothing_to_collect: "No strike payment is waiting to be collected on this listing."
  }

  @doc "A market's book as every agent surface answers it."
  def book({:ok, book}) do
    {:ok,
     %{
       symbol: book.market.symbol,
       contract: book.market.contract,
       stock: book.market.stock,
       block: book.block,
       now: book.now,
       read_at: book.read_at,
       unit: book.unit,
       multiplier: book.multiplier,
       multiplier_change_at: book.effective_at,
       reference_price: book.price,
       listings: Enum.map(book.listings, &listing(&1, book.now))
     }}
  end

  def book({:error, error}), do: refused(error)

  @doc "A wallet's listings and holdings on a market as every agent surface answers them."
  def positions({:ok, positions}) do
    {:ok,
     %{
       symbol: positions.book.market.symbol,
       wallet: positions.wallet,
       now: positions.now,
       read_at: positions.read_at,
       unit: positions.book.unit,
       sold: Enum.map(positions.sold, &listing(&1, positions.now)),
       holdings: positions.holdings
     }}
  end

  def positions({:error, error}), do: refused(error)

  @doc "One action's wallet steps as every agent surface answers them."
  def prepare({:ok, prepared}) do
    {:ok,
     %{
       kind: prepared.kind,
       signer: prepared.signer,
       chain: prepared.chain,
       steps: prepared.steps,
       approved: prepared.approved,
       blocked: blocked(prepared.blocked),
       facts: prepared.facts
     }}
  end

  def prepare({:error, error}), do: refused(error)

  # Input the operation itself refuses (a kind it does not know, an amount below
  # one) is the caller's to fix; a refusal the operation names keeps its reason.
  defp refused(%Ash.Error.Invalid{}),
    do: {:error, Refused.exception(reason: :invalid_request)}

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
end
