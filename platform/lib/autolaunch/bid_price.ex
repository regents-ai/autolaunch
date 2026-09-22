defmodule Autolaunch.BidPrice do
  @moduledoc "Exact zero-based auction tick arithmetic; never raises the user's maximum."
  @uint256_max Integer.pow(2, 256) - 1

  @doc """
  The decimal a Q96 price names in whole currency per whole NEW token.

  Q96 is currency base units per NEW base unit; NEW always has eighteen
  decimals, the currency has `currency_decimals`.
  """
  def decimal(q96, currency_decimals),
    do:
      Decimal.new(1, q96 * Integer.pow(5, 96) * Integer.pow(10, 18), -(96 + currency_decimals))
      |> Decimal.normalize()
      |> Decimal.to_string(:normal)

  defguardp is_positive_uint256(value) when is_integer(value) and value in 1..@uint256_max
  defguardp is_uint256(value) when is_integer(value) and value in 0..@uint256_max

  def align(maximum, %{
        tick_spacing_q96: spacing,
        floor_price_q96: floor,
        clearing_price_q96: clearing,
        max_bid_price_q96: cap
      })
      when is_positive_uint256(maximum) and is_positive_uint256(spacing) and
             is_positive_uint256(floor) and is_uint256(clearing) and is_positive_uint256(cap) do
    price = div(min(maximum, cap), spacing) * spacing
    admissible(price, spacing, floor, clearing)
  end

  def align(_, _), do: {:error, :bid_preparation_unavailable}

  # A tick is admissible when the floor sits on the grid and the price is on or
  # above the floor, above the clearing price and positive.
  defp admissible(price, spacing, floor, clearing) do
    if rem(floor, spacing) == 0 and price >= floor and price > clearing and price > 0,
      do: {:ok, price},
      else: {:error, :price_below_admissible_tick}
  end
end
