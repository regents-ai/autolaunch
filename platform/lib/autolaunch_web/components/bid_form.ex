defmodule AutolaunchWeb.Components.BidForm do
  @moduledoc """
  The one bid form, used by every bid panel, laid out as three boxes: the max
  budget, the max FDV (the most the whole token supply may be worth while the
  bid keeps buying) and what the bid can expect to receive.

  The max FDV comes from one of three places, named by `basis`: a stop on the
  slider, each a multiple of the price to beat now ("stop"); a total value
  typed into the box ("fdv"); or a price per token entered from elsewhere on
  the page, such as "Use this price" ("price"). The browser sends the slider
  and the box beside what they last showed, so the one that differs is the one
  the bidder moved.

  The FDV is shown in the currency paid, so a dollar budget shows a dollar FDV
  at the dollar price of the auction's currency. On a test network, whose coins
  carry no dollar value, it stays in the auction's own currency.

  The host component owns `bid_form_changed`, sent with the form's fields as
  they change (`values/3` reads them), and `fill_bid_amount` when a balance is
  offered, and puts its own button in the `action` slot.
  """
  use Phoenix.Component

  alias Autolaunch.AuctionBook
  alias Autolaunch.Stocks.Amounts
  alias AutolaunchWeb.{TokenDisplay, UsdValue}
  alias Phoenix.LiveView.{AsyncResult, JS}

  # Each slider stop is the price to beat now times one of these.
  @stops Enum.map(~w(1 1.1 1.25 1.5 2 2.5 3 4 5 7.5 10), &Decimal.new/1)
  # The price to beat now plus a quarter, so a small rise does not stop the bid.
  @default_stop 2
  @last_stop length(@stops) - 1
  @bases ~w(stop fdv price)
  @dollars ~w(USDC USDG)
  @plain ~r/\A(?:\d+(?:\.\d+)?|\.\d+)\z/
  @price_digits 12
  @one Decimal.new(1)

  @doc "An empty form, its max FDV on the slider at the price to beat plus a quarter."
  def blank,
    do: %{amount: "", pay_with: nil, basis: "stop", stop: @default_stop, fdv: "", price: ""}

  @doc "The form with its max FDV set by a price per token entered from elsewhere on the page."
  def at_price(form, price), do: %{form | basis: "price", price: price}

  @doc """
  The form's fields as the browser sent them. `max_price` is the bid's most per
  token before this change: a typed FDV is kept as that price when the
  currency switches, so switching never changes the bid's limit.
  """
  def values(params, form, max_price) do
    typed = %{
      form
      | amount: trimmed(params, "amount"),
        pay_with: Map.get(params, "pay_with", form.pay_with),
        basis: basis(params),
        stop: stop(params["stop"], form.stop),
        fdv: trimmed(params, "fdv"),
        price: trimmed(params, "price")
    }

    if params["_target"] == ["pay_with"] and typed.basis == "fdv",
      do: %{typed | basis: "price", price: max_price || ""},
      else: typed
  end

  defp basis(params) do
    cond do
      params["stop"] != params["stop_shown"] -> "stop"
      trimmed(params, "fdv") != trimmed(params, "fdv_shown") -> "fdv"
      params["basis"] in @bases -> params["basis"]
      true -> "stop"
    end
  end

  defp stop(value, current) when is_binary(value) do
    case Integer.parse(value) do
      {stop, ""} when stop in 0..@last_stop -> stop
      _other -> current
    end
  end

  defp stop(_value, current), do: current

  defp trimmed(params, key), do: params |> Map.get(key, "") |> String.trim()

  @doc """
  The currency the max FDV is shown in, and what one unit of the auction's own
  currency is worth in it: nil while that dollar price is unknown.
  """
  def fdv_currency(unit, unit, _rate), do: {unit, @one}
  def fdv_currency(_paid, unit, :test_network), do: {unit, @one}
  def fdv_currency(paid, _unit, rate), do: {paid, rate}

  @doc """
  The most the bid pays per token, as a plain decimal, or nil while it cannot
  be worked out: no price read yet, no token supply or dollar price for a
  typed FDV, or a figure that is not a number above zero. `factor` is the
  second half of `fdv_currency/3`.
  """
  def max_price(
        %{basis: "stop", stop: stop},
        %AsyncResult{ok?: true, result: %{price_to_beat: beat}},
        _supply,
        _factor
      )
      when is_binary(beat),
      do: beat |> decimal() |> Decimal.mult(Enum.at(@stops, stop)) |> plain()

  def max_price(%{basis: "price", price: price}, _book, _supply, _factor) do
    if positive?(price), do: price
  end

  def max_price(%{basis: "fdv", fdv: fdv}, _book, %Decimal{} = supply, %Decimal{} = factor) do
    fdv = String.replace(fdv, ",", "")

    if positive?(fdv) and Decimal.gt?(supply, 0) and Decimal.gt?(factor, 0) do
      Decimal.Context.with(%Decimal.Context{precision: @price_digits}, fn ->
        fdv |> decimal() |> Decimal.div(Decimal.mult(supply, factor)) |> plain()
      end)
    end
  end

  def max_price(_form, _book, _supply, _factor), do: nil

  attr :id, :string, required: true, doc: "the bid panel's id"
  attr :title, :string, required: true
  slot :help, doc: "how bidding works, behind the ? beside the title"

  @doc "The bid panel's title, with how bidding works behind a ? beside it."
  def title(assigns) do
    ~H"""
    <header class="bid-title">
      <h2>{@title}</h2>
      <details
        :if={@help != []}
        id={"#{@id}-help"}
        class="bid-help"
        phx-mounted={JS.ignore_attributes(["open"])}
      >
        <summary aria-label="How bidding works">?</summary>
        <div class="bid-help__panel">{render_slot(@help)}</div>
      </details>
    </header>
    """
  end

  attr :id, :string, required: true, doc: "the bid panel's id; fields are named after it"
  attr :target, :any, required: true
  attr :form, :map, required: true
  attr :amount_unit, :string, required: true, doc: "the currency the budget is paid in"

  attr :pay_with, :list,
    default: [],
    doc: "currencies to switch between, shown when more than one"

  attr :price_unit, :string, required: true, doc: "the currency prices are in"
  attr :token_symbol, :string, required: true
  attr :book, AsyncResult, required: true
  attr :supply, :any, default: nil, doc: "the token's total supply as a Decimal, or nil"

  attr :rate, :any,
    default: nil,
    doc: "the USD price of one unit of the price currency, nil while unknown, or :test_network"

  attr :balance, :string, default: nil, doc: "the wallet's balance of the budget currency"

  slot :action, required: true, doc: "the button that places the bid"

  def bid_form(assigns) do
    %{form: form, book: book, supply: supply, rate: rate} = assigns
    {fdv_unit, factor} = fdv_currency(assigns.amount_unit, assigns.price_unit, rate)
    max_price = max_price(form, book, supply, factor)
    ready = book.ok? && book.result
    beat = ready && ready.price_to_beat
    labels = stop_prices(beat, factor, fdv_unit)
    stop = shown_stop(form, max_price, beat)
    budget_rate = budget_rate(assigns.amount_unit, rate)

    assigns =
      assign(assigns,
        dollars?: fdv_unit in @dollars,
        fdv_unit: fdv_unit,
        ready: ready,
        beat: beat,
        stop: stop,
        last_stop: @last_stop,
        at: stop / @last_stop,
        labels: labels,
        stop_fdvs: stop_fdvs(beat, supply, factor),
        price_label: max_price && factor && price_text(times(max_price, factor), fdv_unit),
        fdv: shown_fdv(form, max_price, supply, factor),
        fdv_in_price_unit: max_price && supply && times(max_price, supply),
        budget_rate: budget_rate,
        budget_usd?: form.amount != "" and budget_rate != :test_network,
        outlook: outlook(ready, max_price, form, assigns)
      )

    ~H"""
    <form
      id={"#{@id}-form"}
      class="bid-form"
      phx-change="bid_form_changed"
      phx-submit="bid_form_changed"
      phx-target={@target}
      phx-hook=".MaxFdv"
      aria-label="Place a bid"
    >
      <input type="hidden" name="basis" value={@form.basis} />
      <input type="hidden" name="price" value={@form.price} />

      <div class="bid-box">
        <div class="bid-box__row">
          <div class="bid-box__main">
            <label class="bid-box__label" for={"#{@id}-amount"}>Max budget</label>
            <input
              id={"#{@id}-amount"}
              class="bid-box__figure"
              name="amount"
              value={@form.amount}
              phx-debounce="400"
              inputmode="decimal"
              autocomplete="off"
              placeholder="0"
            />
          </div>
          <div class="bid-box__side">
            <fieldset :if={length(@pay_with) > 1} class="bid-switch">
              <legend class="visually-hidden">Pay with</legend>
              <label :for={currency <- @pay_with}>
                <input
                  type="radio"
                  name="pay_with"
                  value={currency}
                  checked={@form.pay_with == currency}
                />
                <span>{currency}</span>
              </label>
            </fieldset>
            <span class="bid-chip">{@amount_unit}</span>
          </div>
        </div>
        <div :if={@budget_usd? || @balance} class="bid-box__row bid-box__sub">
          <UsdValue.usd :if={@budget_usd?} amount={@form.amount} rate={@budget_rate} />
          <button
            :if={@balance}
            type="button"
            class="bid-box__balance"
            phx-click="fill_bid_amount"
            phx-target={@target}
          >
            Balance {@balance}
          </button>
        </div>
      </div>

      <div class="bid-box">
        <label class="bid-box__label" for={"#{@id}-max-fdv"}>Max FDV</label>
        <div class="bid-box__fdv">
          <span :if={@dollars?} class="bid-box__figure bid-box__prefix" aria-hidden="true">$</span>
          <input
            id={"#{@id}-max-fdv"}
            class="bid-box__figure"
            name="fdv"
            value={@fdv}
            phx-debounce="400"
            inputmode="decimal"
            autocomplete="off"
            placeholder="0"
            aria-describedby={"#{@id}-fdv-unit"}
          />
          <span id={"#{@id}-fdv-unit"} class={["bid-box__unit", @dollars? && "visually-hidden"]}>
            {@fdv_unit}
          </span>
        </div>
        <input type="hidden" name="fdv_shown" value={@fdv} />
        <p
          :if={@fdv_in_price_unit && (@fdv_unit != @price_unit || @rate != :test_network)}
          class="bid-box__sub"
        >
          <span :if={@fdv_unit != @price_unit}>
            ≈ <TokenDisplay.written value={figure(@fdv_in_price_unit)} unit={@price_unit} />
          </span>
          <UsdValue.usd :if={@fdv_unit == @price_unit} amount={@fdv_in_price_unit} rate={@rate} />
        </p>

        <div :if={@beat} class="bid-slider" style={"--at: #{@at}"}>
          <output class="bid-slider__tip" for={"#{@id}-stop"}>
            {@price_label && "Price: #{@price_label}"}
          </output>
          <span class="bid-slider__dots" aria-hidden="true">
            <i :for={_stop <- 0..@last_stop}></i>
          </span>
          <input
            id={"#{@id}-stop"}
            type="range"
            name="stop"
            min="0"
            max={@last_stop}
            step="1"
            value={@stop}
            phx-debounce="150"
            aria-label="Max FDV"
            aria-valuetext={@price_label && "#{@price_label} per token"}
            data-labels={Jason.encode!(Enum.map(@labels, &"Price: #{&1}"))}
            data-fdvs={Jason.encode!(@stop_fdvs)}
          />
          <input type="hidden" name="stop_shown" value={@stop} />
        </div>

        <p :if={@book.loading} class="bid-box__note">Reading the current price…</p>
        <p :if={@book.failed} class="bid-box__note">
          The current price could not be read just now. Type a max FDV instead.
        </p>
        <p :if={@ready && !@beat} class="bid-box__note">
          Bids have reached the highest price this auction takes.
        </p>
      </div>

      <div class="bid-box bid-box--receive" role="status">
        <span class="bid-box__label">Receive</span>
        <.expected outlook={@outlook} amount={@form.amount} token={@token_symbol} />
      </div>

      {render_slot(@action)}
    </form>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".MaxFdv">
      // While the slider is dragged, its price and the FDV it sets follow it at
      // once; the server answers with the same figures when the drag settles.
      export default {
        mounted() {
          this.el.addEventListener("input", (event) => {
            const slider = event.target
            if (!(slider instanceof HTMLInputElement) || slider.name !== "stop") return

            const stop = Number(slider.value)
            const labels = JSON.parse(slider.dataset.labels || "[]")
            const fdvs = JSON.parse(slider.dataset.fdvs || "[]")
            const tip = slider.parentElement.querySelector(".bid-slider__tip")
            const fdv = this.el.elements.namedItem("fdv")

            slider.parentElement.style.setProperty("--at", String(stop / Number(slider.max)))
            if (tip && labels[stop]) tip.textContent = labels[stop]
            if (fdv instanceof HTMLInputElement && fdvs[stop] !== undefined) fdv.value = fdvs[stop]
          })
        }
      }
    </script>
    """
  end

  defp outlook(ready, max_price, _form, _assigns) when ready in [nil, false] or is_nil(max_price),
    do: nil

  defp outlook(ready, max_price, form, assigns),
    do: AuctionBook.outlook(budget(form.amount, assigns), max_price, ready)

  attr :outlook, :map, default: nil
  attr :amount, :string, required: true
  attr :token, :string, required: true

  # What the budget can expect at the max FDV, against the price to beat now.
  defp expected(%{outlook: %{reaches?: true, about: about}} = assigns) when is_binary(about) do
    ~H"""
    <p class="bid-box__figure">
      ≈ {figure(decimal(@outlook.about))} <span class="ticker">{@token}</span>
    </p>
    <p :if={@outlook.at_least} class="bid-box__sub">
      At least <span class="figure__value">{figure(decimal(@outlook.at_least), :floor)}</span>
      if the price rises to your max
    </p>
    """
  end

  defp expected(%{outlook: %{reaches?: true}} = assigns) do
    ~H"""
    <p class="bid-box__sub">
      {if @amount == "", do: "Enter a budget", else: "Your bid starts buying next block"}
    </p>
    """
  end

  defp expected(%{outlook: %{reaches?: false}} = assigns) do
    ~H"""
    <p class="bid-box__sub">Too low to buy right now. Raise your max FDV.</p>
    """
  end

  defp expected(assigns) do
    ~H"""
    <p class="bid-box__sub">Enter a budget and a max FDV</p>
    """
  end

  # The budget in the auction's own currency, which the book counts tokens in.
  defp budget(amount, %{amount_unit: unit, price_unit: unit}), do: amount

  defp budget(amount, %{rate: %Decimal{} = rate}) do
    if positive?(amount), do: amount |> decimal() |> Decimal.div(rate) |> plain(), else: ""
  end

  defp budget(_amount, _assigns), do: ""

  # A dollar budget is its own dollar value, except on a test network.
  defp budget_rate(_unit, :test_network), do: :test_network
  defp budget_rate(unit, _rate) when unit in @dollars, do: @one
  defp budget_rate(_unit, rate), do: rate

  # The stop on show: the one chosen, or the highest at or under a limit set
  # another way.
  defp shown_stop(%{basis: "stop", stop: stop}, _max_price, _beat), do: stop

  defp shown_stop(_form, max_price, beat) when is_binary(max_price) and is_binary(beat) do
    ratio = Decimal.div(decimal(max_price), decimal(beat))
    max(Enum.count(@stops, &(not Decimal.gt?(&1, ratio))) - 1, 0)
  end

  defp shown_stop(form, _max_price, _beat), do: form.stop

  defp shown_fdv(%{basis: "fdv", fdv: fdv}, _max_price, _supply, _factor), do: fdv

  defp shown_fdv(_form, max_price, %Decimal{} = supply, %Decimal{} = factor)
       when is_binary(max_price),
       do: max_price |> times(supply) |> times(factor) |> figure()

  defp shown_fdv(_form, _max_price, _supply, _factor), do: ""

  defp stop_prices(beat, %Decimal{} = factor, unit) when is_binary(beat),
    do: Enum.map(@stops, &(beat |> times(&1) |> times(factor) |> price_text(unit)))

  defp stop_prices(_beat, _factor, _unit), do: []

  defp stop_fdvs(beat, %Decimal{} = supply, %Decimal{} = factor) when is_binary(beat),
    do: Enum.map(@stops, &(beat |> times(&1) |> times(supply) |> times(factor) |> figure()))

  defp stop_fdvs(_beat, _supply, _factor), do: []

  defp price_text(value, unit) do
    short = value |> plain() |> TokenDisplay.short()
    TokenDisplay.zeros(if unit in @dollars, do: "$" <> short, else: "#{short} #{unit}")
  end

  # A total: whole and grouped from a thousand up, cents from one up, and four
  # significant digits below that.
  defp figure(value, mode \\ :half_up) do
    cond do
      Decimal.gte?(value, 1000) ->
        value |> Decimal.round(0, mode) |> grouped()

      Decimal.gte?(value, 1) ->
        value |> Decimal.round(2, mode) |> Decimal.normalize() |> grouped()

      true ->
        value |> plain() |> TokenDisplay.short(if mode == :floor, do: :down, else: :nearest)
    end
  end

  defp grouped(value), do: value |> Decimal.to_string(:normal) |> Amounts.grouped()

  defp times(value, by), do: value |> decimal() |> Decimal.mult(by)

  defp positive?(typed),
    do: String.match?(typed, @plain) and Decimal.gt?(decimal(typed), 0)

  defp decimal(%Decimal{} = value), do: value
  defp decimal(typed), do: Decimal.new(typed, max_digits: :infinity)

  defp plain(decimal), do: Decimal.to_string(decimal, :normal)
end
