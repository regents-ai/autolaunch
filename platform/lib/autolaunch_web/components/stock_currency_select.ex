defmodule AutolaunchWeb.Components.StockCurrencySelect do
  @moduledoc "Stock currency selection; execution admission remains server-owned."
  use Phoenix.Component

  attr :id, :string, default: "stock-currency"
  attr :name, :string, default: "stock_draft[stock_token_address]"
  attr :value, :string, default: ""
  attr :disabled, :boolean, default: false

  def stock_currency_select(assigns) do
    assigns = assign(assigns, :options, Autolaunch.Stocks.Assets.options())

    ~H"""
    <div>
      <label for={@id}>Auction currency · Base stock token</label>
      <select id={@id} name={@name} required disabled={@disabled} aria-describedby={@id <> "-help"}>
        <option value="" selected={@value == ""}>Choose a stock token</option>
        <option :for={{symbol, address} <- @options} value={address} selected={@value == address}>
          {symbol} · {address}
        </option>
      </select>
      <p id={@id <> "-help"}>
        Bids and refunds use the selected stock token. USDC is converted before bidding.
        These assets are listed for selection, not yet admitted for launch execution.
        Asset transfer policies and execution availability require separate verification.
      </p>
    </div>
    """
  end
end
