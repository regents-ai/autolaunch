defmodule AutolaunchWeb.UsdValue do
  @moduledoc """
  An amount's value in US dollars at the current market price of its currency,
  shown beside the amount itself. A dash stands in while no price is known; a
  value is never guessed.
  """
  use Phoenix.Component

  alias Autolaunch.Stocks.{Amounts, MarketData, PriceFeeds}

  @significant_digits 4

  @doc "The USD price of one unit of the currency a Base auction is bid in; nil while none is known."
  def rate(%{kind: :agent}), do: MarketData.regent_price()

  def rate(%{kind: :stocks, quote_token_symbol: symbol}),
    do: MarketData.stock_price(:base, symbol)

  @doc "A stock token's USD price from a chain's price list; nil while either is unknown."
  def stock_rate(prices, symbol) when is_map(prices) and is_binary(symbol),
    do: prices[PriceFeeds.ticker(symbol)]

  def stock_rate(_prices, _symbol), do: nil

  attr :amount, :any, required: true, doc: "a plain decimal string or a Decimal"
  attr :rate, :any, required: true, doc: "the USD price of one unit, or nil while none is known"
  attr :per, :string, default: nil, doc: "what the amount is per, such as \"per token\""

  @doc "The amount's dollar value, such as `≈ $1,234.50`; nothing for an amount that is not a number."
  def usd(assigns) do
    assigns = assign(assigns, :text, text(decimal(assigns.amount), assigns.rate, assigns.per))

    ~H"""
    <span :if={@text} class="usd-value">{@text}</span>
    """
  end

  defp text(nil, _rate, _per), do: nil
  defp text(_amount, nil, _per), do: "$—"
  defp text(amount, rate, nil), do: "≈ " <> dollars(Decimal.mult(amount, rate))
  defp text(amount, rate, per), do: text(amount, rate, nil) <> " " <> per

  defp decimal(%Decimal{} = amount), do: amount

  # Exact auction prices run past a hundred decimal places; anything far longer
  # is not an amount anyone typed or the chain returned.
  defp decimal(amount) when is_binary(amount) and byte_size(amount) <= 256 do
    case Decimal.parse(String.trim(amount), max_digits: :infinity) do
      {decimal, ""} -> if Decimal.inf?(decimal) or Decimal.nan?(decimal), do: nil, else: decimal
      _unparsed -> nil
    end
  end

  defp decimal(_amount), do: nil

  # Whole dollars and cents from a dollar up; below that, enough significant
  # digits to tell a tiny per-token price from nothing.
  defp dollars(value) do
    cond do
      Decimal.eq?(value, 0) ->
        "$0"

      Decimal.gte?(Decimal.abs(value), 1) ->
        "$" <> (value |> Decimal.round(2) |> Decimal.to_string(:normal) |> Amounts.grouped())

      true ->
        "$" <> (value |> significant() |> Decimal.to_string(:normal))
    end
  end

  defp significant(%Decimal{coef: coef, exp: exp} = value) do
    digits = coef |> Integer.digits() |> length()
    value |> Decimal.round(@significant_digits - digits - exp) |> Decimal.normalize()
  end
end
