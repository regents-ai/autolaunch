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
