defmodule Autolaunch.Auction.Calculations.Fdv do
  @moduledoc """
  The current clearing price times the token's total supply, in quote-token
  units, or nil until the market feed has read both.
  """
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:current_clearing_price, :token_supply]

  @impl true
  def calculate(auctions, _opts, _context), do: Enum.map(auctions, &fdv/1)

  defp fdv(%{current_clearing_price: price, token_supply: %Decimal{} = supply})
       when is_binary(price),
       do: price |> Decimal.new(max_digits: :infinity) |> Decimal.mult(supply)

  defp fdv(_auction), do: nil
end
