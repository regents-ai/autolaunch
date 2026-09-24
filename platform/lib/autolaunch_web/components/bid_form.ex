defmodule AutolaunchWeb.Components.BidForm do
  @moduledoc """
  The one bid form, used by every bid panel: a total bid amount, and a box to
  bid at the current price. Ticked, the most the bid pays per token is the
  price to beat now plus a quarter, so a small rise in the price does not stop
  it buying. Unticked, "Advanced" sets that limit as the most the whole token may
  be worth (its fully diluted value, the default) or as a price per token.

  The host component owns the events: `bid_form_changed` with the form's
  fields, which `values/1` reads, and `review_bid`, which reviews the bid at
  `max_price/3`.
  """
  use Phoenix.Component

  alias Autolaunch.AuctionBook
  alias AutolaunchWeb.{TokenDisplay, UsdValue}
  alias Phoenix.LiveView.AsyncResult

  # The price to beat now, plus a quarter.
  @headroom Decimal.new("1.25")
  @plain ~r/\A(?:\d+(?:\.\d+)?|\.\d+)\z/
  @price_digits 12

  @doc "An empty form: the current price ticked, the limit set as a total value."
  def blank, do: %{amount: "", at_price: true, limit_mode: "fdv", limit: "", pay_with: nil}

  @doc "The form's fields as the browser sent them."
  def values(params, form) do
    %{
      form
      | amount: params |> Map.get("amount", "") |> String.trim(),
        at_price: Map.get(params, "at_price") == "true",
        limit_mode: if(params["limit_mode"] == "price", do: "price", else: "fdv"),
        limit: params |> Map.get("limit", "") |> String.trim(),
        pay_with: Map.get(params, "pay_with", form.pay_with)
    }
  end

  @doc """
  The most the bid pays per token, as a plain decimal, or nil while it cannot
  be worked out: no price read yet, no token supply for a total value, or a
  limit that is not a number above zero.
  """
  def max_price(
        %{at_price: true},
        %AsyncResult{ok?: true, result: %{price_to_beat: beat}},
        _supply
      )
      when is_binary(beat),
      do: beat |> decimal() |> Decimal.mult(@headroom) |> plain()

  def max_price(%{at_price: true}, _book, _supply), do: nil

  def max_price(%{limit_mode: "price", limit: limit}, _book, _supply) do
    if positive?(limit), do: limit
  end

  def max_price(%{limit_mode: "fdv", limit: limit}, _book, %Decimal{} = supply) do
    if positive?(limit) and Decimal.gt?(supply, 0) do
      Decimal.Context.with(%Decimal.Context{precision: @price_digits}, fn ->
        limit |> decimal() |> Decimal.div(supply) |> plain()
      end)
    end
  end

  def max_price(_form, _book, _supply), do: nil

  attr :id, :string, required: true, doc: "the bid panel's id; fields are named after it"
  attr :target, :any, required: true
  attr :form, :map, required: true
  attr :amount_unit, :string, required: true, doc: "the currency the total is paid in"
  attr :pay_with, :list, default: [], doc: "currencies to choose from, shown when more than one"
  attr :price_unit, :string, required: true, doc: "the currency prices are in"
  attr :book, AsyncResult, required: true
  attr :supply, :any, default: nil, doc: "the token's total supply as a Decimal, or nil"
  attr :rate, :any, default: nil, doc: "the USD price of one unit of the price currency"
  attr :amount_in_price_unit?, :boolean, default: false
  attr :max, :boolean, default: false, doc: "offer a Max button that fills the balance"

  def bid_form(assigns) do
    max_price = max_price(assigns.form, assigns.book, assigns.supply)
    book = assigns.book.ok? && assigns.book.result

    assigns =
      assign(assigns,
        max_price: max_price,
        fdv: max_price && assigns.supply && total(max_price, assigns.supply),
        book_ready: book,
        outlook:
          book && max_price &&
            AuctionBook.outlook(
              if(assigns.amount_in_price_unit?, do: assigns.form.amount, else: ""),
              max_price,
              book
            )
      )

    ~H"""
    <form
      id={"#{@id}-form"}
      class="rg-field bid-form"
      phx-change="bid_form_changed"
      phx-submit="review_bid"
      phx-target={@target}
      aria-label="Place a bid"
    >
      <fieldset :if={length(@pay_with) > 1} class="bid-form__choice">
        <legend>Pay with</legend>
        <label :for={currency <- @pay_with}>
          <input type="radio" name="pay_with" value={currency} checked={@form.pay_with == currency} />
          {currency}
        </label>
      </fieldset>

      <label for={"#{@id}-amount"}>Total bid amount</label>
      <div class="bid-amount">
        <input
          id={"#{@id}-amount"}
          name="amount"
          value={@form.amount}
          inputmode="decimal"
          autocomplete="off"
          placeholder="0.0"
          aria-describedby={"#{@id}-amount-unit"}
        />
        <span id={"#{@id}-amount-unit"} class="bid-form__unit">{@amount_unit}</span>
        <Regent.Primitives.button
          :if={@max}
          type="button"
          phx-click="fill_bid_amount"
          phx-target={@target}
          variant="secondary"
        >Max</Regent.Primitives.button>
      </div>
      <UsdValue.usd
        :if={@amount_in_price_unit? && @form.amount != ""}
        class="bid-usd"
        amount={@form.amount}
        rate={@rate}
      />

      <label class="bid-form__check">
        <input type="hidden" name="at_price" value="false" />
        <input type="checkbox" name="at_price" value="true" checked={@form.at_price} />
        Bid at the current price
      </label>

      <div :if={@form.at_price} class="bid-form__limit" role="status">
        <p :if={@book.loading}>Reading the current price…</p>
        <p :if={@book.failed}>
          The current price could not be read just now. Untick the box to set your own limit.
        </p>
        <p :if={@book_ready && !@book_ready.price_to_beat}>
          Bids have reached the highest price this auction takes.
        </p>
        <p :if={@max_price}>
          The most you'll pay per token:
          <strong><TokenDisplay.price amount={@max_price} unit={@price_unit} /></strong>
          <UsdValue.usd amount={@max_price} rate={@rate} per="per token" />
          <span class="bid-form__note">That's the price to beat now plus 25%, so your bid keeps buying if the price rises a little.</span>
        </p>
      </div>

      <fieldset :if={!@form.at_price} class="bid-form__advanced">
        <legend>Advanced</legend>
        <div class="bid-form__choice">
          <label>
            <input type="radio" name="limit_mode" value="fdv" checked={@form.limit_mode == "fdv"} />
            Max total value (FDV)
          </label>
          <label>
            <input type="radio" name="limit_mode" value="price" checked={@form.limit_mode == "price"} />
            Max price per token
          </label>
        </div>
        <label for={"#{@id}-max-price"}>
          {if @form.limit_mode == "fdv",
            do: "Most the whole token supply may be worth, in #{@price_unit}",
            else: "Most you'll pay per token, in #{@price_unit}"}
        </label>
        <input
          id={"#{@id}-max-price"}
          name="limit"
          value={@form.limit}
          inputmode="decimal"
          autocomplete="off"
          placeholder="0.0"
        />
        <p :if={@form.limit_mode == "fdv" && !@supply} class="bid-form__note">
          This token's total supply has not been read yet, so set a price per token instead.
        </p>
        <p :if={@form.limit_mode == "fdv" && @max_price} class="bid-form__note">
          That is at most <TokenDisplay.price amount={@max_price} unit={@price_unit} /> per token
          <UsdValue.usd amount={@max_price} rate={@rate} per="per token" />
        </p>
        <p :if={@form.limit_mode == "price" && @fdv} class="bid-form__note">
          That values the whole token supply at up to
          <TokenDisplay.price amount={@fdv} unit={@price_unit} />
          <UsdValue.usd amount={@fdv} rate={@rate} />
        </p>
      </fieldset>

      <.outlook outlook={@outlook} book={@book_ready} symbol={@price_unit} />

      <Regent.Primitives.button
        class="bid-primary"
        type="submit"
        disabled={@form.amount == "" or is_nil(@max_price)}
      >
        Review bid
      </Regent.Primitives.button>
    </form>
    """
  end

  attr :outlook, :map, default: nil
  attr :book, :any, default: nil
  attr :symbol, :string, required: true

  # What the limit means against the auction's price now, and with an amount
  # in the auction's own currency, the tokens it can expect.
  defp outlook(%{outlook: %{reaches?: true}} = assigns) do
    ~H"""
    <div class="bid-estimate" role="status">
      <p>Above the price now: your bid starts buying next block.</p>
      <p :if={@outlook.about}>
        About <TokenDisplay.price amount={@outlook.about} /> tokens if the price stays at
        <TokenDisplay.price amount={@book.clearing} unit={@symbol} />
        and the auction reaches its minimum.
      </p>
      <p :if={@outlook.at_least}>
        At least <TokenDisplay.price amount={@outlook.at_least} round={:down} />
        tokens if the auction reaches its minimum and the price stays below your limit.
      </p>
    </div>
    """
  end

  defp outlook(%{outlook: %{reaches?: false}} = assigns) do
    ~H"""
    <p class="bid-estimate" role="status">
      Too low to buy right now: the price to beat is {@book.price_to_beat} {@symbol} per token.
    </p>
    """
  end

  defp outlook(assigns), do: ~H""

  defp total(price, supply), do: price |> decimal() |> Decimal.mult(supply) |> plain()

  defp positive?(typed),
    do: String.match?(typed, @plain) and Decimal.gt?(decimal(typed), 0)

  defp decimal(typed), do: Decimal.new(typed, max_digits: :infinity)

  defp plain(decimal), do: Decimal.to_string(decimal, :normal)
end
