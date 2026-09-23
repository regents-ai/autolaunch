defmodule AutolaunchWeb.UsdValue do
  @moduledoc """
  An amount's value in US dollars at the current market price of its currency,
  shown beside the amount itself. A dash stands in while no price is known; a
  value is never guessed. On a test network nothing is shown: its coins carry
  no dollar value, whatever the real market pays for the asset they stand in for.
  """
  use Phoenix.Component

  import Phoenix.LiveView, only: [assign_async: 3]

  alias Autolaunch.Lab
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Stocks.{Amounts, MarketData, PriceFeeds}
  alias AutolaunchWeb.TokenDisplay
  alias Phoenix.LiveView.AsyncResult

  @significant_digits 4

  @doc """
  Reads a chain's dollar prices into `key` in the background, as `assign_async/3`
  does. On that chain's test network nothing is read: `key` holds
  `:test_network` from the first render.
  """
  def assign_rate(socket, key, chain, read) do
    if test_network?(chain),
      do: assign(socket, key, AsyncResult.ok(:test_network)),
      else: assign_async(socket, key, read)
  end

  defp test_network?(:base), do: Lab.test_chain?()
  defp test_network?(:robinhood), do: RobinhoodLab.test_chain?()

  @doc "The USD price of one unit of the currency a Base auction is bid in; nil while none is known."
  def rate(%{kind: :agent}), do: MarketData.regent_price()

  def rate(%{kind: :stocks, quote_token_symbol: symbol}),
    do: MarketData.stock_price(:base, symbol)

  @doc "A stock token's USD price from a chain's price list; nil while either is unknown."
  def stock_rate(:test_network, _symbol), do: :test_network

  def stock_rate(prices, symbol) when is_map(prices) and is_binary(symbol),
    do: prices[PriceFeeds.ticker(symbol)]

  def stock_rate(_prices, _symbol), do: nil

  attr :amount, :any, required: true, doc: "a plain decimal string or a Decimal"

  attr :rate, :any,
    required: true,
    doc: "the USD price of one unit, nil while none is known, or :test_network"

  attr :per, :string, default: nil, doc: "what the amount is per, such as \"per token\""
  attr :class, :string, default: nil

  @doc """
  The amount's dollar value, such as `≈ $1,234.50`; nothing for an amount that
  is not a number. A value under a ten-thousandth of a dollar counts its zeros,
  as in `≈ $0.0₄1245`, with the plain figure kept for assistive technology.
  """
  def usd(assigns) do
    text = text(decimal(assigns.amount), assigns.rate, assigns.per)
    assigns = assign(assigns, text: text, shown: text && TokenDisplay.zeros(text))

    ~H"""
    <span :if={@text && @shown == @text} class={["usd-value", @class]}>{@text}</span>
    <span :if={@text && @shown != @text} class={["usd-value", @class]}>
      <span aria-hidden="true">{@shown}</span><span class="visually-hidden">{@text}</span>
    </span>
    """
  end

  defp text(nil, _rate, _per), do: nil
  defp text(_amount, :test_network, _per), do: nil
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
