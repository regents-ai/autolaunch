defmodule AutolaunchWeb.Components.StockCurrencySelect do
  @moduledoc "Stock currency selection; execution admission remains server-owned."
  use Phoenix.Component

  alias Autolaunch.Chain.Address
  alias Autolaunch.Stocks.{Amounts, Assets, PriceFeeds}

  attr :id, :string, default: "stock-currency"
  attr :name, :string, default: "stock_draft[stock_token_address]"
  attr :value, :string, default: ""
  attr :disabled, :boolean, default: false
  attr :chain, :atom, required: true
  attr :prices, :map, default: %{}

  def stock_currency_select(assigns) do
    assigns =
      assigns
      |> assign(:stocks, Assets.all(assigns.chain))
      |> assign(:chain_label, Autolaunch.LaunchChain.label(assigns.chain))

    ~H"""
    <fieldset id={@id} class="stock-picker" disabled={@disabled}>
      <legend>Auction currency · {@chain_label} stock token</legend>
      <div class="stock-picker__grid">
        <label :for={stock <- @stocks} class="stock-picker__tile">
          <input
            type="radio"
            name={@name}
            value={stock.address}
            checked={Address.equal?(@value, stock.address)}
            required
          />
          <span class="stock-picker__mark" aria-hidden="true">{monogram(stock.symbol)}</span>
          <span class="stock-picker__symbol">{stock.symbol}</span>
          <span class="stock-picker__name">{stock.name}</span>
          <span class="stock-picker__price">{usd_price(@prices[PriceFeeds.ticker(stock.symbol)])}</span>
        </label>
      </div>
    </fieldset>
    """
  end

  defp monogram(symbol), do: symbol |> PriceFeeds.ticker() |> String.slice(0, 2)

  @doc "A USD price for reading, such as `$1,792.32`; a dash while none is known."
  def usd_price(nil), do: "—"

  def usd_price(%Decimal{} = price),
    do: "$" <> (price |> Decimal.round(2) |> Decimal.to_string(:normal) |> Amounts.grouped())

  @doc "A dollar amount rounded for a sentence: `$1.7M`, `$580K`, `$593`."
  def compact_usd(amount) when is_number(amount) do
    cond do
      amount >= 1.0e9 -> "$#{one_decimal(amount / 1.0e9)}B"
      amount >= 1.0e6 -> "$#{one_decimal(amount / 1.0e6)}M"
      amount >= 1.0e3 -> "$#{round(amount / 1.0e3)}K"
      true -> "$#{round(amount)}"
    end
  end

  defp one_decimal(number), do: :erlang.float_to_binary(number / 1, decimals: 1)
end
