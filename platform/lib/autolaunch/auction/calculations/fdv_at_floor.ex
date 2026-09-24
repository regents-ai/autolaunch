defmodule Autolaunch.Auction.Calculations.FdvAtFloor do
  @moduledoc """
  The floor price times the token's total supply, in quote-token units, or nil
  until the market feed has read both.
  """
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:floor_price, :token_supply]

  @impl true
  def calculate(auctions, _opts, _context), do: Enum.map(auctions, &fdv/1)

  defp fdv(%{floor_price: floor, token_supply: %Decimal{} = supply}) when is_binary(floor),
    do: floor |> Decimal.new(max_digits: :infinity) |> Decimal.mult(supply)

  defp fdv(_auction), do: nil
end
