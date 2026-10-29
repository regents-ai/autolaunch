defmodule AutolaunchWeb.UsdValue do
  @moduledoc """
  An amount's value in US dollars at the current market price of its currency,
  shown beside the amount itself. A dash stands in while no price is known; a
  value is never guessed. On a test network nothing is shown: its coins carry
  no dollar value, whatever the real market pays for the asset they stand in for.
  """
  use Phoenix.Component

  import Phoenix.LiveView, only: [assign_async: 4]

  alias Autolaunch.Lab
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Stocks.{MarketData, PriceFeeds}
  alias Phoenix.LiveView.AsyncResult

  @doc """
  Reads a chain's dollar prices into `key` in the background, as `assign_async/3`
  does. Each call is for a new record, so the previous record's price comes
  down until the new one lands. On that chain's test network nothing is read:
  `key` holds `:test_network` from the first render.
  """
  def assign_rate(socket, key, chain, read) do
    if test_network?(chain),
      do: assign(socket, key, AsyncResult.ok(:test_network)),
      else: assign_async(socket, key, read, reset: true)
  end

  defp test_network?(:base), do: Lab.test_chain?()
  defp test_network?(:robinhood), do: RobinhoodLab.test_chain?()

  @doc "The USD price of one unit of the currency a Base auction is bid in; nil while none is known."
  def rate(%{kind: :agent}), do: MarketData.regent_price()

  def rate(%{kind: :stocks, quote_token_symbol: symbol}),
    do: MarketData.stock_price(:base, symbol)

  @doc """
  The dollar prices the market figures use, read together: REGENT's price and
  each chain's stock prices. A test network's coins carry no dollar value, so
  its prices stay unknown.
  """
  def rates do
    %{
      regent: if(!Lab.test_chain?(), do: MarketData.regent_price()),
      base: if(!Lab.test_chain?(), do: MarketData.prices(:base)),
      robinhood: if(!RobinhoodLab.test_chain?(), do: MarketData.prices(:robinhood))
    }
  end

  @doc "The USD price of one unit of an auction's currency from `rates/0`; nil while none is known."
  def auction_rate(rates, auction) do
    cond do
      RobinhoodLab.chain?(auction.chain_id) ->
        stock_rate(rates.robinhood, auction.quote_token_symbol)

      auction.kind == :agent ->
        rates.regent

      true ->
        stock_rate(rates.base, auction.quote_token_symbol)
    end
  end

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
  The amount's dollar value, such as `≈ $1,234.50`, written as
  `RegentFormat.amount/1` writes an amount; nothing for an amount that is not a
  number.
  """
  def usd(assigns) do
    assigns = assign(assigns, :text, text(decimal(assigns.amount), assigns.rate, assigns.per))

    ~H"""
    <span :if={@text} class={["usd-value", @class]}>{@text}</span>
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

  @doc "A dollar figure, such as `$1,234.50` or `$0.0123`, as every Regent page writes one."
  def dollars(value), do: "$" <> RegentFormat.amount(value)
end
