defmodule Autolaunch.CoveredCalls.Quote do
  @moduledoc """
  The strikes a seller chooses from and the premium suggested at each, from
  the stock's Chainlink reference price in the shared book
  (`platform/docs/covered-calls-strike-design.md`).

  Three strikes, the same for every weekly window: the price plus 1%, 3% and
  5%, each rounded up to the strike step and at least one step above the one
  before it (the first, above the price). The step is the largest round amount not above 1% of the price,
  and never under a cent. The contract takes any strike; the set is the
  site's.

  The suggested premium is the Black-Scholes price of the call with an assumed
  yearly volatility of 30% (a fixed figure, not a market quote) and no
  interest (`Autolaunch.CoveredCalls.Terms`), counted to the close of the
  exercise window, the last moment the buyer may exercise, rounded to the cent
  and never under $0.10. It is never enforced: the seller sets the minimum
  premium, and a buyer pays exactly what the listing asks. While the price is
  older than four days, which covers a weekend and a holiday (feeds stop
  updating outside market hours and during a corporate action), the strikes
  still come from it and no premium is suggested.
  """

  alias Autolaunch.CoveredCalls.{Book, Terms}

  @volatility_bps 3_000
  @targets_bps [100, 300, 500]
  # Strike steps in micro-USDC: $0.01 up to $25.
  @steps [
    10_000,
    50_000,
    100_000,
    250_000,
    500_000,
    1_000_000,
    2_500_000,
    5_000_000,
    10_000_000,
    25_000_000
  ]
  @premium_floor 100_000
  @stale_s 4 * 86_400
  # Chainlink stock feeds answer with 8 decimals; USDC has 6.
  @feed_to_usdc 100

  @doc "The strike set of `symbol`'s market, from its shared book."
  @spec read(String.t()) :: {:ok, map()} | {:error, atom()}
  def read(symbol) do
    with {:ok, book} <- Book.read(symbol), do: set(book)
  end

  @doc """
  The strike set for each of the next four weekly windows in a book reading,
  or `:price_unavailable` when the feed did not answer. Prices are micro-USDC
  per whole token; `above_bps` is how far a strike sits above the price.
  """
  @spec set(map()) :: {:ok, map()} | {:error, :price_unavailable}
  def set(%{price: %{answer: answer, updated_at: updated_at}, now: now} = book)
      when answer >= @feed_to_usdc do
    price = div(answer, @feed_to_usdc)
    fresh = now - updated_at <= @stale_s
    strikes = strikes(price)

    {:ok,
     %{
       symbol: book.market.symbol,
       price_per_token: price,
       price_updated_at: updated_at,
       price_fresh: fresh,
       volatility_bps: @volatility_bps,
       strike_step: step(price),
       windows:
         for expiry <- Terms.expiries(now) do
           %{
             expiry: expiry,
             window_closes_at: expiry + Terms.exercise_window(),
             strikes: Enum.map(strikes, &choice(&1, price, fresh, expiry, now))
           }
         end
     }}
  end

  def set(_book), do: {:error, :price_unavailable}

  @doc """
  The reference price per whole token in a book reading (USDC, 6 decimals), or
  `:price_unavailable` when the feed did not answer or is older than four days.
  """
  @spec spot(map()) :: {:ok, pos_integer()} | {:error, :price_unavailable}
  def spot(%{price: %{answer: answer, updated_at: updated_at}, now: now})
      when now - updated_at <= @stale_s,
      do: {:ok, div(answer, @feed_to_usdc)}

  def spot(_book), do: {:error, :price_unavailable}

  @doc "The yearly volatility the suggestion assumes, in basis points."
  def volatility_bps, do: @volatility_bps

  @doc "The three strikes for `price`, lowest first."
  def strikes(price) do
    step = step(price)

    @targets_bps
    |> Enum.map_reduce(round_up(price, step), fn bps, previous ->
      strike = max(round_up(ceil_div(price * (10_000 + bps), 10_000), step), previous + step)
      {strike, strike}
    end)
    |> elem(0)
  end

  @doc "The strike step for `price`: the largest step not above 1% of it, never under a cent."
  def step(price) do
    @steps |> Enum.filter(&(&1 * 100 <= price)) |> Enum.max(fn -> hd(@steps) end)
  end

  defp choice(strike, price, fresh, expiry, now) do
    premium = if fresh, do: premium(price, strike, expiry, now)

    %{
      strike_per_token: strike,
      above_bps: div((strike - price) * 20_000 + price, 2 * price),
      suggested_premium_per_token: premium,
      fee_per_token: premium && Terms.fee(premium)
    }
  end

  defp premium(price, strike, expiry, now) do
    price
    |> Terms.suggested_premium(
      strike,
      expiry + Terms.exercise_window(),
      now,
      @volatility_bps / 10_000
    )
    |> round_cents()
    |> max(@premium_floor)
  end

  defp round_up(value, step), do: ceil_div(value, step) * step
  defp round_cents(micro), do: div(micro + 5_000, 10_000) * 10_000
  defp ceil_div(numerator, denominator), do: div(numerator + denominator - 1, denominator)
end
