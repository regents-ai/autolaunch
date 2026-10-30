defmodule AutolaunchWeb.CoveredCallsAnswer do
  @moduledoc """
  The covered-call answers every HTTP route gives (`AutolaunchWeb.CoveredCallsController`,
  `AutolaunchWeb.CoveredCallsAgentController`), so the public, signed-in and
  signed-agent doors share one shape and one set of refusals. The figures come
  unchanged from `Autolaunch.CoveredCalls`: stock amounts in raw token units,
  prices and USDC in micro-USDC (6 decimals), times in Unix seconds.

  A step the chain's own state makes certain to fail is not a refusal: it is
  answered 200 with `blocked` naming the reason, beside the steps themselves.
  """

  import Phoenix.Controller, only: [json: 2]

  alias Autolaunch.CoveredCalls
  alias Autolaunch.CoveredCalls.Terms
  alias AutolaunchWeb.ApiError

  @integer_fields ~w(listing_id amount strike_per_token premium_per_token expiry)

  @blocked %{
    corporate_action:
      "A change to the stock's share count is scheduled before this listing's exercise window closes, so the contract takes no new listings or purchases until it has happened.",
    not_enough_stock: "This wallet holds less of the stock than the amount to list.",
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
    nothing_to_cancel: "Nothing on this listing is left unsold to cancel.",
    nothing_to_claim: "This wallet has no stock to claim on this listing right now.",
    nothing_to_collect: "No strike payment is waiting to be collected on this listing."
  }

  @chain_unavailable {:service_unavailable,
                      "Covered calls could not be read from the chain just now."}

  @refusals %{
    unknown_market: {:not_found, "There is no covered-call market for that stock."},
    unknown_listing: {:not_found, "There is no listing with that number on this market."},
    invalid_amount: {:unprocessable_entity, "Send each amount as a whole number above zero."},
    not_a_weekly_expiry:
      {:unprocessable_entity,
       "The expiry must be a Friday at 21:00 UTC, given as Unix time in seconds."},
    expiry_passed: {:unprocessable_entity, "That expiry has already passed."},
    invalid_request:
      {:unprocessable_entity,
       "Send only the documented fields: kind as text, a signer address as text, and every amount, listing and expiry as a whole number."},
    wrong_signer: {:forbidden, "That wallet is not one of this account's own wallets."},
    wallet_required: {:conflict, "This account has no wallet to act with."},
    authentication_required: {:unauthorized, "Nobody is signed in on this site in this browser."},
    price_unavailable:
      {:service_unavailable,
       "The stock's reference price is not available right now, so no premium is suggested."},
    chain_unavailable: @chain_unavailable,
    # The node answered something that is not Base or not a block: to an agent,
    # the chain could not be read just now.
    invalid_chain_response: @chain_unavailable,
    invalid_block_header: @chain_unavailable,
    wrong_chain: @chain_unavailable
  }

  @doc "Answers with `result`'s figures shaped by `shape`, or with the refusal it carries."
  def send(conn, {:ok, result}, shape), do: json(conn, %{data: present(shape, result)})
  def send(conn, {:error, error}, _shape), do: refuse(conn, reason(error))

  @doc "Answers with the refusal named `reason`."
  def refuse(conn, reason) do
    {status, message} = Map.fetch!(@refusals, reason)
    ApiError.send(conn, status, Atom.to_string(reason), message)
  end

  @doc """
  A step request's body as the prepare action's inputs, or `:error` when it
  names a field the action does not take or gives one the wrong type.
  """
  def prepare_input(%{"kind" => kind} = body) when is_binary(kind) do
    if Enum.all?(body, &prepare_field?/1),
      do:
        {:ok,
         body
         |> Map.delete("kind")
         |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)},
      else: :error
  end

  def prepare_input(_body), do: :error

  defp prepare_field?({"kind", value}), do: is_binary(value)
  defp prepare_field?({"signer", value}), do: is_binary(value)
  defp prepare_field?({key, value}) when key in @integer_fields, do: is_integer(value)
  defp prepare_field?(_field), do: false

  # Inputs the action itself refuses (a kind it does not know, an amount
  # below one) are the caller's to fix; a refusal the operation names keeps
  # its own reason.
  defp reason(%Ash.Error.Invalid{}), do: :invalid_request
  defp reason(error), do: CoveredCalls.reason(error)

  defp present(:book, book) do
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
    }
  end

  defp present(:quote, quote), do: quote

  defp present(:positions, positions) do
    %{
      symbol: positions.book.market.symbol,
      wallet: positions.wallet,
      now: positions.now,
      read_at: positions.read_at,
      unit: positions.book.unit,
      sold: Enum.map(positions.sold, &listing(&1, positions.now)),
      holdings: positions.holdings
    }
  end

  defp present(:prepare, prepared) do
    %{
      kind: prepared.kind,
      signer: prepared.signer,
      chain: prepared.chain,
      steps: prepared.steps,
      approved: prepared.approved,
      blocked: blocked(prepared.blocked),
      facts: prepared.facts
    }
  end

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
