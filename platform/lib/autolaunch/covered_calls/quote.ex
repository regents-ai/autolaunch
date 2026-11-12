defmodule Autolaunch.CoveredCalls.Quote do
  @moduledoc """
  A seller's quote on one stock: everything a page's trade ticket and an
  agent read before listing, from the stock's Chainlink reference price in
  the shared book.

    * the reference price per whole token and when the feed last updated it
    * the next weekly expiries, each with its exercise window, and the chosen
      one's term in whole days (`Terms.term_days/2`)
    * three suggested strikes above the reference price (`@presets`), each
      with how far above it is and its suggested premium
    * for the chosen strike (the middle suggestion when none is asked) and
      premium (the suggestion when none is asked), what a listing of the
      amount asked pays, as `CoveredCallsV1` counts it

  Every USDC figure a listing pays comes from `Autolaunch.CoveredCalls.Terms`,
  the contract's own arithmetic, so the quote, a page's receipt and the
  prepared wallet steps agree to the micro-USDC.

  The suggestion is the Black-Scholes price of the call with an assumed yearly
  volatility of 30% (a fixed figure, not a market quote) and no interest
  (`Autolaunch.CoveredCalls.Terms`), counted to the close of the exercise
  window, the last moment the buyer may exercise, and rounded to the cent, as
  a page shows and takes a price. It is never enforced: the seller sets the
  minimum premium, and a buyer pays exactly what the listing asks. It is not
  offered while the reference price is older than four days, which covers a
  weekend and a holiday; feeds stop updating outside market hours and during a
  corporate action.
  """

  alias Autolaunch.CoveredCalls.{Book, Terms}

  @volatility 0.30
  @stale_s 4 * 86_400
  # Chainlink stock feeds answer with 8 decimals; USDC has 6.
  @feed_to_usdc 100
  @cent 10_000
  # The suggested strikes, in percent above the reference price.
  @presets [2, 5, 10]

  @doc """
  The quote for `request` (`symbol`, `expiry`, and optionally `amount`,
  `strike_per_token` and `premium_per_token`), already bounded by the
  action's arguments. Without an amount the per-token figures still come
  back, and the totals (`receipt` and each preset's `premium`) are nil.
  """
  @spec read(map()) :: {:ok, map()} | {:error, atom()}
  def read(%{symbol: symbol, expiry: expiry} = request) do
    with {:ok, book} <- Book.read(symbol),
         true <- Terms.weekly?(expiry) || {:error, :not_a_weekly_expiry},
         true <- expiry > book.now || {:error, :expiry_passed},
         {:ok, spot} <- spot(book) do
      amount = request[:amount]
      [_near, middle, _far] = presets = presets(spot, expiry, book.now)
      strike = request[:strike_per_token] || middle.strike_per_token
      suggested = premium(spot, strike, expiry, book.now)
      premium = request[:premium_per_token] || suggested

      {:ok,
       %{
         symbol: symbol,
         unit: book.unit,
         spot_per_token: spot,
         price_updated_at: book.price.updated_at,
         volatility: @volatility,
         expiries: Enum.map(Terms.expiries(book.now), &window/1),
         presets: Enum.map(presets, &Map.put(&1, :premium, total(amount, &1, book.unit))),
         expiry: expiry,
         exercise_closes_at: expiry + Terms.exercise_window(),
         term_days: Terms.term_days(expiry, book.now),
         amount: amount,
         strike_per_token: strike,
         suggested_premium_per_token: suggested,
         premium_per_token: premium,
         receipt: receipt(amount, spot, strike, premium, book.unit)
       }}
    end
  end

  @doc """
  The reference price per whole token in a book reading (USDC, 6 decimals), or
  `:price_unavailable` when the feed did not answer, answered less than one
  micro-USDC, or is older than four days.
  """
  @spec spot(map()) :: {:ok, pos_integer()} | {:error, :price_unavailable}
  def spot(%{price: %{answer: answer, updated_at: updated_at}, now: now})
      when now - updated_at <= @stale_s and answer >= @feed_to_usdc,
      do: {:ok, div(answer, @feed_to_usdc)}

  def spot(_book), do: {:error, :price_unavailable}

  @doc """
  The suggested premium per whole token at `strike` for the series that
  expires at `expiry`, from `spot`, counted to the window's close, to the
  nearest cent and never below one.
  """
  def premium(spot, strike, expiry, now) do
    micro =
      Terms.suggested_premium(spot, strike, expiry + Terms.exercise_window(), now, @volatility)

    max(div(micro + div(@cent, 2), @cent) * @cent, @cent)
  end

  @doc "The yearly volatility the suggestion assumes."
  def volatility, do: @volatility

  # The suggested strikes: each about its percent above the reference price,
  # rounded up to the stock's tick, and at least a tick above the one before,
  # so the three are always distinct, ascending and above the reference.
  defp presets(spot, expiry, now) do
    tick = tick(spot)

    {strikes, _highest} =
      Enum.map_reduce(@presets, div(spot, tick) * tick, fn percent, below ->
        strike = max(up_to(div(spot * (100 + percent) + 99, 100), tick), below + tick)
        {strike, strike}
      end)

    for strike <- strikes do
      %{
        strike_per_token: strike,
        above_reference: (strike - spot) / spot,
        suggested_premium_per_token: premium(spot, strike, expiry, now)
      }
    end
  end

  # A strike step a person reads at a glance: the power of ten a hundredth to
  # a thousandth of the price (a dollar from $100 to $999.99, ten cents from
  # $10 to $99.99), never under a cent (10^4 micro-USDC).
  defp tick(spot), do: 10 ** max(length(Integer.digits(spot)) - 3, 4)

  defp up_to(value, step), do: div(value + step - 1, step) * step

  defp window(expiry),
    do: %{
      expiry: expiry,
      exercise_opens_at: expiry,
      exercise_closes_at: expiry + Terms.exercise_window()
    }

  defp total(nil, _preset, _unit), do: nil

  defp total(amount, preset, unit),
    do: Terms.usdc_for(amount, preset.suggested_premium_per_token, unit)

  # What a listing of `amount` at these prices pays, as the contract counts
  # it: the premium if all of it is bought at once, the 1% fee taken from it,
  # what the seller keeps, and the strike if all of it is exercised; beside
  # them the stock's worth at the reference price, and the premium kept as a
  # fraction of that worth for the term to expiry (not a yearly rate).
  defp receipt(nil, _spot, _strike, _premium, _unit), do: nil

  defp receipt(amount, spot, strike, premium, unit) do
    value = Terms.usdc_for(amount, spot, unit)
    gross = Terms.usdc_for(amount, premium, unit)
    fee = Terms.fee(gross)

    %{
      reference_value: value,
      premium: gross,
      fee: fee,
      net_premium: gross - fee,
      strike: Terms.usdc_for(amount, strike, unit),
      net_premium_yield: (gross - fee) / value
    }
  end
end
