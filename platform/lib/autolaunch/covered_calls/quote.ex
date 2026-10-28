defmodule Autolaunch.CoveredCalls.Quote do
  @moduledoc """
  The suggested premium per whole token a page shows a seller as a guide, from
  the stock's Chainlink reference price in the shared book. It is never
  enforced: the seller sets the minimum premium, and a buyer pays exactly what
  the listing asks.

  The suggestion is the Black-Scholes price of the call with a fixed yearly
  volatility of 30% and no interest (`Autolaunch.CoveredCalls.Terms`). It is not
  offered while the reference price is older than four days, which covers a
  weekend and a holiday; feeds stop updating outside market hours and during a
  corporate action.
  """

  alias Autolaunch.CoveredCalls.{Book, Terms}

  @volatility 0.30
  @stale_s 4 * 86_400
  # Chainlink stock feeds answer with 8 decimals; USDC has 6.
  @feed_to_usdc 100

  @spec suggest(String.t(), pos_integer(), integer()) :: {:ok, map()} | {:error, atom()}
  def suggest(symbol, strike_per_token, expiry) do
    with {:ok, book} <- Book.read(symbol),
         true <- Terms.weekly?(expiry) || {:error, :not_a_weekly_expiry},
         true <- expiry > book.now || {:error, :expiry_passed},
         {:ok, spot} <- spot(book) do
      {:ok,
       %{
         symbol: symbol,
         spot_per_token: spot,
         strike_per_token: strike_per_token,
         expiry: expiry,
         volatility: @volatility,
         suggested_premium_per_token:
           Terms.suggested_premium(spot, strike_per_token, expiry, book.now, @volatility),
         price_updated_at: book.price.updated_at
       }}
    end
  end

  defp spot(%{price: %{answer: answer, updated_at: updated_at}, now: now})
       when now - updated_at <= @stale_s,
       do: {:ok, div(answer, @feed_to_usdc)}

  defp spot(_book), do: {:error, :price_unavailable}
end
