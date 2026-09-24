defmodule Autolaunch.Token.Calculations.MarketCap do
  @moduledoc """
  The token's price times its total supply, in the pool currency's units, or
  nil until both are known.
  """
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:price_quote, auction: [:token_supply]]

  @impl true
  def calculate(tokens, _opts, _context), do: Enum.map(tokens, &market_cap/1)

  defp market_cap(%{price_quote: price, auction: %{token_supply: %Decimal{} = supply}})
       when is_binary(price),
       do: price |> Decimal.new(max_digits: :infinity) |> Decimal.mult(supply)

  defp market_cap(_token), do: nil
end
