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
  attr :price_info, :string, default: nil, doc: "more on the price, behind an info icon"

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
      aria-label="The price to start buying"
      style={@color && "--image-color: #{@color}"}
    >
      <div :if={@book.price_to_beat} class="auction-book__beat">
        <p class="auction-book__lead">To start buying now, bid at least</p>
        <p class="auction-book__price">
          <strong><TokenDisplay.counted amount={@book.price_to_beat} unit={@symbol} /></strong>
          per token <UsdValue.usd amount={@book.price_to_beat} rate={@usd_rate} per="per token" />
          <span :if={@price_info} class="auction-book__info">
            <button
              type="button"
              class="auction-book__info-icon"
              aria-label="About this price"
              aria-describedby={"#{@id}-price-info"}
            >
              i
            </button>
            <span id={"#{@id}-price-info"} role="tooltip" class="auction-book__info-panel">
              {@price_info}
            </span>
          </span>
        </p>
        <Regent.Primitives.button
          type="button"
          variant="secondary"
          phx-click={
            "use_price"
            |> JS.push(value: %{price: @book.price_to_beat}, target: "##{@bid_form}")
            |> JS.focus(to: "##{@bid_form}-max-price")
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
          No bids yet. The price starts at <TokenDisplay.price amount={@book.floor} unit={@symbol} />
          per token.
        </p>
        <ol :if={@book.levels.shown != []} role="list">
          <li :if={@book.levels.hidden_above > 0} class="auction-book__more">
            {more(@book.levels.hidden_above, "higher")}
          </li>
          <.level :for={level <- @in_levels} level={level} symbol={@symbol} widest={@widest} />
          <li class="auction-book__now">
            <span>Price now</span>
            <span><TokenDisplay.price amount={@book.clearing} unit={@symbol} /></span>
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
        <li>If the auction doesn't reach its minimum, every bid comes back in full.</li>
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
        <TokenDisplay.price amount={@level.price} />
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
  def standing_label(:in), do: "Buying"
  def standing_label(:sharing), do: "Sharing at the current price"
  def standing_label(:outbid), do: "Outbid"

  attr :price, :any, required: true, doc: "the price everyone pays now"
  attr :unit, :string, required: true, doc: "the currency prices are in"

  attr :back, :atom,
    required: true,
    values: [:now, :price_recorded, :after_end],
    doc: "when the rest of the bid can come back"

  @doc """
  One of the bidder's own bids after the price passed its maximum: it has
  stopped buying, keeps what it bought, and can be bid again or have the rest
  come back.
  """
  def outbid_status(assigns) do
    ~H"""
    <p class="auction-book__outbid">
      <strong>Outbid: no longer buying.</strong>
      You keep what you've bought so far. Bid again above
      <TokenDisplay.price amount={@price} unit={@unit} />
      to keep buying. You can get the rest back {back(@back)}.
    </p>
    """
  end

  attr :bid_form, :string, required: true, doc: "the id of the page's bid form"

  attr :return_to, :string,
    default: nil,
    doc: "the id of the outbid bid, once the auction has reached its minimum"

  @doc "The top of an auction page when one of the signed-in bidder's bids is outbid."
  def outbid_banner(assigns) do
    ~H"""
    <section id="auction-outbid" class="auction-outbid-banner" aria-label="You were outbid">
      <p>
        <strong>You were outbid.</strong>
        The price passed the most your bid pays per token, so it has stopped buying. You keep what it bought so far.
      </p>
      <p class="auction-outbid-banner__links">
        <a href={"##{@bid_form}"}>Bid again</a>
        <a :if={@return_to} href={"##{@return_to}"}>See my outbid bid</a>
      </p>
    </section>
    """
  end

  defp back(:now), do: "now"
  defp back(:price_recorded), do: "once the auction records a price above your bid"
  defp back(:after_end), do: "after bidding ends"

  @doc """
  The same once bidding has ended with the minimum reached: a bid still in at
  the final price won its tokens, and an outbid one is returned for the rest.
  """
  def graduated_bid_status(:in), do: "Won"
  def graduated_bid_status(:outbid), do: "Outbid: return it to get the rest back"
  def graduated_bid_status(standing), do: standing_label(standing)

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
