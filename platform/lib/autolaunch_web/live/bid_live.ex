defmodule AutolaunchWeb.BidLive do
  @moduledoc """
  One of the signed-in wallet's bids on its own page, under three headings in
  the account screen's order: what is mine, what may happen next and what it
  cost.

  The page address is the bid's own id: a stored Base bid's (`lab:…`), or a
  Robinhood bid's auction address and the auction's number for it. A Base bid
  is read from the site's records, as the policy allows its owner; a Robinhood
  bid from the chain, among the signed-in wallet's own bids, after the page.

  What is mine is always five rows. What the bid used, did not use and filled
  is what its withdraw stated on the chain (`Autolaunch.BidSettlement`); until
  one is recorded those rows show a dash. What may happen next is one line and
  one place for one button, which offers whatever the portfolio offers for
  the bid: the same withdraw, refund or claim, and while bidding is open, the
  early return of a bid that is outbid or sharing at the price. With nothing
  to press, that place says until when. What it
  cost is one line per transaction the chain watcher recorded, each with its
  explorer link; a withdraw or claim made before the watcher recorded them
  keeps its line in words, its link's place empty.
  """

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers,
    only: [human_actor: 1, current_human_id: 1, signed_in_wallet: 1, display_time: 1]

  import AutolaunchWeb.Components.MarketCard, only: [auction_status: 1]
  import AutolaunchWeb.Components.SwapModal

  alias Autolaunch.AuctionBook
  alias Autolaunch.MarketReadings
  alias Autolaunch.Robinhood.Positions, as: RobinhoodPositions
  alias Autolaunch.Stocks.Amounts
  alias Autolaunch.Token
  alias AutolaunchWeb.Components.AuctionBook, as: AuctionBookComponent
  alias AutolaunchWeb.Components.BidPlaced

  alias AutolaunchWeb.{
    BidSettlementComponent,
    LabMarket,
    LiveListings,
    Paths,
    RobinhoodStockBidComponent,
    TokenDisplay
  }

  alias Phoenix.LiveView.AsyncResult

  @robinhood_id ~r/\A(0x[0-9a-f]{40}):(\d{1,78})\z/

  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(AutolaunchWeb.PublicDocuments.page(:bid))
     |> assign(id: id, dialog: nil, queued?: false, bid: %AsyncResult{}, book: %AsyncResult{})
     |> LabMarket.subscribe_heads()
     |> LiveListings.subscribe()
     |> read()}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("open_settlement", _params, socket),
    do: {:noreply, assign(socket, :dialog, :settle)}

  def handle_event("open_early", _params, socket),
    do: {:noreply, assign(socket, :dialog, :early)}

  def handle_event("close_trade", _params, socket), do: {:noreply, assign(socket, :dialog, nil)}

  # The bid's auction saved a change: a new withdraw or claim, or its state.
  def handle_info({:autolaunch_listings_changed, auction_id}, socket) do
    if auction_id == auction_id(socket.assigns.bid.result),
      do: {:noreply, LiveListings.schedule(socket)},
      else: {:noreply, socket}
  end

  def handle_info(:reread_listings, socket),
    do: {:noreply, socket |> LiveListings.taken() |> request_read()}

  # A market feed stored readings at a new block: the bid may have become
  # returnable or claimable.
  def handle_info({:shared_reading, {:market_head, _feed}}, socket),
    do: {:noreply, request_read(socket)}

  def handle_info({:bid_settlement_changed, _position_id}, socket),
    do: {:noreply, request_read(socket)}

  # The Robinhood bid dialog tells its page about its form; this page has none.
  def handle_info({message, _value}, socket)
      when message in [:bid_draft_price, :robinhood_outbid],
      do: {:noreply, socket}

  def handle_async(:robinhood, {:ok, result}, socket),
    do: {:noreply, socket |> shown(result) |> read_queued()}

  def handle_async(:book, {:ok, {:ok, book}}, socket),
    do: {:noreply, assign(socket, :book, AsyncResult.ok(socket.assigns.book, book))}

  def handle_async(:book, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, :book, AsyncResult.failed(socket.assigns.book, reason))}

  def handle_async(:book, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :book, AsyncResult.failed(socket.assigns.book, reason))}

  def handle_async(:robinhood, {:exit, reason}, socket),
    do:
      {:noreply,
       socket |> assign(:bid, AsyncResult.failed(socket.assigns.bid, reason)) |> read_queued()}

  def render(assigns) do
    assigns =
      assign(assigns,
        signed_in?: assigns.account_control.kind == :signed_in,
        human_id: current_human_id(assigns.access_context)
      )

    ~H"""
    <section id="autolaunch-bid" class="bid-page">
      <.link navigate="/portfolio" class="bid-page__back">Portfolio</.link>

      <section :if={@account_control.kind == :sign_in} class="rg-account rg-account--signed-out">
        <p>Sign in to see your bid.</p>
        <Regent.Primitives.button
          type="button"
          class="account-control__sign-in"
          data-account-target="sign-in"
        >Sign in</Regent.Primitives.button>
      </section>

      <%= if @account_control.kind != :sign_in do %>
        <p :if={@bid.loading && is_nil(@bid.result)} class="bid-page__note" role="status">
          Reading your bid…
        </p>
        <p :if={@bid.failed && is_nil(@bid.result)} class="bid-page__note" role="alert">
          Your bid could not be read just now. Try again in a moment.
        </p>
        <p :if={@bid.ok? && @bid.result == :missing} class="bid-page__note">
          The wallet you signed in with has no bid here.
        </p>
        <.bid
          :if={is_map(@bid.result)}
          bid={@bid.result}
          book={@book}
          dialog={@dialog}
          signed_in?={@signed_in?}
          human_id={@human_id}
          session_lease={@session_lease}
        />
      <% end %>
    </section>
    """
  end

  attr :bid, :map, required: true
  attr :book, AsyncResult, required: true, doc: "the price book of a Base bid's open auction"
  attr :dialog, :atom, default: nil
  attr :signed_in?, :boolean, required: true
  attr :human_id, :integer, default: nil
  attr :session_lease, :any, required: true

  defp bid(assigns) do
    bid = assigns.bid
    {line, slot} = next(bid, assigns.book)
    assigns = assign(assigns, mine: mine(bid), line: line, slot: slot, costs: costs(bid))

    ~H"""
    <header class="bid-page__header">
      <span class="market-list__art">
        <img :if={@bid.image} src={@bid.image} alt="" />
        <span :if={!@bid.image}>{String.first(@bid.name)}</span>
      </span>
      <div>
        <h1>Your bid on {@bid.name}</h1>
        <p class="bid-page__note">
          {@bid.chain_name} · <.link :if={@bid.path} navigate={@bid.path}>{@bid.symbol}</.link>
          <span :if={!@bid.path}>{@bid.symbol}</span>
        </p>
      </div>
      <div :if={@bid.listing} class="bid-page__status">
        <.auction_status id="bid-page-time" auction={@bid.listing} />
      </div>
    </header>

    <section class="rg-account" aria-labelledby="bid-mine-title">
      <h2 id="bid-mine-title">What is mine</h2>
      <dl class="rg-account__metrics bid-page__mine">
        <div :for={{label, figure, detail} <- @mine}>
          <dt>{label}</dt>
          <dd>{figure}</dd>
          <dd class="bid-page__detail">{detail}</dd>
        </div>
      </dl>
    </section>

    <section class="rg-account" aria-labelledby="bid-next-title">
      <h2 id="bid-next-title">What may happen next</h2>
      <p class="bid-page__line">{@line}</p>
      <div class="bid-page__slot">
        <Regent.Primitives.button :if={match?({:press, _}, @slot)} phx-click="open_settlement">
          {elem(@slot, 1)}
        </Regent.Primitives.button>
        <Regent.Primitives.button :if={@slot == :early_dialog} phx-click="open_early">
          Withdraw
        </Regent.Primitives.button>
        <.live_component
          :if={@slot == :early_return}
          module={BidSettlementComponent}
          id={"bid-early-#{@bid.position.id}"}
          early
          position={@bid.position}
          authenticated={@signed_in?}
          current_human_id={@human_id}
          session_lease={@session_lease}
        />
        <p :if={match?({:wait, _}, @slot)} class="bid-page__note">{elem(@slot, 1)}</p>
      </div>
    </section>

    <section class="rg-account" aria-labelledby="bid-cost-title">
      <h2 id="bid-cost-title">What it cost</h2>
      <ul class="rg-account__history">
        <li :for={cost <- @costs}>
          <p>{cost.words}</p>
          <span class="bid-page__link">
            <a
              :if={cost.hash}
              href={BidPlaced.transaction_url(@bid.chain, cost.hash)}
              target="_blank"
              rel="noopener noreferrer"
            >
              {BidPlaced.explorer(@bid.chain)}
            </a>
          </span>
          <span class="rg-account__when">{cost.when}</span>
        </li>
      </ul>
    </section>

    <.dialog
      :if={@dialog}
      kind={@dialog}
      bid={@bid}
      signed_in?={@signed_in?}
      human_id={@human_id}
      session_lease={@session_lease}
    />
    """
  end

  attr :kind, :atom, required: true, doc: ":settle, or :early for a Robinhood bid's early return"
  attr :bid, :map, required: true
  attr :signed_in?, :boolean, required: true
  attr :human_id, :integer, default: nil
  attr :session_lease, :any, required: true

  defp dialog(%{bid: %{chain: :base}} = assigns) do
    ~H"""
    <.settlement_modal
      id={"bid-settle-#{@bid.position.id}"}
      position={@bid.position}
      market={MarketReadings.market(@bid.position.auction_address)}
      authenticated={@signed_in?}
      current_human_id={@human_id}
      session_lease={@session_lease}
    />
    """
  end

  defp dialog(%{bid: %{chain: :robinhood, listing: listing}} = assigns) do
    assigns =
      assign(assigns,
        listing: listing,
        stake_path: if(assigns.bid.position.token, do: Paths.token_stake(listing))
      )

    ~H"""
    <.robinhood_bid_modal
      id={"bid-#{@kind}-#{@listing.id}"}
      auction={@listing}
      ended={if @kind == :settle, do: RobinhoodStockBidComponent.ended_copy(@listing)}
      stake_path={@stake_path}
      authenticated={@signed_in?}
      current_human_id={@human_id}
      session_lease={@session_lease}
    />
    """
  end

  # Five rows, always: what went in, what the auction used and for how many
  # tokens at what price each, what it did not use, the bid's ceiling, and
  # the tokens it filled. The withdraw states the three it settles.
  defp mine(bid) do
    exit = Enum.find(bid.settlements, &(&1.kind == :exit))
    used = exit && Decimal.max(Decimal.sub(bid.put_in, exit.currency), Decimal.new(0))

    [
      {"Put in", figure(bid.put_in, bid.unit), nil},
      {"Used", used && figure(used, bid.unit), used && average(used, exit.tokens, bid)},
      {"Not used", exit && figure(exit.currency, bid.unit), nil},
      {"Your max price", figure(bid.max_price, bid.unit), "per token"},
      {"Tokens", exit && tokens(exit.tokens, bid.symbol), nil}
    ]
    |> Enum.map(fn {label, figure, detail} -> {label, figure || "-", detail} end)
  end

  defp average(used, tokens, bid) do
    if Decimal.gt?(tokens, 0),
      do: "#{tokens(tokens, bid.symbol)} at #{figure(Decimal.div(used, tokens), bid.unit)} each"
  end

  defp figure(amount, unit),
    do:
      "#{amount |> Decimal.to_string(:normal) |> TokenDisplay.short() |> TokenDisplay.zeros()} #{unit}"

  defp tokens(amount, symbol),
    do:
      "#{amount |> Decimal.to_string(:normal) |> TokenDisplay.short(:down) |> Amounts.grouped()} #{symbol}"

  # One line, then the button that settles the bid, or until when there is
  # nothing to press.
  defp next(%{chain: :base, position: position, listing: auction} = bid, book) do
    case position.status do
      "active" when auction.state == :active -> open(position, auction, book)
      "active" -> {"Bidding has ended.", {:wait, "Nothing to do until the auction settles"}}
      "returnable" -> settle(bid, auction.state, BidSettlementComponent.spent?(position))
      "claimable" -> {"Your tokens are ready to claim.", {:press, claim(bid)}}
      "returned" when position.tokens_filled not in [nil, "", "0"] -> claims_later()
      _settled -> settled()
    end
  end

  defp next(%{chain: :robinhood, listing: nil}, _book),
    do: {"This auction is not listed on this site.", {:wait, "Nothing to do here"}}

  defp next(%{chain: :robinhood, position: position, listing: listing} = bid, _book) do
    case position.standing do
      :in ->
        buying(listing)

      standing when standing in [:sharing, :outbid] ->
        {AuctionBookComponent.standing_label(standing), :early_dialog}

      :ended ->
        {"Bidding has ended.", {:wait, "Nothing to do until the launch finishes"}}

      :refundable ->
        settle(
          %{bid | put_in: Decimal.new(position.refundable, max_digits: :infinity)},
          :failed,
          false
        )

      :graduated ->
        settle(bid, :graduated, false)

      :filled ->
        claims_later()

      :claimable ->
        {"Your tokens are ready to claim.", {:press, claim(bid)}}

      _settled ->
        settled()
    end
  end

  # An open Base bid against the auction's price, as the portfolio reads it:
  # one that is buying waits for the end; one that is outbid or sharing at the
  # price has its early return, which says itself when the money can come
  # back. Until the price is read the place says so; if it cannot be read,
  # the early return is offered and asks the auction itself.
  defp open(position, auction, book) do
    case book do
      %{ok?: true, result: book} ->
        case AuctionBook.bid_standing(position, auction, book) do
          :in -> buying(auction)
          standing -> {AuctionBookComponent.standing_label(standing), :early_return}
        end

      %{failed: failed} when failed not in [nil, false] ->
        {"Bidding is open.", :early_return}

      _reading ->
        {"Bidding is open.", {:wait, "Reading the auction's price…"}}
    end
  end

  defp buying(auction),
    do:
      {AuctionBookComponent.standing_label(:in),
       {:wait, "Nothing to do until #{display_time(auction.estimated_end_at)}"}}

  defp settle(bid, :failed, _spent?),
    do:
      {"The auction did not reach its minimum.",
       {:press,
        BidSettlementComponent.refund_label(Decimal.to_string(bid.put_in, :normal), bid.unit)}}

  defp settle(bid, _state, true), do: {"The auction has settled.", {:press, claim(bid)}}

  defp settle(bid, _state, false),
    do: {"The auction has settled.", {:press, "Withdraw unspent #{bid.unit}"}}

  defp claims_later,
    do: {"Your tokens cannot be claimed yet.", {:wait, "Nothing to do until claims open"}}

  defp settled, do: {"This bid is settled.", {:wait, "Nothing left to do"}}

  defp claim(bid) do
    case Enum.find(bid.settlements, &(&1.kind == :exit)) do
      %{tokens: tokens} -> "Claim #{tokens(tokens, bid.symbol)}"
      nil -> "Claim #{bid.symbol}"
    end
  end

  # The bid, then each withdraw and claim the chain watcher recorded, oldest
  # first. A withdraw or claim the bid shows but the watcher has not recorded
  # keeps its line without a link.
  defp costs(bid) do
    placed =
      case bid.placed do
        %{} = placed ->
          %{
            words: "Bid #{figure(placed.display_amount, placed.display_symbol)}",
            hash: placed.transaction_hash,
            when: display_time(placed.occurred_at)
          }

        nil ->
          %{words: "Bid #{figure(bid.put_in, bid.unit)}", hash: nil, when: nil}
      end

    recorded = Enum.map(bid.settlements, &settlement(&1, bid))
    kinds = Enum.map(bid.settlements, & &1.kind)

    unrecorded =
      for {kind, words} <- [exit: exited(bid), claim: "Claimed"],
          kind in bid.done and kind not in kinds,
          do: %{words: words, hash: nil, when: nil}

    [placed | recorded ++ unrecorded]
  end

  # A failed auction's bids come back whole: a refund, not a withdraw.
  defp exited(%{listing: %{state: :failed}}), do: "Refunded"
  defp exited(_bid), do: "Withdrawn"

  defp settlement(%{kind: :exit} = row, bid) do
    verb = if exited(bid) == "Refunded", do: "Refunded", else: "Withdrew"

    filled =
      if Decimal.gt?(row.tokens, 0), do: ", #{tokens(row.tokens, bid.symbol)} filled", else: ""

    %{
      words: "#{verb} #{figure(row.currency, bid.unit)}#{filled}",
      hash: row.transaction_hash,
      when: display_time(row.occurred_at)
    }
  end

  defp settlement(%{kind: :claim} = row, bid),
    do: %{
      words: "Claimed #{tokens(row.tokens, bid.symbol)}",
      hash: row.transaction_hash,
      when: display_time(row.occurred_at)
    }

  defp auction_id(%{listing: %{id: id}}), do: id
  defp auction_id(_bid), do: nil

  # The bid as the signed-in session may see it. A Base bid is read now, from
  # the site's records; a Robinhood one from the chain, after the page.
  defp read(socket) do
    actor = human_actor(socket.assigns.access_context)
    wallet = signed_in_wallet(socket.assigns.access_context)

    case {actor, parse(socket.assigns.id)} do
      {nil, _id} ->
        socket

      {_actor, :error} ->
        shown(socket, {:ok, :missing})

      {actor, {:base, bid_id}} ->
        socket |> shown(base(bid_id, actor)) |> read_book()

      {_actor, {:robinhood, auction, bid_id}} ->
        socket
        |> assign(:bid, AsyncResult.loading(socket.assigns.bid))
        |> read_robinhood(wallet, auction, bid_id)
    end
  end

  defp read_robinhood(socket, wallet, auction, bid_id) do
    if connected?(socket),
      do: start_async(socket, :robinhood, fn -> robinhood(wallet, auction, bid_id) end),
      else: socket
  end

  # The price book of an open Base bid's auction, after the page; a new read
  # keeps the last book on screen until it lands.
  defp read_book(
         %{assigns: %{bid: %{result: %{position: %{status: "active"}, listing: auction}}}} =
           socket
       )
       when auction.state == :active do
    if connected?(socket),
      do:
        socket
        |> assign(:book, AsyncResult.loading(socket.assigns.book))
        |> start_async(:book, fn -> AuctionBook.base(auction) end),
      else: socket
  end

  defp read_book(socket), do: socket

  defp request_read(socket) do
    if socket.assigns.bid.loading,
      do: assign(socket, :queued?, true),
      else: read(socket)
  end

  defp read_queued(%{assigns: %{queued?: true}} = socket),
    do: socket |> assign(:queued?, false) |> read()

  defp read_queued(socket), do: socket

  defp shown(socket, {:ok, bid}),
    do: assign(socket, :bid, AsyncResult.ok(socket.assigns.bid, bid))

  defp shown(socket, {:error, reason}),
    do: assign(socket, :bid, AsyncResult.failed(socket.assigns.bid, reason))

  defp parse("lab:" <> _rest = id), do: {:base, id}

  defp parse(id) do
    case Regex.run(@robinhood_id, id) do
      [_id, auction, bid_id] -> {:robinhood, auction, bid_id}
      nil -> :error
    end
  end

  defp base(bid_id, actor) do
    case Autolaunch.get_my_bid_position(bid_id, actor: actor, not_found_error?: false) do
      {:ok, nil} ->
        {:ok, :missing}

      {:ok, position} ->
        auction = position.auction

        with {:ok, stored} <- stored(auction.id, position.onchain_bid_id) do
          {:ok,
           Map.merge(stored, %{
             chain: :base,
             chain_name: "Base",
             position: position,
             listing: auction,
             name: auction.title,
             symbol: auction.token_symbol,
             unit: auction.quote_token_symbol,
             image: auction.image,
             path:
               if(match?(%Token{}, position.token),
                 do: Paths.token(auction),
                 else: Paths.auction(auction)
               ),
             put_in: Decimal.new(position.amount, max_digits: :infinity),
             max_price: Decimal.new(position.max_price, max_digits: :infinity),
             done:
               done(
                 position.status in ~w(claimable returned claimed),
                 position.status == "claimed"
               )
           })}
        end

      {:error, %Ash.Error.Invalid{}} ->
        {:ok, :missing}

      error ->
        error
    end
  end

  defp robinhood(wallet, auction, bid_id) do
    with {:ok, positions} <- RobinhoodPositions.read_wallet(wallet) do
      case Enum.find(positions, &(&1.auction == auction and &1.bid_id == bid_id)) do
        nil -> {:ok, :missing}
        position -> robinhood_bid(position)
      end
    end
  end

  defp robinhood_bid(position) do
    listing = position.listing

    with {:ok, stored} <- stored(listing && listing.id, position.bid_id) do
      {:ok,
       Map.merge(stored, %{
         chain: :robinhood,
         chain_name: "Robinhood",
         position: position,
         listing: listing,
         name: position.name,
         symbol: position.symbol,
         unit: position.stock_symbol,
         image: position.image,
         path: robinhood_path(position),
         put_in: Decimal.new(position.committed, max_digits: :infinity),
         max_price: Decimal.new(position.max_price, max_digits: :infinity),
         done:
           done(
             position.standing in [:filled, :claimable, :returned, :claimed],
             position.standing == :claimed
           )
       })}
    end
  end

  # Which of a withdraw and a claim the bid has had, by its own standing.
  defp done(exited?, claimed?),
    do: for({kind, true} <- [exit: exited?, claim: claimed?], do: kind)

  defp robinhood_path(%{listing: %{hidden: true}}), do: nil
  defp robinhood_path(%{token: %Token{}, listing: listing}), do: Paths.token(listing)
  defp robinhood_path(%{listing: %{} = listing}), do: Paths.auction(listing)
  defp robinhood_path(_position), do: nil

  # The bid's own transaction and its withdraws and claims, as the chain
  # watcher recorded them for its auction.
  defp stored(nil, _bid_id), do: {:ok, %{placed: nil, settlements: []}}
  defp stored(_auction_id, nil), do: {:ok, %{placed: nil, settlements: []}}

  defp stored(auction_id, bid_id) do
    with {:ok, placed} <- Autolaunch.auction_bid(auction_id, bid_id),
         {:ok, settlements} <- Autolaunch.bid_settlements(auction_id, bid_id),
         do: {:ok, %{placed: placed, settlements: settlements}}
  end
end
