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

  alias Autolaunch.Stocks.Amounts
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
            |> JS.focus(to: "##{@bid_form}-max-fdv")
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
        <li>
          You set a max budget (analogy to swaps: how much you are trading) and a max price you'll pay per token (analogy: buy a little every block, but stop when the FDV is higher than your limit).
        </li>
        <li>
          Your budget is spent a little every block. Every bidder pays the same price per block.
        </li>
        <li>
          If the price passes your maximum, you stop buying and the remainder of your budget can be withdrawn.
        </li>
        <li>If the auction doesn't reach the minimum set by the creator, every bid is returned.</li>
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

  @doc """
  One of the bidder's own bids after the price passed its maximum: it has
  stopped buying, keeps what it bought, and can be bid again. When the rest
  can come back is `return_line/1`'s, read from the auction.
  """
  def outbid_status(assigns) do
    ~H"""
    <p class="auction-book__outbid">
      <strong>Outbid: no longer buying.</strong>
      You keep what you've bought so far. Bid again above
      <TokenDisplay.price amount={@price} unit={@unit} /> to keep buying.
    </p>
    """
  end

  attr :id, :string, required: true

  attr :status, :any,
    required: true,
    doc:
      "`:now`, `:record`, `:buying`, or `{:minimum, still_needed}` with the amount as a plain decimal"

  attr :unit, :string, required: true, doc: "the currency the bid is in"
  attr :usd_rate, :any, required: true, doc: "the USD price of one unit, or nil"
  attr :ends_at, :any, required: true, doc: "when bidding is expected to end, or nil"

  @doc """
  The one line under a bidder's own bid saying when its unspent money can come
  back, from the auction's own answer: now; once the auction reaches its
  minimum or after it ends; after one more wallet confirmation that records
  the new price; or, for a bid whose limit equals the price, after it ends.
  The end time shows in the viewer's own time zone.
  """
  def return_line(%{status: :now} = assigns) do
    ~H"""
    <p id={@id} class="auction-book__back">Your unspent money can come back now.</p>
    """
  end

  def return_line(%{status: {:minimum, missing}} = assigns) do
    assigns = assign(assigns, missing: missing, shown: shortfall(missing))

    ~H"""
    <p id={@id} class="auction-book__back">
      Your money can come back once the auction reaches its minimum
      (<TokenDisplay.price amount={@shown} unit={@unit} />
      <UsdValue.usd
        amount={@missing}
        rate={@usd_rate}
      /> to go), or after it ends<.ends_at id={@id} at={@ends_at} />.
    </p>
    """
  end

  def return_line(%{status: :record} = assigns) do
    ~H"""
    <p id={@id} class="auction-book__back">
      The price has passed your limit. Withdrawing first records the new price on the auction (one extra wallet confirmation).
    </p>
    """
  end

  def return_line(%{status: :buying} = assigns) do
    ~H"""
    <p id={@id} class="auction-book__back">
      Your limit equals the current price, so your bid is still buying. Your money can come back after the auction ends<.ends_at
        id={@id}
        at={@ends_at}
      />.
    </p>
    """
  end

  # As the raise progress shows what is still needed: whole and grouped from
  # 1,000 up, rounded up so the line never shows less than is missing.
  defp shortfall(missing) do
    decimal = Decimal.new(missing)

    if Decimal.gte?(decimal, 1000),
      do:
        decimal |> Decimal.round(0, :ceiling) |> Decimal.to_string(:normal) |> Amounts.grouped(),
      else: Decimal.to_string(decimal, :normal)
  end

  attr :id, :string, required: true
  attr :at, :any, required: true

  # " at <time>", in the viewer's own time zone once the page is live; nothing
  # while the end time is not known yet. The hook comes first so no space is
  # left between the time and the sentence's full stop.
  defp ends_at(%{at: nil} = assigns), do: ~H""

  defp ends_at(assigns) do
    ~H"""
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
      export default {
        mounted() { this.show() },
        updated() { this.show() },
        show() {
          this.el.textContent = new Date(this.el.dateTime).toLocaleString([], {
            weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit"
          })
        }
      }
    </script>
    {" at "}<time
      id={"#{@id}-end"}
      phx-hook=".LocalTime"
      datetime={DateTime.to_iso8601(@at)}
    >{Calendar.strftime(@at, "%a %b %-d, %H:%M UTC")}</time>
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
