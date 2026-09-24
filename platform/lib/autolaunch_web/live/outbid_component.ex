defmodule AutolaunchWeb.OutbidComponent do
  @moduledoc """
  One of the signed-in bidder's own bids on a Base auction while bidding is
  open, and what they can do next.

  A bid still buying can be added to. An outbid bid can be bid again at the
  current price, and the money it has not spent can come back early once the
  auction allows it. The auction cannot change a bid, so adding and raising
  both open the one bid form (`BidComponent`) with the old bid's figures
  entered, and each places a new bid with new money. Under an outbid bid, or
  one sharing at the price, `BidSettlementComponent` says when the unspent
  money can come back and offers the early return.

  Hosts pass the auction's price book when they already read it; anywhere
  else the component reads it once.
  """

  use AutolaunchWeb, :live_component

  import AutolaunchWeb.Components.AuctionBook, only: [outbid_status: 1, standing_label: 1]
  import AutolaunchWeb.Components.AutolaunchHelpers, only: [display_status: 1]

  alias Autolaunch.{AuctionBook, BidActions}
  alias AutolaunchWeb.TokenDisplay
  alias Phoenix.LiveView.AsyncResult

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:open, fn -> nil end)
     |> assign_book()}
  end

  @impl true
  def render(assigns) do
    auction = assigns.position.auction

    assigns =
      assign(assigns,
        auction: auction,
        standing: standing(assigns.position, auction, assigns.book)
      )

    ~H"""
    <article id={@id} class="bid-position">
      <p class="bid-position__terms">
        Bid #{@position.onchain_bid_id} ·
        <TokenDisplay.price amount={@position.amount} unit={@auction.quote_token_symbol} /> up to
        <TokenDisplay.price
          amount={@position.max_price}
          unit={"#{@auction.quote_token_symbol} per token"}
        />
      </p>

      <p :if={@standing == :settled} class="bid-position__status">
        {display_status(@position.status)}
      </p>

      <p :if={@standing in [:in, :sharing]} class="bid-position__status">
        {standing_label(@standing)}
      </p>

      <.outbid_status
        :if={@standing == :outbid}
        price={@book.result.clearing}
        unit={@auction.quote_token_symbol}
      />

      <.live_component
        :if={@standing in [:outbid, :sharing]}
        module={AutolaunchWeb.BidSettlementComponent}
        id={"#{@id}-early"}
        position={@position}
        early
        recheck={@book.result.block}
        authenticated={@authenticated}
        current_human_id={@current_human_id}
        session_lease={@session_lease}
      />

      <Regent.Primitives.button
        :if={!@open && @standing == :outbid}
        type="button"
        phx-click="open_bid"
        phx-value-kind="raise"
        phx-target={@myself}
        variant="secondary"
      >
        Raise my bid to keep buying
      </Regent.Primitives.button>

      <Regent.Primitives.button
        :if={!@open && @standing in [:in, :sharing]}
        type="button"
        phx-click="open_bid"
        phx-value-kind="add"
        phx-target={@myself}
        variant="secondary"
      >
        Add to this bid
      </Regent.Primitives.button>

      <div :if={@open} class="bid-position__new">
        <p class="bid-form__note">
          This places a new bid with new money. Your first bid stays as it is.
        </p>
        <.live_component
          module={AutolaunchWeb.BidComponent}
          id={"#{@id}-bid"}
          auction={@auction}
          book={@book}
          heading={heading(@open)}
          preset_amount={if @open == :raise, do: @position.amount}
          preset_limit={if @open == :add, do: @position.max_price}
          authenticated={@authenticated}
          current_human_id={@current_human_id}
          session_lease={@session_lease}
        />
      </div>
    </article>
    """
  end

  @impl true
  def handle_event("open_bid", %{"kind" => "raise"}, socket),
    do: {:noreply, assign(socket, :open, :raise)}

  def handle_event("open_bid", %{"kind" => "add"}, socket),
    do: {:noreply, assign(socket, :open, :add)}

  # A bid that has left the auction, or one whose place cannot be read yet.
  defp standing(%{status: status}, _auction, _book) when status != "active", do: :settled
  defp standing(_position, _auction, %AsyncResult{ok?: false}), do: :reading

  defp standing(position, %{quote_token_decimals: decimals}, %AsyncResult{result: book}) do
    {:ok, price_q96} = BidActions.price_q96(position.max_price, decimals)
    AuctionBook.standing(price_q96, book)
  end

  defp heading(:raise), do: "Raise my bid"
  defp heading(:add), do: "Add to this bid"

  # The auction page hands over the book it already reads; anywhere else the
  # component reads it itself, once.
  defp assign_book(%{assigns: %{book: %AsyncResult{}}} = socket), do: socket

  defp assign_book(%{assigns: %{position: %{auction: auction}}} = socket),
    do:
      assign_async(socket, :book, fn ->
        with {:ok, book} <- AuctionBook.base(auction), do: {:ok, %{book: book}}
      end)
end
