defmodule Autolaunch.CoveredCalls.Terms do
  @moduledoc """
  The arithmetic of a covered call, exactly as `CoveredCallsV2` does it: weekly
  expiries, the premium and strike a fill or an exercise pays, the 1% fee, what
  a bid escrows and what a sale into one pays, a listing's or a bid's state at a
  moment, and the suggested premium a page offers as a guide.

  Stock amounts are raw token units; prices are USDC (6 decimals) per whole
  token; every USDC amount rounds up, as the contract rounds it.
  """

  @day 86_400
  @week 7 * @day
  # Unix time began on a Thursday, so Friday 21:00 UTC is 1 day 21 hours into
  # an epoch-aligned week: the contract's `WEEKLY_EXPIRY_OFFSET`.
  @expiry_offset @day + 21 * 3_600
  @window @day
  @fee_bps 100
  @bps 10_000
  @usdc_unit 1_000_000
  @year 365 * @day

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

  @doc """
  A listing's term as a page names it: the whole days from `now` to `expiry`,
  to the nearest day and never under one.
  """
  def term_days(expiry, now) when is_integer(expiry) and is_integer(now) and expiry > now,
    do: max(div(expiry - now + div(@day, 2), @day), 1)

  @doc "`amount` raw units at `per_token` USDC per whole token of `unit` raw units, rounded up."
  def usdc_for(amount, per_token, unit), do: ceil_div(amount * per_token, unit)

  @doc "The 1% of `premium` that goes to REGENT staking, rounded up, as the contract takes it."
  def fee(premium), do: ceil_div(premium * @fee_bps, @bps)

  @doc """
  Where a listing stands at `now`: `:stopped` once its seller stopped it before
  any was bought (`cancel` leaves its amount at the zero filled), `:open` while
  it can be bought, `:sold` when it is open but nothing is left, `:exercise`
  during the 24 hours after expiry, and `:closed` after them.

  A listing stopped after some was bought keeps the bought part for its buyers
  and reads as sold: the contract keeps no other record of the stop.
  """
  def stage(%{expiry: expiry} = listing, now) do
    cond do
      listing.amount == 0 -> :stopped
      now < expiry and listing.amount > listing.filled -> :open
      now < expiry -> :sold
      now < expiry + @window -> :exercise
      true -> :closed
    end
  end

  @doc """
  Whether a multiplier change scheduled at `effective_at` falls after `now`
  and before the exercise window of `expiry` closes, so the contract refuses
  to list or fill.
  """
  def corporate_action?(effective_at, expiry, now),
    do: effective_at > now and effective_at < expiry + @window

  @doc """
  Seconds from `now` until the earliest of `times` still to come, at most a
  week, or nil when none is: when a page reads again because a listing's
  expiry or window closes, or a scheduled multiplier change takes effect.
  """
  def next_wait(times, now) do
    case for(at <- times, at > now, do: at - now) do
      [] -> nil
      waits -> min(Enum.min(waits), @week)
    end
  end

  @doc "Raw units still for sale on a listing, or still asked for on a bid."
  def available(listing_or_bid), do: listing_or_bid.amount - listing_or_bid.filled

  @doc """
  Where a bid stands at `now`: `:cancelled` once its bidder stopped it before
  any was sold into it (`cancelBid` leaves its amount at the zero filled),
  `:open` while stock can be sold into it, `:sold` when nothing is left to sell
  into it, and `:expired` when its expiry passed with part of it unsold.

  A bid stopped after some was sold into it keeps the sold part as its bidder's
  calls and reads as sold: the contract keeps no other record of the stop. A
  refund after the expiry closes a bid the same way, so an expired bid reads as
  cancelled or sold once its bidder has taken the refund.
  """
  def bid_stage(%{expiry: expiry} = bid, now) do
    cond do
      bid.amount == 0 -> :cancelled
      bid.amount == bid.filled -> :sold
      now < expiry -> :open
      true -> :expired
    end
  end

  @doc """
  The smallest sale into a bid of `amount` raw units the site asks for: one
  whole token of `unit` raw units, or the whole bid when it asks for less. The
  contract still takes a sale of the bid's whole remainder below it.
  """
  def min_sale(amount, unit), do: min(amount, unit)

  @doc """
  The USDC `raiseBid` takes to add `amount` raw units to `bid`, as the
  contract's `raiseCostFor`: the premium for the raised amount less the
  premium already escrowed, each rounded up once, so raising in small steps
  never escrows more than bidding the total at once.
  """
  def raise_cost(bid, amount, unit),
    do:
      usdc_for(bid.amount + amount, bid.premium_per_token, unit) -
        usdc_for(bid.amount, bid.premium_per_token, unit)

  @doc """
  What selling `amount` raw units into `bid` pays now, as the contract's
  `salePremiumFor`: the sales into one bid are together paid the premium for
  all that has been sold into it, rounded up once, and carry the 1% fee of that
  total, rounded up once, so each sale takes the next slice of both. `receive`
  is what lands in the seller's wallet, the premium less the fee.
  """
  def sale(bid, amount, unit) do
    paid_before = usdc_for(bid.filled, bid.premium_per_token, unit)
    paid_after = usdc_for(bid.filled + amount, bid.premium_per_token, unit)
    premium = paid_after - paid_before
    fee = fee(paid_after) - fee(paid_before)
    %{premium: premium, fee: fee, receive: premium - fee}
  end

  @doc """
  The escrow still standing behind `bid`'s unsold amount: what `cancelBid`
  releases to its bidder's refund.
  """
  def escrow_left(bid, unit),
    do:
      usdc_for(bid.amount, bid.premium_per_token, unit) -
        usdc_for(bid.filled, bid.premium_per_token, unit)

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

  defp normal_cdf(x), do: 0.5 * (1 + :math.erf(x / :math.sqrt(2)))

  defp ceil_div(numerator, denominator), do: div(numerator + denominator - 1, denominator)
end
