defmodule AutolaunchWeb.Components.AuctionBook do
  @moduledoc """
  The words for a bidder's own bid against the price now: buying, sharing at
  the price or outbid; when its unspent money can come back; and the banner
  at the top of an auction page when one of the bidder's bids is outbid.
  """
  use Phoenix.Component

  alias Autolaunch.Stocks.Amounts
  alias AutolaunchWeb.{TokenDisplay, UsdValue}

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
end
