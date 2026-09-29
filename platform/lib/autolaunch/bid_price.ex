defmodule Autolaunch.BidPrice do
  @moduledoc "Exact zero-based auction tick arithmetic; never raises the user's maximum."
  @uint256_max Integer.pow(2, 256) - 1

  # uint256 / 2^96 needs at most 49 integer digits, a dot and 96
  # fractional digits. Formatting must not consult Decimal's rounding context.
  def decimal(q96) when is_integer(q96) and q96 in 0..@uint256_max do
    Decimal.new(1, q96 * Integer.pow(5, 96), -96)
    |> Decimal.to_string(:normal)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  def align(maximum, %{
        tick_spacing_q96: spacing,
        floor_price_q96: floor,
        clearing_price_q96: clearing,
        max_bid_price_q96: cap
      })
      when is_integer(maximum) and maximum in 1..@uint256_max and
             is_integer(spacing) and spacing in 1..@uint256_max and
             is_integer(floor) and floor in 1..@uint256_max and
             is_integer(clearing) and clearing in 0..@uint256_max and
             is_integer(cap) and cap in 1..@uint256_max do
    price = div(min(maximum, cap), spacing) * spacing

    if rem(floor, spacing) == 0 and price >= floor and price > clearing and price > 0,
      do: {:ok, price},
      else: {:error, :price_below_admissible_tick}
  end

  def align(_, _), do: {:error, :bid_preparation_unavailable}
end
