defmodule AutolaunchWeb.Components.StockSelect do
  @moduledoc """
  The paired stock as a gallery: the chosen stock's logo, ticker and name on a
  button, and under it every stock the chain offers as a card with its logo,
  company website and past week's trading volume. Each card is a radio choice,
  so the choice saves with the form it names like any other field.

  Search narrows the cards in the browser as it is typed. Sorting is the
  page's: it puts the cards in order, so keyboard and screen-reader order
  match what is seen. Opening and closing happen in the browser; execution
  admission remains server-owned.
  """
  use Phoenix.Component

  alias Autolaunch.Stocks.{Assets, Companies, PriceFeeds}
  alias Phoenix.LiveView.JS
  alias RegentChain.Address

  @logo_dir Application.app_dir(:autolaunch, "priv/static/images/stocks")

  @logo_files @logo_dir |> File.ls!() |> Enum.sort()
  @logos for file <- @logo_files,
             Path.extname(file) in ~w(.svg .png),
             into: %{},
             do: {Path.rootname(file), "/images/stocks/" <> file}

  @sorts [
    {"alphabetical", "Alphabetical"},
    {"volume", "Trading Volume"},
    {"added", "Recently Added"}
  ]

  def __mix_recompile__?, do: @logo_dir |> File.ls!() |> Enum.sort() != @logo_files

  @doc "The gallery's sort orders, by the name the page sends back."
  def sorts, do: Enum.map(@sorts, &elem(&1, 0))

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, default: ""
  attr :chain, :atom, required: true
  attr :sort, :string, default: "alphabetical"
  attr :sort_event, :string, required: true
  attr :form, :string, required: true, doc: "the id of the form the choice saves with"

  def stock_select(assigns) do
    stocks =
      assigns.chain
      |> Assets.all()
      |> Enum.map(&card/1)
      |> ordered(assigns.sort)

    assigns =
      assign(assigns,
        stocks: stocks,
        sorts: @sorts,
        selected: Enum.find(stocks, &Address.equal?(assigns.value, &1.address))
      )

    ~H"""
    <div
      id={@id}
      class="stock-select"
      phx-hook="MotionPanels"
      phx-click-away={close(@id)}
      phx-window-keydown={close(@id)}
      phx-key="Escape"
    >
      <button
        type="button"
        id={"#{@id}-button"}
        class="stock-select__button"
        aria-haspopup="dialog"
        aria-expanded="false"
        aria-controls={"#{@id}-list"}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
        phx-click={toggle(@id)}
      >
        <%= if @selected do %>
          <.stock_logo stock={@selected} />
          <span class="stock-select__symbol">{@selected.symbol}</span>
          <span class="stock-select__name">{@selected.company}</span>
        <% else %>
          <span class="stock-select__placeholder">Choose a stock</span>
        <% end %>
        <span class="stock-select__chevron" aria-hidden="true">⌄</span>
      </button>
      <div
        id={"#{@id}-list"}
        class="stock-select__list stock-gallery"
        hidden
        {AutolaunchWeb.Motion.panel("menu", ["hidden"])}
      >
        <div
          id={"#{@id}-gallery"}
          class="stock-gallery__body"
          phx-hook=".StockGallery"
          data-close={close(@id)}
          data-button={"#{@id}-button"}
        >
          <input
            type="search"
            id={"#{@id}-search"}
            class="stock-gallery__search"
            form=""
            placeholder="Search stocks"
            aria-label="Search stocks"
            aria-controls={"#{@id}-cards"}
            autocomplete="off"
            phx-update="ignore"
            data-stock-search
          />
          <div class="stock-gallery__sorts" role="group" aria-label="Sort stocks">
            <button
              :for={{key, label} <- @sorts}
              type="button"
              class="stock-gallery__sort"
              aria-pressed={to_string(@sort == key)}
              phx-click={JS.push(@sort_event, value: %{by: key})}
            >
              {label}
            </button>
          </div>
          <fieldset id={"#{@id}-cards"} class="stock-gallery__cards">
            <legend class="visually-hidden">Paired stock</legend>
            <div
              :for={stock <- @stocks}
              id={"#{@id}-card-#{String.downcase(stock.address)}"}
              class="stock-card"
              data-search={stock.search}
              phx-mounted={JS.ignore_attributes(["hidden"])}
            >
              <label class="stock-card__choice">
                <input
                  type="radio"
                  name={@name}
                  form={@form}
                  value={stock.address}
                  checked={Address.equal?(@value, stock.address)}
                />
                <.stock_logo stock={stock} />
                <span class="stock-card__names">
                  <span class="stock-select__symbol">{stock.symbol}</span>
                  <span class="stock-select__name">{stock.company}</span>
                </span>
                <span class="stock-card__volume">{volume_line(stock.volume)}</span>
              </label>
              <a
                :if={stock.website}
                class="stock-card__site"
                href={stock.website}
                target="_blank"
                rel="noopener noreferrer"
              >
                {URI.parse(stock.website).host |> String.replace_prefix("www.", "")}
              </a>
            </div>
          </fieldset>
          <p
            :if={@stocks != []}
            id={"#{@id}-no-match"}
            class="stock-gallery__empty"
            role="status"
            hidden
            data-stock-empty
            phx-mounted={JS.ignore_attributes(["hidden"])}
          >
            No stocks match your search.
          </p>
          <p :if={@stocks == []} id={"#{@id}-none"} class="stock-gallery__empty" role="status">
            No stocks are offered on this chain right now.
          </p>
        </div>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".StockGallery">
      // Hides the cards the search does not name. The cards keep their
      // hidden mark through page updates, so it is applied again after each.
      // A card picked with the pointer closes the gallery; arrow keys move the
      // choice without closing it, and Enter on a card closes it and returns
      // to the button.
      export default {
        mounted() {
          this.search = this.el.querySelector("[data-stock-search]")
          this.search.addEventListener("input", () => this.narrow())
          this.el.addEventListener("click", event => {
            if (event.detail > 0 && event.target.closest(".stock-card__choice")) {
              this.js().exec(this.el.dataset.close)
            }
          })
          this.el.addEventListener("keydown", event => {
            if (event.key === "Enter" && event.target.type === "radio") {
              event.preventDefault()
              this.js().exec(this.el.dataset.close)
              document.getElementById(this.el.dataset.button).focus()
            }
          })
        },
        updated() { this.narrow() },
        narrow() {
          const words = this.search.value.trim().toLowerCase()
          const cards = [...this.el.querySelectorAll("[data-search]")]
          cards.forEach(card => { card.hidden = words !== "" && !card.dataset.search.includes(words) })
          const empty = this.el.querySelector("[data-stock-empty]")
          if (empty) empty.hidden = cards.some(card => !card.hidden)
        }
      }
    </script>
    """
  end

  # A card's facts: the added time is when this site first offered the stock;
  # a stock offered before the site kept that record has none and sorts after
  # those that do.
  defp card(stock) do
    ticker = PriceFeeds.ticker(stock.symbol)
    company = company(stock)

    %{
      address: stock.address,
      symbol: stock.symbol,
      ticker: ticker,
      company: company,
      website: Companies.website(ticker),
      volume: weekly_volume(stock),
      added_at: stock.offered_at,
      search: String.downcase("#{stock.symbol} #{company} #{stock.search_text}")
    }
  end

  # The past week is the seven whole UTC days up to yesterday. Each morning's
  # reads take a few hours, so until a stock's lands its count to the day
  # before shows with that week named; an older count shows none.
  defp weekly_volume(%{
         weekly_volume_usd: %Decimal{} = usd,
         weekly_volume_complete: complete?,
         weekly_volume_through: through
       }) do
    if Date.diff(Date.utc_today(), through) <= 2,
      do: %{usd: Decimal.to_float(usd), complete?: complete?, through: through}
  end

  defp weekly_volume(_stock), do: nil

  defp ordered(stocks, "volume"),
    do:
      Enum.sort_by(stocks, &{is_nil(&1.volume), -((&1.volume && &1.volume.usd) || 0), &1.symbol})

  # By the day each was first offered: stocks recorded the same day were added
  # together, so they keep alphabetical order among themselves.
  defp ordered(stocks, "added"),
    do:
      Enum.sort_by(
        stocks,
        &{is_nil(&1.added_at),
         &1.added_at && -(&1.added_at |> DateTime.to_date() |> Date.to_gregorian_days()),
         &1.symbol}
      )

  defp ordered(stocks, "alphabetical"), do: Enum.sort_by(stocks, & &1.symbol)

  # A floor, from a stock whose pools GeckoTerminal lists over more than one
  # page, reads as at least that much.
  defp volume_line(nil), do: "Volume unavailable"

  defp volume_line(%{usd: usd, complete?: complete?, through: through}) do
    floor = if complete?, do: "", else: "+"

    week =
      if through == Date.add(Date.utc_today(), -1),
        do: "past week",
        else: "week to #{Calendar.strftime(through, "%-d %b")}"

    "#{compact_usd(usd)}#{floor} #{week}"
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
