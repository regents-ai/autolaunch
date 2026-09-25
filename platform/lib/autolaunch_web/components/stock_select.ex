defmodule AutolaunchWeb.Components.StockSelect do
  @moduledoc """
  The paired stock as one dropdown: the chosen stock's logo, ticker and name on
  a button, and the chain's stocks listed under it as radio choices, so the
  choice saves with its form like any other field. Opening and closing happen
  in the browser; execution admission remains server-owned.
  """
  use Phoenix.Component

  alias Autolaunch.Chain.Address
  alias Autolaunch.Stocks.{Assets, PriceFeeds}
  alias Phoenix.LiveView.JS

  @logo_dir Application.app_dir(:autolaunch, "priv/static/images/stocks")

  @logo_files @logo_dir |> File.ls!() |> Enum.sort()
  @logos for file <- @logo_files,
             Path.extname(file) in ~w(.svg .png),
             into: %{},
             do: {Path.rootname(file), "/images/stocks/" <> file}

  def __mix_recompile__?, do: @logo_dir |> File.ls!() |> Enum.sort() != @logo_files

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, default: ""
  attr :chain, :atom, required: true

  def stock_select(assigns) do
    stocks = Assets.all(assigns.chain)

    assigns =
      assign(assigns,
        stocks: stocks,
        selected: Enum.find(stocks, &Address.equal?(assigns.value, &1.address))
      )

    ~H"""
    <div
      id={@id}
      class="stock-select"
      phx-click-away={close(@id)}
      phx-window-keydown={close(@id)}
      phx-key="Escape"
    >
      <button
        type="button"
        id={"#{@id}-button"}
        class="stock-select__button"
        aria-haspopup="listbox"
        aria-expanded="false"
        aria-controls={"#{@id}-list"}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
        phx-click={toggle(@id)}
      >
        <%= if @selected do %>
          <.stock_logo stock={@selected} />
          <span class="stock-select__symbol">{@selected.symbol}</span>
          <span class="stock-select__name">{company(@selected)}</span>
        <% else %>
          <span class="stock-select__placeholder">Choose a stock</span>
        <% end %>
        <span class="stock-select__chevron" aria-hidden="true">⌄</span>
      </button>
      <fieldset
        id={"#{@id}-list"}
        class="stock-select__list"
        hidden
        phx-mounted={JS.ignore_attributes(["hidden"])}
        phx-keydown={close(@id)}
        phx-key="Enter"
      >
        <legend class="visually-hidden">Paired stock</legend>
        <label :for={stock <- @stocks} class="stock-select__option" phx-click={close(@id)}>
          <input
            type="radio"
            name={@name}
            value={stock.address}
            checked={Address.equal?(@value, stock.address)}
          />
          <.stock_logo stock={stock} />
          <span class="stock-select__symbol">{stock.symbol}</span>
          <span class="stock-select__name">{company(stock)}</span>
        </label>
      </fieldset>
    </div>
    """
  end

  attr :stock, :map, required: true

  @doc "A stock's logo on its round chip; its first letters when no logo is stored."
  def stock_logo(assigns) do
    ticker = PriceFeeds.ticker(assigns.stock.symbol)
    assigns = assign(assigns, ticker: ticker, logo: Map.get(@logos, ticker))

    ~H"""
    <span class="stock-logo" aria-hidden="true">
      <img :if={@logo} src={@logo} alt="" width="20" height="20" loading="lazy" />
      <span :if={!@logo}>{String.slice(@ticker, 0, 2)}</span>
    </span>
    """
  end

  # Robinhood lists its stocks with the network in every name.
  defp company(stock), do: String.replace_suffix(stock.name, " • Robinhood Token", "")

  defp toggle(id) do
    JS.toggle_attribute({"hidden", "hidden"}, to: "##{id}-list")
    |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "##{id}-button")
    |> JS.focus_first(to: "##{id}-list")
  end

  defp close(id) do
    JS.set_attribute({"hidden", "hidden"}, to: "##{id}-list")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "##{id}-button")
  end

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
