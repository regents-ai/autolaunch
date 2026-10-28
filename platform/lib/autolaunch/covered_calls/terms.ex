defmodule Autolaunch.CoveredCalls.Terms do
  @moduledoc """
  The arithmetic of a covered call, exactly as `CoveredCallsV1` does it: weekly
  expiries, the premium and strike a fill or an exercise pays, the 1% fee, a
  listing's state at a moment, and the suggested premium a page offers as a
  guide.

  Stock amounts are raw token units; prices are USDC (6 decimals) per whole
  token; every USDC amount rounds up, as the contract rounds it.
  """

  @week 7 * 86_400
  # Unix time began on a Thursday, so Friday 21:00 UTC is 1 day 21 hours into
  # an epoch-aligned week: the contract's `WEEKLY_EXPIRY_OFFSET`.
  @expiry_offset 86_400 + 21 * 3_600
  @window 86_400
  @fee_bps 100
  @bps 10_000
  @usdc_unit 1_000_000
  @year 365 * 86_400

  def exercise_window, do: @window
  def fee_bps, do: @fee_bps

  @doc "Whether `expiry` is a Friday at 21:00 UTC, the only expiry the contract takes."
  def weekly?(expiry) when is_integer(expiry), do: rem(expiry, @week) == @expiry_offset
  def weekly?(_expiry), do: false

  @doc "The next `count` weekly expiries after `now`."
  def expiries(now, count \\ 4) when is_integer(now) and count > 0 do
    first = now - rem(now, @week) + @expiry_offset
    first = if first <= now, do: first + @week, else: first
    for n <- 0..(count - 1), do: first + n * @week
  end

  @doc "`amount` raw units at `per_token` USDC per whole token of `unit` raw units, rounded up."
  def usdc_for(amount, per_token, unit), do: ceil_div(amount * per_token, unit)

  @doc "The 1% of `premium` that goes to REGENT staking, rounded up, as the contract takes it."
  def fee(premium), do: ceil_div(premium * @fee_bps, @bps)

  @doc """
  Where a listing stands at `now`: `:open` while it can be bought, `:sold` when
  it is open but nothing is left, `:exercise` during the 24 hours after expiry,
  and `:closed` after them.
  """
  def stage(%{expiry: expiry} = listing, now) do
    cond do
      now < expiry and listing.amount > listing.filled -> :open
      now < expiry -> :sold
      now < expiry + @window -> :exercise
      true -> :closed
    end
  end

  @doc "Raw units still for sale on a listing."
  def available(listing), do: listing.amount - listing.filled

  @doc """
  The unexercised stock a seller gets back once the window has closed, which
  the contract books on the seller's next claim. A cancelled remainder is
  owed too; what a page shows as claimable comes from the contract's own
  `claimable` read.
  """
  def returning(listing, now) do
    if not listing.stock_returned and now >= listing.expiry + @window,
      do: listing.amount - listing.exercised,
      else: 0
  end

  @doc "Strike USDC paid on a listing and not yet collected by its seller."
  def strike_due(listing), do: listing.strike_paid - listing.strike_collected

  @doc """
  A suggested premium per whole token for a call struck at `strike` expiring
  at `expiry`, from the reference price `spot` (both USDC per token, 6
  decimals), with `volatility` a yearly fraction: the Black-Scholes price with
  no interest. A guide for the seller only; the contract enforces nothing from
  it. Never below one micro-USDC.
  """
  def suggested_premium(spot, strike, expiry, now, volatility)
      when spot > 0 and strike > 0 and expiry > now and volatility > 0 do
    s = spot / @usdc_unit
    k = strike / @usdc_unit
    t = (expiry - now) / @year
    vt = volatility * :math.sqrt(t)
    d1 = (:math.log(s / k) + vt * vt / 2) / vt
    d2 = d1 - vt
    price = s * normal_cdf(d1) - k * normal_cdf(d2)
    max(round(price * @usdc_unit), 1)
  end

  @doc """
  The seller's result per whole token at expiry if the stock is at `price`,
  against `basis` (what they count the stock as worth today), with the premium
  kept: below the strike the stock stays theirs; above it, the strike is what
  they receive. All USDC per token, 6 decimals.
  """
  def payoff(price, strike, premium, basis), do: min(price, strike) + premium - basis

  defp normal_cdf(x), do: 0.5 * (1 + :math.erf(x / :math.sqrt(2)))

  defp ceil_div(numerator, denominator), do: div(numerator + denominator - 1, denominator)
end
