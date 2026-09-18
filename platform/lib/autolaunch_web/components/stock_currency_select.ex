defmodule AutolaunchWeb.Components.StockCurrencySelect do
  @moduledoc "Stock currency selection; execution admission remains server-owned."
  use Phoenix.Component

  attr :id, :string, default: "stock-currency"
  attr :name, :string, default: "stock_draft[stock_token_address]"
  attr :value, :string, default: ""
  attr :disabled, :boolean, default: false
  attr :chain, :atom, required: true

  def stock_currency_select(assigns) do
    assigns =
      assigns
      |> assign(:options, Autolaunch.Stocks.Assets.options(assigns.chain))
      |> assign(:chain_label, Autolaunch.LaunchChain.label(assigns.chain))
      |> assign(:dollar, Autolaunch.LaunchChain.raise_currency(assigns.chain))

    ~H"""
    <div>
      <label for={@id}>Auction currency · {@chain_label} stock token</label>
      <select id={@id} name={@name} required disabled={@disabled} aria-describedby={@id <> "-help"}>
        <option value="" selected={@value == ""}>Choose a stock token</option>
        <option :for={{symbol, address} <- @options} value={address} selected={@value == address}>
          {symbol} · {address}
        </option>
      </select>
      <p id={@id <> "-help"}>
        Bids and refunds use the selected stock token. {@dollar} is converted before bidding.
        These assets are listed for selection, not yet admitted for launch execution.
        Asset transfer policies and execution availability require separate verification.
      </p>
    </div>
    """
  end
end
