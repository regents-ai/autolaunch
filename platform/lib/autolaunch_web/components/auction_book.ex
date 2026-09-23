defmodule AutolaunchWeb.Components.AuctionBook do
  @moduledoc """
  The price side of an open auction, for bidders who have never used one: the
  lowest maximum price that gets tokens now, with a button that enters it in
  the bid form; every maximum price bid so far, marked as buying, sharing at
  the price or outbid, around the price everyone pays right now; how much of
  the supply has sold; and three lines on how a bid works. The figures come
  from `Autolaunch.AuctionBook`.
  """
  use Phoenix.Component

  alias AutolaunchWeb.{TokenDisplay, UsdValue}
  alias Phoenix.LiveView.JS

  attr :id, :string, required: true
  attr :book, :map, required: true
  attr :symbol, :string, required: true, doc: "the currency prices are in"
  attr :usd_rate, :any, required: true, doc: "the USD price of one unit, or nil"
  attr :color, :string, default: nil, doc: "the image colour, or nil for the plain bars"
  attr :bid_form, :string, required: true, doc: "the bid component's id"

  def auction_book(assigns) do
    assigns =
      assign(assigns,
        widest:
          assigns.book.levels.shown
          |> Enum.map(&amount(&1.amount))
          |> Enum.max(Decimal, fn -> nil end),
        in_levels: Enum.filter(assigns.book.levels.shown, &(&1.standing == :in)),
        other_levels: Enum.reject(assigns.book.levels.shown, &(&1.standing == :in))
      )

    ~H"""
    <section
      id={@id}
      class="auction-book"
      aria-label="The price to get tokens"
      style={@color && "--image-color: #{@color}"}
    >
      <div :if={@book.price_to_beat} class="auction-book__beat">
        <p class="auction-book__lead">To get tokens now, bid at least</p>
        <p class="auction-book__price">
          <strong><TokenDisplay.counted amount={@book.price_to_beat} unit={@symbol} /></strong>
          per token <UsdValue.usd amount={@book.price_to_beat} rate={@usd_rate} per="per token" />
        </p>
        <Regent.Primitives.button
          type="button"
          variant="secondary"
          phx-click={
            JS.push("use_price", value: %{price: @book.price_to_beat}, target: "##{@bid_form}")
          }
        >
          Use this price
        </Regent.Primitives.button>
      </div>
      <p :if={!@book.price_to_beat} class="auction-book__lead">
        Bids have reached the highest price this auction takes.
      </p>

      <figure class="auction-book__ladder">
        <figcaption>Bids by the most each will pay per token</figcaption>
        <p :if={@book.levels.shown == []} class="auction-book__empty">
          No bids yet. The price starts at
          <TokenDisplay.counted amount={@book.floor} unit={@symbol} /> per token.
        </p>
        <ol :if={@book.levels.shown != []} role="list">
          <li :if={@book.levels.hidden_above > 0} class="auction-book__more">
            {more(@book.levels.hidden_above, "higher")}
          </li>
          <.level :for={level <- @in_levels} level={level} symbol={@symbol} widest={@widest} />
          <li class="auction-book__now">
            <span>Price now</span>
            <span><TokenDisplay.counted amount={@book.clearing} unit={@symbol} /></span>
          </li>
          <.level :for={level <- @other_levels} level={level} symbol={@symbol} widest={@widest} />
          <li :if={@book.levels.hidden_below > 0} class="auction-book__more">
            {more(@book.levels.hidden_below, "lower")}
          </li>
        </ol>
      </figure>

      <p class="auction-book__sold">
        Tokens sold so far: <strong>{sold(@book.sold_percent)}</strong>
      </p>

      <ul class="auction-book__how" role="list" aria-label="How a bid works">
        <li>You set a budget and the most you'll pay per token.</li>
        <li>Your budget is spent a little every block, at the one price everyone pays.</li>
        <li>If the price passes your maximum, you stop buying and the rest comes back to you.</li>
      </ul>
    </section>
    """
  end

  attr :level, :map, required: true
  attr :symbol, :string, required: true
  attr :widest, :any, required: true

  defp level(assigns) do
    ~H"""
    <li class="auction-book__level" data-standing={@level.standing}>
      <span class="auction-book__level-price">
        <TokenDisplay.counted amount={@level.price} />
      </span>
      <span class="auction-book__bar" aria-hidden="true">
        <span style={"width: #{width(@level.amount, @widest)}%"}></span>
      </span>
      <span class="auction-book__level-amount">
        <TokenDisplay.price amount={@level.amount} unit={@symbol} />
        · {standing_label(@level.standing)}
      </span>
    </li>
    """
  end

  @doc "A bid's place against the price now, in words."
  def standing_label(:in), do: "Getting tokens"
  def standing_label(:sharing), do: "Sharing at the current price"
  def standing_label(:outbid), do: "Outbid"

  @doc "The same for one of the bidder's own bids, which also says when an outbid one is repaid."
  def bid_status(:outbid),
    do: "Outbid: the rest comes back when the auction reaches its minimum or ends"

  def bid_status(standing), do: standing_label(standing)

  # A bar never shrinks to nothing, so a small bid still shows.
  defp width(amount, widest),
    do:
      amount
      |> amount()
      |> Decimal.div(widest)
      |> Decimal.mult(100)
      |> Decimal.max(3)
      |> Decimal.to_float()

  defp amount(units), do: Decimal.new(units, max_digits: :infinity)

  defp more(1, side), do: "1 more #{side} price"
  defp more(count, side), do: "#{count} more #{side} prices"

  defp sold(percent) when percent == 0, do: "none yet"
  defp sold(percent) when percent < 0.01, do: "under 0.01%"
  defp sold(percent) when percent < 1, do: "#{Float.round(percent, 2)}%"
  defp sold(percent), do: "#{Float.round(percent, 1)}%"
end
