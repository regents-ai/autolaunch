defmodule AutolaunchWeb.CoveredCallsLive do
  @moduledoc """
  `/stock/covered-call`: covered calls on a Base stock as a trade ticket, in two tabs
  with an address each.

  **Sell**, first and at `/stock/covered-call`, takes an amount, one of the next four
  Fridays, a strike (three suggestions or a custom price) and a premium (the
  suggestion, or typed). Beside it a receipt and the three ways the listing can end
  follow the ticket as it changes. Every figure comes from the market's quote
  (`Autolaunch.CoveredCalls.covered_call_quote/3`), read again on each change; a
  receipt shows only once the quote answers for exactly what the ticket holds.
  Under it, while any are open, the bids buyers have posted; a bid's Sell now
  ticket opens below them at `?bid=<id>`: the amount, what the sale pays now (the
  prepared step's own figures, read at the latest block) and how it can end.
  A link to a bid or listing the shared reading does not list (dust, an
  expiry the site does not offer, outside the best fifty) reads that one from
  the chain and opens the same ticket while it is open there; otherwise a
  line says, from the chain, why there is none.

  **Buy** (`?tab=buy`, with how many are for sale) lists the calls for sale, and a
  listing's ticket opens below the list at `?listing=<id>`: the amount, what it costs
  and the three ways it can end, counted by `Autolaunch.CoveredCalls.Terms`. Its
  switch's other side, **Bid** (`?tab=bid`), posts a bid for calls on the Sell
  ticket's terms: what the contract holds for it and how the calls can end.

  Each ticket opens on the stock's last 30 days of reference prices with its
  strike drawn across them (when buying or bidding, the break-even too), from the
  line every open page shares (`Autolaunch.CoveredCalls.PriceLine`).

  The page owns each ticket's fields; every press goes to the wallet through
  `AutolaunchWeb.CoveredCallComponent`, handed the ticket's order as it stands.

  Every ticket names its stock by issuer, chain and address under its title,
  and says in plain sight what the contract does: a seller is paid when a buyer
  buys, sold stock stays locked until the window closes, and only the buyer
  can exercise, by their own transaction inside the window. Beside My calls, a
  signed-in holder whose window is open or opens within three days reads when
  it closes, from the wallet reading the open ticket's panel makes.

  With covered calls switched off the address is the site's 404.
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [current_human_id: 1]

  alias Autolaunch.CoveredCalls
  alias Autolaunch.CoveredCalls.{Book, Chain, Deployment, PriceLine, Quote, Terms}
  alias Autolaunch.SharedReading
  alias AutolaunchWeb.Components.{BidPlaced, PriceChart}
  alias AutolaunchWeb.CoveredCallComponent
  alias AutolaunchWeb.CoveredCallsFormat, as: F
  alias AutolaunchWeb.{NotFoundError, Read}
  alias Phoenix.LiveView.{AsyncResult, JS}
  alias Regent.Primitives, as: P

  # A new Sell or Bid ticket: no amount yet, the next Friday, the middle
  # suggested strike (the quote's own choice when none is asked) and the
  # suggested premium.
  @ticket %{"amount" => "", "expiry" => nil, "strike" => "1", "custom" => "", "premium" => nil}
  @presets ~w(0 1 2)

  def mount(_params, _session, socket) do
    with true <- Deployment.enabled?(),
         {:ok, %{chain_id: chain_id, markets: [market | _]}} <- Deployment.current() do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Autolaunch.PubSub, topic(market))
        SharedReading.subscribe(PriceLine.key(market.symbol))
      end

      {:ok,
       socket
       |> assign(AutolaunchWeb.PublicDocuments.page("/stock/covered-call"))
       |> assign(
         share:
           if(connected?(socket),
             do: nil,
             else: AutolaunchWeb.ShareCard.market_meta(:covered_calls, market.symbol)
           )
       )
       |> assign(
         market: market,
         chain_id: chain_id,
         book: AsyncResult.loading(),
         quote: %Read{},
         tab: :sell,
         selected: nil,
         bid: nil,
         linked: nil,
         done: nil,
         due: nil,
         fields: %{sell: @ticket, bid: @ticket},
         balance: nil,
         exercise_by: nil,
         buy: nil,
         sale: "",
         line: PriceLine.line(market.symbol)
       )
       |> read_book()}
    else
      _off -> raise NotFoundError
    end
  end

  def handle_params(params, _uri, socket) do
    selected = chosen(params["listing"])

    {:noreply,
     socket
     |> assign(tab: tab(params["tab"], selected), selected: selected, bid: chosen(params["bid"]))
     |> opened(socket.assigns)
     |> forget_balance()
     |> read_quote()
     |> reread()}
  end

  # The Refresh press asks every reader of the chain to read again, so the
  # shared book is taken anew unless it was taken in the last ten seconds.
  def handle_event("refresh", _params, socket) do
    Autolaunch.ChainRefresh.request(socket.assigns.chain_id)
    {:noreply, read_book(socket)}
  end

  def handle_event("dismiss_done", _params, socket), do: {:noreply, assign(socket, done: nil)}

  # The Sell and Bid tickets' fields, each event named for its ticket.
  def handle_event("sell" <> event, params, socket),
    do: {:noreply, edit(socket, :sell, event, params)}

  def handle_event("bid" <> event, params, socket),
    do: {:noreply, edit(socket, :bid, event, params)}

  def handle_event("buy", %{"amount" => amount}, socket),
    do: {:noreply, assign(socket, buy: amount)}

  def handle_event("sale", %{"amount" => amount}, socket),
    do: {:noreply, assign(socket, sale: amount)}

  # The Buy tab's switch between buying a listing and posting a bid.
  def handle_event("mode", %{"mode" => mode}, socket) when mode in ~w(buy bid),
    do: {:noreply, push_patch(socket, to: ~p"/stock/covered-call?tab=#{mode}")}

  # A press landed here: every open page of this market hears which listing
  # and wallet.
  def handle_info({:covered_calls_changed, symbol, press}, socket) do
    Phoenix.PubSub.broadcast(
      Autolaunch.PubSub,
      "covered_calls:" <> symbol,
      {:covered_call_pressed, press}
    )

    {:noreply, socket}
  end

  def handle_info({:covered_call_pressed, _press}, socket), do: {:noreply, read_book(socket)}

  # The open ticket's panel read the signed-in wallet: its stock, for Max, and
  # when the window closes on calls it holds.
  def handle_info({:covered_call_wallet, _symbol, nil}, socket),
    do: {:noreply, assign(socket, balance: nil, exercise_by: nil)}

  def handle_info({:covered_call_wallet, _symbol, wallet}, socket),
    do: {:noreply, assign(socket, balance: wallet.balance, exercise_by: wallet.exercise_by)}

  def handle_info({:shared_reading, _price_history}, socket),
    do: {:noreply, assign(socket, line: PriceLine.line(socket.assigns.market.symbol))}

  # A listing's or bid's expiry or a scheduled multiplier change came: the shared book
  # is taken anew unless it was taken in the last ten seconds, and the page
  # and its panels read it, so a button the chain held back comes back.
  def handle_info(:covered_calls_due, socket) do
    Book.refresh(socket.assigns.chain_id)
    {:noreply, read_book(socket)}
  end

  # A panel's last step landed; the page says what moved, and a listing or bid
  # made leaves its ticket ready for the next one on the same terms.
  def handle_info({:covered_call_done, done}, socket) do
    socket =
      case done.kind do
        :list -> put_field(socket, :sell, "amount", "")
        :bid -> put_field(socket, :bid, "amount", "")
        :fill -> assign(socket, buy: nil)
        :sell_to_bid -> assign(socket, sale: "")
        _other -> socket
      end

    {:noreply, assign(socket, done: done)}
  end

  def handle_async(:book, {:ok, {:ok, book}}, socket) do
    if socket.assigns.due, do: Process.cancel_timer(socket.assigns.due)

    open = Enum.map(book.listings ++ book.bids, & &1.expiry)
    wait = Terms.next_wait([book.effective_at | open], book.now)

    {:noreply,
     socket
     |> assign(
       book: AsyncResult.ok(socket.assigns.book, book),
       due: wait && Process.send_after(self(), :covered_calls_due, (wait + 5) * 1_000)
     )
     |> read_quote()
     |> read_linked()}
  end

  def handle_async(:book, {:ok, {:error, error}}, socket),
    do:
      {:noreply,
       assign(socket, book: AsyncResult.failed(socket.assigns.book, CoveredCalls.reason(error)))}

  def handle_async(:book, {:exit, reason}, socket),
    do: {:noreply, assign(socket, book: AsyncResult.failed(socket.assigns.book, reason))}

  # The one listing or bid a link names, read from the chain, kept only while
  # the link still names it.
  def handle_async(:linked, {:ok, {kind, id, result}}, socket) do
    answer =
      case result do
        {:ok, offer} -> {:ok, offer}
        {:error, error} -> {:error, CoveredCalls.reason(error)}
      end

    {:noreply, linked(socket, kind, id, answer)}
  end

  def handle_async(:linked, {:exit, _reason}, %{assigns: %{linked: linked}} = socket)
      when is_map(linked),
      do: {:noreply, linked(socket, linked.kind, linked.id, {:error, :chain_unavailable})}

  def handle_async(:linked, {:exit, _reason}, socket), do: {:noreply, socket}

  # A quote that answered for other strikes than the ticket now names (the
  # reference price moved, and the suggestions with it) is read again for them.
  def handle_async({Read, :quote, _generation} = name, result, socket) do
    socket = Read.settle(socket, name, result)
    %{quote: quote, fields: fields, book: book, tab: tab} = socket.assigns

    if tab in [:sell, :bid] and quote.state == :ready and
         !answers?(quote.value, request(ticket(fields[tab], book.result, quote.value))),
       do: {:noreply, read_quote(socket)},
       else: {:noreply, socket}
  end

  # A ticket's figures as they are typed or chosen. The premium follows the
  # suggestion until it is typed in itself, and Custom starts from the strike
  # chosen before it, to change from there.
  defp edit(socket, key, "", params) do
    fields = socket.assigns.fields[key]
    premium = if params["_target"] == ["premium"], do: params["premium"], else: fields["premium"]

    fields =
      fields |> Map.merge(Map.take(params, ~w(amount custom))) |> Map.put("premium", premium)

    put_fields(socket, key, fields)
  end

  defp edit(socket, key, "_expiry", %{"expiry" => expiry}),
    do: put_field(socket, key, "expiry", expiry)

  defp edit(socket, key, "_strike", %{"strike" => choice}) when choice in ["custom" | @presets] do
    %{fields: %{^key => fields}, book: book, quote: quote} = socket.assigns
    ticket = ticket(fields, book.result, quote.value)

    custom =
      if choice == "custom" and fields["custom"] == "" and ticket.strike,
        do: F.plain_usd(ticket.strike),
        else: fields["custom"]

    put_fields(socket, key, %{fields | "strike" => choice, "custom" => custom})
  end

  defp edit(socket, key, "_suggested", _params), do: put_field(socket, key, "premium", nil)

  defp put_field(socket, key, name, value),
    do: put_fields(socket, key, Map.put(socket.assigns.fields[key], name, value))

  defp put_fields(socket, key, fields),
    do: socket |> update(:fields, &Map.put(&1, key, fields)) |> read_quote()

  # The listing or bid a ticket's address names: its number, nil for none, or
  # `:unknown` for one that isn't a number the contract can have.
  defp chosen(nil), do: nil

  defp chosen(text) when is_binary(text) do
    case Integer.parse(text) do
      {id, ""} when id > 0 -> id
      _not_a_number -> :unknown
    end
  end

  defp chosen(_not_text), do: :unknown

  # Selling comes first, a bid's own address with it; a listing's own address
  # opens it on the Buy tab.
  defp tab("buy", _selected), do: :buy
  defp tab("bid", _selected), do: :bid
  defp tab(_tab, nil), do: :sell
  defp tab(_tab, _selected), do: :buy

  # Another listing's ticket starts at all that is left of it, another bid's
  # with no amount.
  defp opened(socket, %{selected: selected, bid: bid}) do
    %{selected: now_selected, bid: now_bid, buy: buy, sale: sale} = socket.assigns

    assign(socket,
      buy: if(now_selected == selected, do: buy),
      sale: if(now_bid == bid, do: sale, else: "")
    )
  end

  # The wallet's stock is for the Sell tickets' Max, so it is read anew each
  # time one opens.
  defp forget_balance(%{assigns: %{tab: :sell}} = socket), do: socket
  defp forget_balance(socket), do: assign(socket, balance: nil)

  # A shared link to one listing or bid reads the market again unless it was
  # read in the last ten seconds, so it is never turned away on an old reading.
  defp reread(%{assigns: %{selected: selected, bid: bid}} = socket)
       when not is_integer(selected) and not is_integer(bid),
       do: socket

  defp reread(socket) do
    if connected?(socket) do
      Book.refresh(socket.assigns.chain_id)
      read_book(socket)
    else
      socket
    end
  end

  defp read_book(socket) do
    symbol = socket.assigns.market.symbol
    start_async(socket, :book, fn -> CoveredCalls.read_covered_call_book(symbol) end)
  end

  # A link to a listing or bid the reading does not offer (dust, an expiry the
  # site does not list, or not among the best fifty) reads that one record
  # (`Book.one/3`, shared and kept as the reading is): never the whole market
  # again. It is read when the link names another record or the page has a
  # new reading, not when the same reading answers again, and a new read stops
  # the one still running. Its ticket shows while it is open there.
  defp read_linked(%{assigns: %{book: %AsyncResult{ok?: true, result: book}}} = socket) do
    case {unlisted_link(socket.assigns, book), socket.assigns.linked} do
      {nil, _linked} ->
        socket |> cancel_async(:linked) |> assign(linked: nil)

      {{kind, id}, %{kind: kind, id: id, read_at: read_at}} when read_at == book.read_at ->
        socket

      {{kind, id}, linked} ->
        symbol = socket.assigns.market.symbol

        socket
        |> assign(linked: reading_link(linked, kind, id, book.read_at))
        |> cancel_async(:linked)
        |> start_async(:linked, fn ->
          {kind, id, CoveredCalls.read_covered_call_offer(symbol, kind, id)}
        end)
    end
  end

  defp read_linked(socket), do: socket

  defp unlisted_link(%{tab: :sell, bid: id}, book) when is_integer(id),
    do: unlisted_link(:bid, id, book.bids)

  defp unlisted_link(%{tab: :buy, selected: id}, book) when is_integer(id),
    do: unlisted_link(:listing, id, book.listings)

  defp unlisted_link(_assigns, _book), do: nil

  defp unlisted_link(kind, id, offered),
    do: if(!Enum.any?(offered, &(&1.id == id)), do: {kind, id})

  # The same link read again keeps showing what it last read until the new read answers.
  defp reading_link(%{kind: kind, id: id} = linked, kind, id, read_at),
    do: %{linked | read_at: read_at}

  defp reading_link(_linked, kind, id, read_at),
    do: %{kind: kind, id: id, read_at: read_at, result: :reading}

  defp linked(socket, kind, id, answer) do
    case socket.assigns.linked do
      %{kind: ^kind, id: ^id} = linked -> assign(socket, linked: %{linked | result: answer})
      _another -> socket
    end
  end

  # The open ticket's quote, Sell's or Bid's, for the ticket as it stands. The
  # latest read wins.
  defp read_quote(%{assigns: %{tab: tab, book: %AsyncResult{ok?: true, result: book}}} = socket)
       when tab in [:sell, :bid] do
    %{market: %{symbol: symbol}, fields: %{^tab => fields}, quote: quote} = socket.assigns
    asked = request(ticket(fields, book, quote.value))

    Read.start(socket, :quote, symbol, fn ->
      case CoveredCalls.covered_call_quote(symbol, asked, actor: nil) do
        {:ok, answer} -> {:ok, answer}
        {:error, error} -> {:error, CoveredCalls.reason(error)}
      end
    end)
  end

  defp read_quote(socket), do: socket

  defp topic(market), do: "covered_calls:" <> market.symbol

  # What a Sell or Bid ticket holds, read from its fields and the latest quote:
  # the expiry chosen (the next Friday until one is), the strike (a
  # suggestion's, or the custom price typed), the premium (typed, or the
  # suggestion for that strike and expiry), and the order once all of them and
  # an amount read. The receipt is the quote's only when the quote answered for
  # exactly that order.
  defp ticket(fields, book, quote) do
    expiries = Terms.expiries(book.now)
    expiry = Enum.find(expiries, hd(expiries), &(Integer.to_string(&1) == fields["expiry"]))
    presets = quoted_presets(quote)
    amount = F.parse_tokens(fields["amount"], book.unit)
    {strike, suggested} = strike(fields, presets, priced(quote, expiry))
    {typed, premium} = premium(fields["premium"], suggested)
    order = order(amount, strike, premium, expiry)

    %{
      expiries: expiries,
      expiry: expiry,
      presets: presets,
      amount: amount,
      strike: strike,
      suggested: suggested,
      edited?: fields["premium"] != nil,
      typed: typed,
      premium: premium,
      order: order,
      value: value(amount, quote),
      receipt: receipt(order, quote),
      lead: lead(order, quote)
    }
  end

  # The typed amount's worth at the reference price, once the quote answered for it.
  defp value(amount, %{amount: amount, receipt: %{reference_value: value}})
       when is_integer(amount),
       do: value

  defp value(_amount, _quote), do: nil

  defp quoted_presets(nil), do: []
  defp quoted_presets(%{presets: presets}), do: presets

  # The quote prices the ticket only when it answered for the chosen expiry.
  defp priced(%{expiry: expiry} = quote, expiry), do: quote
  defp priced(_quote, _expiry), do: nil

  # The premium typed in, and the one the ticket uses: the typed one once
  # there is one, until then the suggestion.
  defp premium(nil, suggested), do: {nil, suggested}

  defp premium(field, _suggested) do
    typed = F.parse_usd(field)
    {typed, typed}
  end

  defp order(amount, strike, premium, _expiry)
       when is_nil(amount) or is_nil(strike) or is_nil(premium),
       do: nil

  defp order(amount, strike, premium, expiry),
    do: %{amount: amount, strike_per_token: strike, premium_per_token: premium, expiry: expiry}

  defp receipt(nil, _quote), do: nil
  defp receipt(order, quote), do: if(answers?(quote, order), do: quote.receipt)

  # Under You receive: what the seller keeps, if every call sells, as a share
  # of the stock's worth at the reference price.
  defp lead(order, quote) do
    case receipt(order, quote) do
      nil ->
        nil

      %{net_premium_yield: share} ->
        "#{:erlang.float_to_binary(share * 100, decimals: 2)}% of the stock's value, if all sells"
    end
  end

  # The strike chosen and the premium suggested for it at the chosen expiry,
  # once the quote has answered for that expiry (and, for a custom strike, for
  # that strike).
  defp strike(%{"strike" => "custom", "custom" => custom}, _presets, priced) do
    strike = F.parse_usd(custom)

    {strike,
     if(priced && priced.strike_per_token == strike, do: priced.suggested_premium_per_token)}
  end

  defp strike(%{"strike" => choice}, presets, priced) do
    index = String.to_integer(choice)

    case Enum.at(presets, index) do
      nil ->
        {nil, nil}

      preset ->
        {preset.strike_per_token,
         if(priced, do: Enum.at(priced.presets, index).suggested_premium_per_token)}
    end
  end

  # The quote's arguments for a ticket: what it holds so far. A premium is asked
  # for only once typed, so the quote suggests one for the strike.
  defp request(ticket) do
    [
      expiry: ticket.expiry,
      amount: ticket.amount,
      strike_per_token: ticket.strike,
      premium_per_token: ticket.typed
    ]
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Map.new()
  end

  # Whether a quote answered for every figure asked.
  defp answers?(nil, _asked), do: false
  defp answers?(quote, asked), do: Enum.all?(asked, fn {name, value} -> quote[name] == value end)

  def render(assigns) do
    %{book: %{result: book}, linked: linked, selected: selected, bid: bid} = assigns
    # What the shared reading offers: open, best first, the first fifty of each expiry.
    open = if(book, do: book.listings, else: [])
    bids = if(book, do: book.bids, else: [])

    assigns =
      assign(assigns,
        reading: book,
        open: open,
        bids: bids,
        ticket_listing: offer(open, linked, :listing, selected),
        ticket_bid: offer(bids, linked, :bid, bid),
        listing_note: shut(:listing, selected, linked),
        bid_note: shut(:bid, bid, linked),
        human_id: current_human_id(assigns.access_context)
      )

    ~H"""
    <article class="covered-calls">
      <CoveredCallComponent.toast
        :if={@done}
        id="covered-call-done"
        done={@done}
        dismiss="dismiss_done"
      />
      <header class="covered-calls__header">
        <div class="covered-calls__intro">
          <h1>Covered calls</h1>
          <p id="covered-calls-eligibility" class="covered-calls__eligibility">
            Available to
            <a href="https://www.coinbase.com/tokenize" target="_blank" rel="noopener">
              eligible people
            </a>
            outside the US.
          </p>
        </div>
        <div class="covered-calls__header-actions">
          <AutolaunchWeb.Components.ShareMarket.share_market
            id="covered-calls-share"
            kind={:covered_calls}
            subject={@market.symbol}
            account_control={@account_control}
          />
          <P.last_read
            id="covered-calls-read"
            at={@reading && @reading.read_at}
            phx-click="refresh"
            label="Read the listings again"
          />
        </div>
      </header>

      <nav
        id="covered-calls-tabs"
        class="covered-calls__tabs"
        aria-label="Covered calls"
        phx-hook="MotionTabs"
        data-active={if @tab == :sell, do: "sell", else: "buy"}
        data-variant={AutolaunchWeb.Motion.standard("tabs")}
      >
        <span
          id="covered-calls-tabs-ink"
          class="covered-calls__ink"
          data-ink
          aria-hidden="true"
          phx-mounted={JS.ignore_attributes(["style"])}
        ></span>
        <.link patch={~p"/stock/covered-call"} data-tab="sell" aria-current={@tab == :sell && "page"}>
          Sell
        </.link>
        <.link
          patch={~p"/stock/covered-call?tab=buy"}
          data-tab="buy"
          aria-current={@tab in [:buy, :bid] && "page"}
        >
          Buy <span :if={@reading} class="covered-calls__count">{length(@open)}</span>
        </.link>
        <span
          :if={@human_id && @exercise_by}
          id="covered-calls-deadline"
          class="covered-calls__deadline"
          role="status"
        >
          Exercise by
          <CoveredCallComponent.local_time id="covered-calls-deadline-at" at={@exercise_by} />
        </span>
        <.link :if={@human_id} navigate={~p"/portfolio"} class="covered-calls__mine">My calls</.link>
      </nav>

      <p :if={@book.failed} class="covered-calls__note" role="alert">
        The listings couldn't be read just now. Try again in a moment.
      </p>

      <section :if={@tab in [:buy, :bid]} class="covered-calls__section" aria-label="Buy">
        <.pills
          id="covered-calls-buy-mode"
          class="covered-calls__switch"
          active={@tab}
          aria-label="Buy or bid"
        >
          <:pill value="buy" event="mode" name="mode">Buy</:pill>
          <:pill value="bid" event="mode" name="mode">Bid</:pill>
        </.pills>
        <h2 :if={@tab == :buy} id="covered-calls-buy-title" class="covered-calls__title">
          For sale
        </h2>
        <div :if={@tab == :buy && @open != []} class="market-list__scroll">
          <table class="market-list__table covered-calls__table">
            <caption class="visually-hidden">Calls for sale on {@market.symbol}</caption>
            <thead>
              <tr>
                <th scope="col">Strike</th>
                <th scope="col">Premium</th>
                <th scope="col">Exercise window</th>
                <th scope="col">Available</th>
                <th scope="col"><span class="visually-hidden">Buy</span></th>
              </tr>
            </thead>
            <tbody :for={listing <- @open} id={"covered-call-#{listing.id}"}>
              <tr class={@selected == listing.id && "covered-calls__chosen"}>
                <td data-label="Strike">{F.usd(listing.strike_per_token)}</td>
                <td data-label="Premium">
                  {F.usd(listing.premium_per_token)} <small>per {@market.symbol}</small>
                </td>
                <td data-label="Exercise window">{F.window(listing.expiry)}</td>
                <td data-label="Available">
                  {F.tokens(Terms.available(listing), @reading.unit)} {@market.symbol}
                  <small>{shares(Terms.available(listing), @reading)}</small>
                </td>
                <td class="covered-calls__row-action">
                  <.link
                    patch={~p"/stock/covered-call?listing=#{listing.id}"}
                    class="rg-button rg-button--secondary"
                    aria-expanded={to_string(@selected == listing.id)}
                  >
                    Buy
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p
          :if={@tab == :buy && @reading && @listing_note}
          id="covered-calls-listing-note"
          class="covered-calls__note"
          role="status"
        >
          {@listing_note}
        </p>
        <p
          :if={@tab == :buy && @reading && @reading.listings_total > length(@open)}
          id="covered-calls-listings-more"
          class="covered-calls__note"
        >
          The best {length(@open)} of {@reading.listings_total} listings
        </p>
        <.buy_ticket
          :if={@tab == :buy && @reading && @ticket_listing}
          listing={@ticket_listing}
          unlisted={unlisted(@ticket_listing, @open, @reading, &Terms.for_buyers/1)}
          market={@market}
          reading={@reading}
          line={@line}
          typed={@buy}
          session_lease={@session_lease}
          human_id={@human_id}
        />
        <div
          :if={@tab == :buy && @reading && @open == []}
          class="market-list__scroll market-list__empty"
        >
          <h2>No listings</h2>
          <.link patch={~p"/stock/covered-call"} class="rg-button rg-button--secondary">
            Sell calls
          </.link>
        </div>
        <div
          :if={@tab == :buy && !@reading && !@book.failed}
          class="market-list__scroll"
          aria-busy="true"
        >
          <span class="loading-block"></span>
        </div>
        <.bid_ticket
          :if={@tab == :bid && @reading}
          market={@market}
          reading={@reading}
          line={@line}
          fields={@fields.bid}
          quote={@quote}
          session_lease={@session_lease}
          human_id={@human_id}
        />
        <div
          :if={@tab == :bid && !@reading && !@book.failed}
          class="covered-calls__waiting"
          aria-busy="true"
        >
          <span class="loading-block"></span>
        </div>
      </section>

      <section :if={@tab == :sell} class="covered-calls__section" aria-label="Sell">
        <.sell_ticket
          :if={@reading}
          market={@market}
          reading={@reading}
          line={@line}
          fields={@fields.sell}
          quote={@quote}
          balance={@balance}
          session_lease={@session_lease}
          human_id={@human_id}
        />
        <div :if={!@reading && !@book.failed} class="covered-calls__waiting" aria-busy="true">
          <span class="loading-block"></span>
        </div>
        <p
          :if={@reading && @bid_note}
          id="covered-calls-bid-note"
          class="covered-calls__note"
          role="status"
        >
          {@bid_note}
        </p>
      </section>

      <section
        :if={@tab == :sell && @reading && (@bids != [] or @ticket_bid)}
        class="covered-calls__section"
        aria-labelledby="covered-calls-bids-title"
      >
        <h2 id="covered-calls-bids-title" class="covered-calls__title">Bids</h2>
        <div :if={@bids != []} class="market-list__scroll">
          <table class="market-list__table covered-calls__table">
            <caption class="visually-hidden">Bids for calls on {@market.symbol}</caption>
            <thead>
              <tr>
                <th scope="col">Strike</th>
                <th scope="col">Premium</th>
                <th scope="col">Exercise window</th>
                <th scope="col">Wanted</th>
                <th scope="col"><span class="visually-hidden">Sell</span></th>
              </tr>
            </thead>
            <tbody :for={bid <- @bids} id={"covered-call-bids-#{bid.id}"}>
              <tr class={@bid == bid.id && "covered-calls__chosen"}>
                <td data-label="Strike">{F.usd(bid.strike_per_token)}</td>
                <td data-label="Premium">
                  {F.usd(bid.premium_per_token)} <small>per {@market.symbol}</small>
                </td>
                <td data-label="Exercise window">{F.window(bid.expiry)}</td>
                <td data-label="Wanted">
                  {F.tokens(Terms.available(bid), @reading.unit)} {@market.symbol}
                  <small>{shares(Terms.available(bid), @reading)}</small>
                </td>
                <td class="covered-calls__row-action">
                  <.link
                    patch={~p"/stock/covered-call?bid=#{bid.id}"}
                    class="rg-button rg-button--secondary"
                    aria-expanded={to_string(@bid == bid.id)}
                  >
                    Sell
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p
          :if={@reading.bids_total > length(@bids)}
          id="covered-calls-bids-more"
          class="covered-calls__note"
        >
          The best {length(@bids)} of {@reading.bids_total} bids
        </p>
        <.sale_ticket
          :if={@ticket_bid}
          bid={@ticket_bid}
          unlisted={unlisted(@ticket_bid, @bids, @reading, &Terms.for_sellers(&1, spot(@reading)))}
          market={@market}
          reading={@reading}
          line={@line}
          typed={@sale}
          balance={@balance}
          session_lease={@session_lease}
          human_id={@human_id}
        />
      </section>

      <section class="covered-calls__section" aria-labelledby="covered-calls-contract-title">
        <h2 id="covered-calls-contract-title" class="covered-calls__title">Contract</h2>
        <dl class="covered-calls__facts covered-calls__contract">
          <dt>Covered calls</dt>
          <dd><P.address id="covered-calls-contract" address={@market.contract} /></dd>
          <dt>{@market.symbol}</dt>
          <dd><P.address id="covered-calls-stock" address={@market.stock} /></dd>
          <dt>Price feed</dt>
          <dd><P.address id="covered-calls-feed" address={@market.feed} /></dd>
          <dt>Code</dt>
          <dd>
            <a
              href={BidPlaced.address_url(:base, @market.contract) <> "#code"}
              target="_blank"
              rel="noopener"
            >
              Verified on Basescan
            </a>
          </dd>
          <dt>Owner</dt>
          <dd>None</dd>
          <dt>Upgrades</dt>
          <dd>None</dd>
          <dt>Issuer</dt>
          <dd>Coinbase can pause or seize {@market.symbol}</dd>
          <dt>Staking</dt>
          <dd>Buying and selling into bids stop while REGENT staking is paused</dd>
        </dl>
      </section>
    </article>
    """
  end

  attr :market, :map, required: true
  attr :reading, :map, required: true
  attr :line, :list, required: true, doc: "from `Autolaunch.CoveredCalls.PriceLine.line/1`"
  attr :fields, :map, required: true
  attr :quote, Read, required: true

  attr :balance, :integer,
    default: nil,
    doc: "the listing wallet's stock; nil signed out or unread"

  attr :session_lease, :any, required: true
  attr :human_id, :any, required: true

  # The Sell ticket: the price line with the strike across it, the terms, then
  # the wallet's button, beside the receipt and the three ways the listing can
  # end. The strike's line follows the form in the browser as it is chosen or
  # typed.
  defp sell_ticket(%{fields: fields, reading: reading, quote: quote} = assigns) do
    assigns =
      assign(assigns,
        t: ticket(fields, reading, quote.value),
        symbol: assigns.market.symbol,
        unit: reading.unit,
        refused: refused(quote)
      )

    ~H"""
    <Regent.Structure.panel id="covered-calls-sell" class="covered-calls__ticket">
      <div class="covered-calls__fields">
        <.stock_price name="sell" reading={@reading} market={@market} />
        <PriceChart.price_line
          id="covered-calls-sell-price"
          points={@line}
          follow="covered-calls-sell-form"
        >
          <:level price={dollars(@t.strike)} />
        </PriceChart.price_line>

        <.terms
          name="sell"
          fields={@fields}
          t={@t}
          reading={@reading}
          symbol={@symbol}
          balance={@balance}
        />

        <.live_component
          module={CoveredCallComponent}
          id="covered-call-list"
          kind={:list}
          symbol={@symbol}
          unit={@unit}
          order={@t.order}
          session_lease={@session_lease}
          current_human_id={@human_id}
        />
      </div>

      <div
        id="covered-calls-sell-result"
        class="covered-calls__result"
        phx-hook="MotionCount"
        data-variant={AutolaunchWeb.Motion.standard("count")}
      >
        <section class="covered-calls__receipt" aria-labelledby="covered-calls-sell-receipt-title">
          <div class="covered-calls__label">
            <h3 id="covered-calls-sell-receipt-title">Receipt</h3>
            <P.tip id="covered-calls-sell-receipt-tip" label="About the receipt">
              If all of it sells. Buyers can buy part, and you can stop selling the rest at any
              time. 1% of each premium goes to REGENT stakers. Strike payments wait in the
              contract until you collect them.
            </P.tip>
            <span class="covered-calls__status" role="status">{@refused}</span>
          </div>
          <dl id="covered-calls-sell-receipt" class="covered-calls__lines">
            <div>
              <dt>You receive</dt>
              <dd class="covered-calls__lead">
                <span id="covered-calls-sell-net" data-count>
                  {F.usd(@t.receipt && @t.receipt.net_premium)}
                </span>
                <small id="covered-calls-sell-yield">{@t.lead}</small>
              </dd>
            </div>
            <div>
              <dt>Fee</dt>
              <dd id="covered-calls-sell-fee" data-count>{F.usd(@t.receipt && @t.receipt.fee)}</dd>
            </div>
            <div>
              <dt>If exercised</dt>
              <dd id="covered-calls-sell-exercised" data-count>
                {F.usd(@t.receipt && @t.receipt.strike)}
              </dd>
            </div>
            <.window id="covered-calls-sell" expiry={@t.expiry} />
          </dl>
          <p id="covered-calls-sell-paid" class="covered-calls__note">
            Paid to your wallet each time a buyer buys. Nothing is paid until someone buys.
          </p>
        </section>

        <ul id="covered-calls-sell-outcomes" class="covered-calls__outcomes" aria-label="Outcomes">
          <li id="covered-calls-sell-kept">
            <strong>Not exercised</strong>
            <span data-count>{F.usd(@t.receipt && @t.receipt.net_premium)}</span>
            <small>
              You keep the premium and collect your {yours(@t.amount, @unit, @symbol)} after the
              window closes
            </small>
          </li>
          <li id="covered-calls-sell-taken">
            <strong>Exercised</strong>
            <span data-count>
              {F.usd(@t.receipt && @t.receipt.strike + @t.receipt.net_premium)}
            </span>
            <small>
              You keep the premium and collect the strike; the {@symbol} goes to the buyer
            </small>
          </li>
          <li id="covered-calls-sell-unsold">
            <strong>Unsold</strong>
            <span data-count>{held(@t.amount, @unit, @symbol)}</span>
            <small>
              Take it back at any time. Sold calls stay locked until the window closes.
            </small>
          </li>
        </ul>
        <.seller_risks id="covered-calls-sell-risks" symbol={@symbol} expiry={@t.expiry} />
      </div>
    </Regent.Structure.panel>
    """
  end

  attr :market, :map, required: true
  attr :reading, :map, required: true
  attr :line, :list, required: true, doc: "from `Autolaunch.CoveredCalls.PriceLine.line/1`"
  attr :fields, :map, required: true
  attr :quote, Read, required: true
  attr :session_lease, :any, required: true
  attr :human_id, :any, required: true

  # The Bid ticket: the terms of the calls wanted, chosen as on Sell, then the
  # wallet's button, beside what the contract holds for the bid and the three
  # ways the calls can end for the bidder. The page sets the bid's minimum
  # sale (`Terms.min_sale/2`), said only in the receipt's note.
  defp bid_ticket(%{fields: fields, reading: reading, quote: quote} = assigns) do
    t = ticket(fields, reading, quote.value)
    unit = reading.unit

    assigns =
      assign(assigns,
        t: t,
        symbol: assigns.market.symbol,
        unit: unit,
        pay: t.order && Terms.usdc_for(t.amount, t.premium, unit),
        exercise: t.amount && t.strike && Terms.usdc_for(t.amount, t.strike, unit),
        break_even: t.strike && t.premium && t.strike + t.premium,
        min_sale: Terms.min_sale(t.amount || unit, unit),
        refused: refused(quote)
      )

    ~H"""
    <Regent.Structure.panel id="covered-calls-bid" class="covered-calls__ticket">
      <div class="covered-calls__fields">
        <.stock_price name="bid" reading={@reading} market={@market} />
        <PriceChart.price_line
          id="covered-calls-bid-price"
          points={@line}
          follow="covered-calls-bid-form"
        >
          <:level price={dollars(@t.strike)} name="Strike" />
          <:level price={dollars(@break_even)} name="Break-even" dotted />
        </PriceChart.price_line>

        <.terms name="bid" fields={@fields} t={@t} reading={@reading} symbol={@symbol} />

        <.live_component
          module={CoveredCallComponent}
          id="covered-call-bid"
          kind={:bid}
          symbol={@symbol}
          unit={@unit}
          order={@t.order}
          session_lease={@session_lease}
          current_human_id={@human_id}
        />
      </div>

      <div
        id="covered-calls-bid-result"
        class="covered-calls__result"
        phx-hook="MotionCount"
        data-variant={AutolaunchWeb.Motion.standard("count")}
      >
        <section class="covered-calls__receipt" aria-labelledby="covered-calls-bid-receipt-title">
          <div class="covered-calls__label">
            <h3 id="covered-calls-bid-receipt-title">Receipt</h3>
            <P.tip id="covered-calls-bid-receipt-tip" label="About the receipt">
              The premium waits in the contract until sellers sell into the bid, each sale at
              least {F.tokens(@min_sale, @unit)} {@symbol} or all that is left. Stop the bid at
              any time, or wait for the expiry, and refund what isn't spent.
            </P.tip>
            <span class="covered-calls__status" role="status">{@refused}</span>
          </div>
          <dl id="covered-calls-bid-receipt" class="covered-calls__lines">
            <div>
              <dt>You pay</dt>
              <dd id="covered-calls-bid-pay" data-count>
                {if @pay, do: F.usd_due(@pay), else: F.usd(nil)}
              </dd>
            </div>
            <.buyer_fee />
            <div>
              <dt>To exercise</dt>
              <dd id="covered-calls-bid-exercise" data-count>
                {if @exercise, do: F.usd_due(@exercise), else: F.usd(nil)}
              </dd>
            </div>
            <div>
              <dt>On exercise</dt>
              <dd id="covered-calls-bid-get">
                <span data-count>{held(@t.amount, @unit, @symbol)}</span>
                <small :if={@t.amount && shares?(@reading)}>{shares(@t.amount, @reading)}</small>
              </dd>
            </div>
            <div>
              <dt>Break-even</dt>
              <dd id="covered-calls-bid-break-even">
                {F.usd_due(@break_even)} <small>per {@symbol}</small>
              </dd>
            </div>
            <.window id="covered-calls-bid" expiry={@t.expiry} />
          </dl>
          <p id="covered-calls-bid-held" class="covered-calls__note">
            Held by the contract until a seller sells to you. Not guaranteed to fill. Stop and
            refund the rest at any time. Each sale arrives as its own position to exercise.
          </p>
          <.buyer_steps id="covered-calls-bid-steps" first="Approve USDC and place the bid now." />
        </section>

        <.buyer_outcomes
          id="covered-calls-bid-outcomes"
          symbol={@symbol}
          strike={@t.strike}
          break_even={@break_even}
        />
      </div>
    </Regent.Structure.panel>
    """
  end

  attr :bid, :map, required: true

  attr :unlisted, :atom,
    default: nil,
    doc: "why a bid opened by its link is not in the list (`unlisted/4`)"

  attr :market, :map, required: true
  attr :reading, :map, required: true
  attr :line, :list, required: true, doc: "from `Autolaunch.CoveredCalls.PriceLine.line/1`"
  attr :typed, :string, required: true, doc: "the amount typed"

  attr :balance, :integer,
    default: nil,
    doc: "the selling wallet's stock; nil signed out or unread"

  attr :session_lease, :any, required: true
  attr :human_id, :any, required: true

  # A bid's Sell now ticket, under the bids so it is never wider than the
  # screen: the price line with the bid's strike across it and the amount,
  # beside what the sale pays now, counted as the contract counts it (the
  # wallet's prepared step counts the same at the latest block), and how it
  # can end.
  defp sale_ticket(%{bid: bid, reading: reading, typed: typed} = assigns) do
    unit = reading.unit
    amount = F.parse_tokens(typed, unit)

    assigns =
      assign(assigns,
        id: "covered-call-sell-#{bid.id}",
        symbol: assigns.market.symbol,
        unit: unit,
        amount: amount,
        order: amount && %{bid_id: bid.id, amount: amount},
        sale: amount && Terms.sale(bid, amount, unit),
        exercise: amount && Terms.usdc_for(amount, bid.strike_per_token, unit),
        least: Terms.least_sale(bid),
        max: assigns.balance && min(assigns.balance, Terms.available(bid)),
        under: under_price(bid, amount || unit, reading)
      )

    ~H"""
    <Regent.Structure.panel id={@id} class="covered-calls__ticket" aria-labelledby={"#{@id}-title"}>
      <div class="covered-calls__fields">
        <div class="covered-calls__market">
          <h3 id={"#{@id}-title"} class="covered-calls__title">Sell now</h3>
        </div>
        <CoveredCallComponent.stock id={"#{@id}-stock"} market={@market} />
        <p :if={@unlisted} id={"#{@id}-unlisted"} class="covered-calls__note">
          {unlisted_words(@unlisted, :bid, @symbol)}
        </p>
        <PriceChart.price_line id={"#{@id}-price"} points={@line}>
          <:level price={dollars(@bid.strike_per_token)} name="Strike" />
        </PriceChart.price_line>
        <form id={"#{@id}-form"} phx-change="sale" phx-submit="sale">
          <div class="covered-calls__field">
            <div class="covered-calls__label">
              <label for={"#{@id}-amount"}>Amount</label>
              <span :if={@max} id={"#{@id}-balance"} class="covered-calls__balance">
                <span class="visually-hidden">Balance</span>
                {F.tokens(@balance, @unit)} {@symbol}
                <button
                  id={"#{@id}-max"}
                  type="button"
                  class="covered-calls__max"
                  phx-click={
                    JS.dispatch("autolaunch:fill",
                      to: "##{@id}-amount",
                      detail: %{value: F.tokens(@max, @unit)}
                    )
                  }
                  disabled={@max == 0}
                >
                  Max
                </button>
              </span>
            </div>
            <span class="covered-calls__input">
              <input
                id={"#{@id}-amount"}
                name="amount"
                type="text"
                value={@typed}
                inputmode="decimal"
                autocomplete="off"
                spellcheck="false"
                placeholder="0"
              />
              <span aria-hidden="true">{@symbol}</span>
            </span>
          </div>
        </form>
        <.live_component
          module={CoveredCallComponent}
          id={"covered-call-sale-#{@bid.id}"}
          kind={:sell_to_bid}
          symbol={@symbol}
          unit={@unit}
          bid={@bid}
          order={@order}
          session_lease={@session_lease}
          current_human_id={@human_id}
        />
      </div>

      <div
        id={"#{@id}-result"}
        class="covered-calls__result"
        phx-hook="MotionCount"
        data-variant={AutolaunchWeb.Motion.standard("count")}
      >
        <section class="covered-calls__receipt" aria-labelledby={"#{@id}-receipt-title"}>
          <div class="covered-calls__label">
            <h4 id={"#{@id}-receipt-title"}>Receipt</h4>
            <P.tip id={"#{@id}-receipt-tip"} label="About the receipt">
              1% of the premium goes to REGENT stakers. If the calls are exercised, the strike
              waits in the contract until you collect it.
            </P.tip>
          </div>
          <dl id={"#{@id}-receipt"} class="covered-calls__lines">
            <div>
              <dt>You receive</dt>
              <dd class="covered-calls__lead">
                <span id={"#{@id}-receive"} data-count>{F.usd(@sale && @sale.receive)}</span>
                <small>Paid now</small>
              </dd>
            </div>
            <div>
              <dt>Premium</dt>
              <dd id={"#{@id}-premium"} data-count>{F.usd(@sale && @sale.premium)}</dd>
            </div>
            <div>
              <dt>Fee</dt>
              <dd id={"#{@id}-fee"} data-count>{F.usd(@sale && @sale.fee)}</dd>
            </div>
            <div>
              <dt>If exercised</dt>
              <dd id={"#{@id}-exercised"} data-count>{F.usd(@exercise)}</dd>
            </div>
            <div>
              <dt>Wanted</dt>
              <dd id={"#{@id}-wanted"}>{F.tokens(Terms.available(@bid), @unit)} {@symbol}</dd>
            </div>
            <div :if={@least != @unit}>
              <dt>Minimum</dt>
              <dd id={"#{@id}-minimum"}>{F.tokens(@least, @unit)} {@symbol}</dd>
            </div>
            <.window id={@id} expiry={@bid.expiry} />
          </dl>
        </section>

        <ul id={"#{@id}-outcomes"} class="covered-calls__outcomes" aria-label="Outcomes">
          <li>
            <strong>Not exercised</strong>
            <span data-count>{F.usd(@sale && @sale.receive)}</span>
            <small>
              You keep the premium and collect your {yours(@amount, @unit, @symbol)} after the
              window closes
            </small>
          </li>
          <li>
            <strong>Exercised</strong>
            <span data-count>{F.usd(@sale && @exercise + @sale.receive)}</span>
            <small>
              You keep the premium and collect the strike; the {@symbol} goes to the buyer
            </small>
          </li>
        </ul>
        <.seller_risks id={"#{@id}-risks"} symbol={@symbol} expiry={@bid.expiry} under={@under} />
      </div>
    </Regent.Structure.panel>
    """
  end

  attr :name, :string, required: true, doc: "the ticket, \"sell\" or \"bid\": its ids"
  attr :reading, :map, required: true
  attr :market, :map, required: true

  # The stock over a ticket, named by issuer, chain and address, and its
  # reference price, said to be one, with its age and where it comes from.
  defp stock_price(assigns) do
    ~H"""
    <div class="covered-calls__market">
      <h2 class="covered-calls__title">{@market.symbol}</h2>
      <span class="covered-calls__reference">
        <small id={"covered-calls-#{@name}-reference"}>{reference(@reading)}</small>
        <P.tip id={"covered-calls-#{@name}-price-tip"} class="covered-calls__spot">
          <:figure>{F.usd(spot(@reading))}</:figure>
          {price_words(@reading, @market.symbol)}
        </P.tip>
      </span>
    </div>
    <CoveredCallComponent.stock id={"covered-calls-#{@name}-stock"} market={@market} />
    """
  end

  attr :name, :string, required: true, doc: "the ticket, \"sell\" or \"bid\": its events and ids"
  attr :fields, :map, required: true
  attr :t, :map, required: true, doc: "the ticket as it stands, from `ticket/3`"
  attr :reading, :map, required: true
  attr :symbol, :string, required: true

  attr :balance, :integer,
    default: nil,
    doc: "the wallet's stock, for Sell's Max; nil for none"

  # A Sell or Bid ticket's terms: the amount, one of the next Fridays, a
  # strike (three suggestions or a custom price) and a premium (the
  # suggestion, or typed). The events are named for the ticket.
  defp terms(assigns) do
    assigns =
      assign(assigns, unit: assigns.reading.unit, custom?: assigns.fields["strike"] == "custom")

    ~H"""
    <form id={"covered-calls-#{@name}-form"} phx-change={@name} phx-submit={@name}>
      <div class="covered-calls__field">
        <div class="covered-calls__label">
          <label for={"covered-calls-#{@name}-amount"}>Amount</label>
          <P.tip id={"covered-calls-#{@name}-amount-tip"} label="About the amount">
            Dividends during the week stay with the tokens: they raise each token's share
            count ({multiplier(@reading.multiplier)} shares per {@symbol} now), so they go to
            whoever ends up with the {@symbol}.
          </P.tip>
          <span :if={@balance} id={"covered-calls-#{@name}-balance"} class="covered-calls__balance">
            <span class="visually-hidden">Balance</span>
            {F.tokens(@balance, @unit)} {@symbol}
            <button
              id={"covered-calls-#{@name}-max"}
              type="button"
              class="covered-calls__max"
              phx-click={
                JS.dispatch("autolaunch:fill",
                  to: "#covered-calls-#{@name}-amount",
                  detail: %{value: F.tokens(@balance, @unit)}
                )
              }
              disabled={@balance == 0}
            >
              Max
            </button>
          </span>
        </div>
        <span class="covered-calls__input">
          <input
            id={"covered-calls-#{@name}-amount"}
            name="amount"
            type="text"
            value={@fields["amount"]}
            inputmode="decimal"
            autocomplete="off"
            spellcheck="false"
            placeholder="0"
          />
          <span aria-hidden="true">{@symbol}</span>
        </span>
        <small
          id={"covered-calls-#{@name}-value"}
          class="covered-calls__hint covered-calls__value"
        >
          {amount_hint(@t, @reading)}
        </small>
      </div>

      <fieldset class="covered-calls__field">
        <legend class="covered-calls__label">
          <span id={"covered-calls-#{@name}-expiry-label"}>Expiry</span>
          <P.tip id={"covered-calls-#{@name}-expiry-tip"} label="About the expiry">
            Calls expire on a Friday at 21:00 UTC. {exerciser(@name)} for the 24 hours after.
          </P.tip>
        </legend>
        <.pills id={"covered-calls-#{@name}-expiry"} active={@t.expiry}>
          <:pill
            :for={expiry <- @t.expiries}
            value={expiry}
            event={"#{@name}_expiry"}
            name="expiry"
            label={F.window(expiry)}
          >
            {F.date(expiry)}
          </:pill>
        </.pills>
      </fieldset>

      <fieldset class="covered-calls__field">
        <legend class="covered-calls__label">
          <span>Strike</span>
          <P.tip id={"covered-calls-#{@name}-strike-tip"} label="About the strike">
            {strike_words(@name, @symbol)}
          </P.tip>
        </legend>
        <.pills id={"covered-calls-#{@name}-strike"} active={@fields["strike"]}>
          <:pill
            :for={{choice, preset} <- presets(@t.presets)}
            value={choice}
            event={"#{@name}_strike"}
            name="strike"
            disabled={is_nil(preset)}
            strike={preset && F.plain_usd(preset.strike_per_token)}
          >
            <span>{F.usd(preset && preset.strike_per_token)}</span>
            <small>{above(preset)}</small>
          </:pill>
          <:pill value="custom" event={"#{@name}_strike"} name="strike" strike="custom">
            Custom
          </:pill>
        </.pills>
        <span class="covered-calls__input covered-calls__custom" inert={!@custom?}>
          <input
            id={"covered-calls-#{@name}-custom"}
            name="custom"
            type="text"
            value={@fields["custom"]}
            inputmode="decimal"
            autocomplete="off"
            spellcheck="false"
            placeholder="0.00"
            aria-label="Custom strike"
          />
          <span aria-hidden="true">USDC</span>
        </span>
      </fieldset>

      <div class="covered-calls__field">
        <div class="covered-calls__label">
          <label for={"covered-calls-#{@name}-premium"}>Premium</label>
          <P.tip id={"covered-calls-#{@name}-premium-tip"} label="About the premium">
            A model estimate, not a market price. It assumes the stock moves about {round(
              Quote.volatility() * 100
            )}% a year. You choose the premium.
          </P.tip>
          <button
            id={"covered-calls-#{@name}-suggested"}
            type="button"
            class="covered-calls__suggested"
            phx-click={"#{@name}_suggested"}
            inert={!suggest?(@t)}
          >
            Model {F.usd(@t.suggested)}
          </button>
        </div>
        <span class="covered-calls__input">
          <input
            id={"covered-calls-#{@name}-premium"}
            name="premium"
            type="text"
            value={@fields["premium"] || (@t.suggested && F.plain_usd(@t.suggested))}
            inputmode="decimal"
            autocomplete="off"
            spellcheck="false"
            placeholder="0.00"
          />
          <span aria-hidden="true">per {@symbol}</span>
        </span>
        <small id={"covered-calls-#{@name}-live"} class="covered-calls__hint covered-calls__live">
          {live_price(@name, @t, @reading, @symbol)}
        </small>
      </div>
    </form>
    """
  end

  attr :id, :string, required: true, doc: "the ticket's id, before -opens and -closes"
  attr :expiry, :integer, required: true

  # A ticket's exercise window, as receipt lines.
  defp window(assigns) do
    ~H"""
    <div>
      <dt>Opens</dt>
      <dd><CoveredCallComponent.local_time id={"#{@id}-opens"} at={@expiry} /></dd>
    </div>
    <div>
      <dt>Closes</dt>
      <dd>
        <CoveredCallComponent.local_time
          id={"#{@id}-closes"}
          at={@expiry + Terms.exercise_window()}
        />
      </dd>
    </div>
    """
  end

  # A buyer pays the premium and nothing on top.
  defp buyer_fee(assigns) do
    ~H"""
    <div>
      <dt>Fee</dt>
      <dd>None on top <small>1% comes out of the seller's side</small></dd>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :first, :string, required: true, doc: "the steps the ticket's own button takes"

  # Under a buyer's receipt: exercise is the holder's own act, inside the
  # window only, and the steps each part takes.
  defp buyer_steps(assigns) do
    ~H"""
    <p id={@id} class="covered-calls__note">
      You must exercise yourself between Opens and Closes. Calls not exercised by then end, and
      the premium is not returned. {@first} In the window: approve USDC and exercise, then
      collect the stock.
    </p>
    """
  end

  attr :id, :string, required: true
  attr :symbol, :string, required: true
  attr :expiry, :integer, required: true

  attr :under, :map,
    default: nil,
    doc: "a sale into a bid whose strike and premium are under the price (`under_price/3`)"

  # What a seller gives up, in plain sight on both Sell tickets. A sale into a
  # bid that pays less than the stock is priced at says so first, with both
  # totals.
  defp seller_risks(assigns) do
    ~H"""
    <p id={@id} class="covered-calls__risks">
      <strong>Risks</strong>
      <span :if={@under} id={"#{@id}-under"}>
        This bid is under the price: if exercised you receive {F.usd(@under.receive)} for {@under.tokens} {@symbol} priced at {F.usd(
          @under.worth
        )}.
      </span>
      Once sold, your {@symbol} is locked until the window closes on {F.window_closes(@expiry)}.
      If the price falls you cannot sell it before then. If the price rises above the strike,
      the gain above it goes to the buyer. The buyer chooses. Nothing is exercised automatically.
    </p>
    """
  end

  attr :id, :string, required: true
  attr :symbol, :string, required: true
  attr :strike, :integer, default: nil, doc: "USDC per token; nil while it is not set"
  attr :break_even, :integer, default: nil, doc: "USDC per token; nil while it is not set"

  # How calls can end for whoever holds them, by where the stock token's own
  # price stands in the window: the token's, never the share's on its exchange.
  defp buyer_outcomes(assigns) do
    ~H"""
    <ul id={@id} class="covered-calls__outcomes" aria-label="Outcomes">
      <li>
        <strong>Above break-even</strong>
        <span>{@symbol}'s price over {F.usd_due(@break_even)}</span>
        <small>Exercising costs less than the price</small>
      </li>
      <li>
        <strong>In between</strong>
        <span>{@symbol}'s price {F.usd(@strike)} – {F.usd_due(@break_even)}</span>
        <small>Exercise to win back part of the premium</small>
      </li>
      <li>
        <strong>Below strike</strong>
        <span>{@symbol}'s price under {F.usd(@strike)}</span>
        <small>Let it lapse; the premium is spent</small>
      </li>
    </ul>
    """
  end

  attr :listing, :map, required: true

  attr :unlisted, :atom,
    default: nil,
    doc: "why a listing opened by its link is not in the list (`unlisted/4`)"

  attr :market, :map, required: true
  attr :reading, :map, required: true
  attr :line, :list, required: true, doc: "from `Autolaunch.CoveredCalls.PriceLine.line/1`"
  attr :typed, :string, default: nil, doc: "the amount typed; nil for all that is left"
  attr :session_lease, :any, required: true
  attr :human_id, :any, required: true

  # The chosen listing's Buy ticket, under the list so it is never wider than
  # the screen: the price line with its strike and break-even across it, the
  # amount, what it costs and how it can end, counted as the contract counts
  # them.
  defp buy_ticket(%{listing: listing, reading: reading, typed: typed} = assigns) do
    unit = reading.unit
    left = Terms.available(listing)
    amount = if typed, do: F.parse_tokens(typed, unit), else: left
    break_even = listing.strike_per_token + listing.premium_per_token

    assigns =
      assign(assigns,
        id: "covered-call-buy-#{listing.id}",
        symbol: assigns.market.symbol,
        unit: unit,
        value: typed || F.tokens(left, unit),
        left: F.tokens(left, unit),
        amount: amount,
        order: amount && %{listing_id: listing.id, amount: amount},
        pay: amount && Terms.usdc_for(amount, listing.premium_per_token, unit),
        exercise: amount && Terms.usdc_for(amount, listing.strike_per_token, unit),
        break_even: break_even
      )

    ~H"""
    <Regent.Structure.panel id={@id} class="covered-calls__ticket" aria-labelledby={"#{@id}-title"}>
      <div class="covered-calls__fields">
        <div class="covered-calls__market">
          <h3 id={"#{@id}-title"} class="covered-calls__title">Buy calls</h3>
        </div>
        <CoveredCallComponent.stock id={"#{@id}-stock"} market={@market} />
        <p :if={@unlisted} id={"#{@id}-unlisted"} class="covered-calls__note">
          {unlisted_words(@unlisted, :listing, @symbol)}
        </p>
        <PriceChart.price_line id={"#{@id}-price"} points={@line}>
          <:level price={dollars(@listing.strike_per_token)} name="Strike" />
          <:level price={dollars(@break_even)} name="Break-even" dotted />
        </PriceChart.price_line>
        <form id={"#{@id}-form"} phx-change="buy" phx-submit="buy">
          <div class="covered-calls__field">
            <div class="covered-calls__label">
              <label for={"#{@id}-amount"}>Amount</label>
              <small class="covered-calls__hint">of {@left}</small>
            </div>
            <span class="covered-calls__input">
              <input
                id={"#{@id}-amount"}
                name="amount"
                type="text"
                value={@value}
                inputmode="decimal"
                autocomplete="off"
                spellcheck="false"
                placeholder="0"
              />
              <span aria-hidden="true">{@symbol}</span>
            </span>
          </div>
        </form>
        <.live_component
          module={CoveredCallComponent}
          id={"covered-call-fill-#{@listing.id}"}
          kind={:fill}
          symbol={@symbol}
          unit={@unit}
          listing={@listing}
          order={@order}
          session_lease={@session_lease}
          current_human_id={@human_id}
        />
      </div>

      <div
        id={"#{@id}-result"}
        class="covered-calls__result"
        phx-hook="MotionCount"
        data-variant={AutolaunchWeb.Motion.standard("count")}
      >
        <section class="covered-calls__receipt" aria-labelledby={"#{@id}-receipt-title"}>
          <div class="covered-calls__label">
            <h4 id={"#{@id}-receipt-title"}>Receipt</h4>
          </div>
          <dl id={"#{@id}-receipt"} class="covered-calls__lines">
            <div>
              <dt>You pay</dt>
              <dd id={"#{@id}-pay"} data-count>{if @pay, do: F.usd_due(@pay), else: F.usd(nil)}</dd>
            </div>
            <.buyer_fee />
            <div>
              <dt>To exercise</dt>
              <dd id={"#{@id}-exercise"} data-count>
                {if @exercise, do: F.usd_due(@exercise), else: F.usd(nil)}
              </dd>
            </div>
            <div>
              <dt>On exercise</dt>
              <dd id={"#{@id}-get"}>
                <span data-count>{if @amount, do: "#{F.tokens(@amount, @unit)} #{@symbol}", else: "—"}</span>
                <small :if={@amount && shares?(@reading)}>{shares(@amount, @reading)}</small>
              </dd>
            </div>
            <div>
              <dt>Strike</dt>
              <dd id={"#{@id}-strike"}>
                {F.usd(@listing.strike_per_token)} <small>per {@symbol}</small>
              </dd>
            </div>
            <div>
              <dt>Break-even</dt>
              <dd id={"#{@id}-break-even"}>
                {F.usd_due(@break_even)} <small>per {@symbol}</small>
              </dd>
            </div>
            <.window id={@id} expiry={@listing.expiry} />
          </dl>
          <.buyer_steps id={"#{@id}-steps"} first="Approve USDC and buy now." />
        </section>

        <.buyer_outcomes
          id={"#{@id}-outcomes"}
          symbol={@symbol}
          strike={@listing.strike_per_token}
          break_even={@break_even}
        />
      </div>
    </Regent.Structure.panel>
    """
  end

  attr :id, :string, required: true
  attr :active, :any, required: true, doc: "the value chosen"
  attr :class, :string, default: nil
  attr :rest, :global

  slot :pill, required: true do
    attr :value, :any, required: true
    attr :event, :string, required: true
    attr :name, :string, required: true, doc: "the event's value name"
    attr :label, :string, doc: "the choice's name when its words are short"
    attr :disabled, :boolean

    attr :strike, :string,
      doc: "a strike's price in dollars, or \"custom\" for the typed one, for the price line"
  end

  # One choice of a few, side by side, the chosen one marked by a block that
  # travels to it (`MotionTabs`). Each choice is a button the page hears.
  defp pills(assigns) do
    ~H"""
    <div
      id={@id}
      class={["covered-calls__pills", @class]}
      role="group"
      phx-hook="MotionTabs"
      data-active={@active}
      data-variant={AutolaunchWeb.Motion.standard("tabs")}
      style={"--pills: #{length(@pill)}"}
      {@rest}
    >
      <span
        id={"#{@id}-ink"}
        class="covered-calls__pill-ink"
        data-ink
        aria-hidden="true"
        phx-mounted={JS.ignore_attributes(["style"])}
      ></span>
      <button
        :for={pill <- @pill}
        type="button"
        data-tab={pill.value}
        aria-pressed={to_string(to_string(pill.value) == to_string(@active))}
        aria-label={pill[:label]}
        disabled={pill[:disabled]}
        data-strike={pill[:strike]}
        phx-click={pill.event}
        {%{"phx-value-#{pill.name}" => pill.value}}
      >
        {render_slot(pill)}
      </button>
    </div>
    """
  end

  # The three suggestions by their place, or empty places until the quote is in.
  defp presets([_, _, _] = presets), do: Enum.zip(@presets, presets)
  defp presets(_none), do: Enum.map(@presets, &{&1, nil})

  defp above(nil), do: "—"

  defp above(preset),
    do: "+#{:erlang.float_to_binary(preset.above_reference * 100, decimals: 1)}%"

  # The way back to the suggestion, once a different premium is typed.
  defp suggest?(%{edited?: edited?, typed: typed, suggested: suggested}),
    do: edited? and is_integer(suggested) and typed != suggested

  # A USDC price per token in dollars, as the price line draws it.
  defp dollars(nil), do: nil
  defp dollars(micro), do: micro / 1_000_000

  defp held(nil, _unit, _symbol), do: "—"
  defp held(amount, unit, symbol), do: "#{F.tokens(amount, unit)} #{symbol}"

  defp yours(nil, _unit, symbol), do: symbol
  defp yours(amount, unit, symbol), do: held(amount, unit, symbol)

  # Why a ticket's quote is missing or old, beside its receipt's title.
  defp refused(%Read{state: state, error: error}) when state in [:error, :stale],
    do: quote_refusal(error)

  defp refused(_quote), do: nil

  defp exerciser("sell"), do: "The buyer can exercise"
  defp exerciser("bid"), do: "You can exercise"

  defp strike_words("sell", symbol),
    do:
      "The price per #{symbol} the buyer pays if they exercise. Any rise above it goes to the buyer."

  defp strike_words("bid", symbol),
    do: "The price per #{symbol} you pay if you exercise. Any rise above it is yours."

  defp quote_refusal(:price_unavailable), do: "No reference price right now"
  defp quote_refusal(_unavailable), do: "The price couldn't be read"

  # A sale of `amount` into `bid` when its strike plus its premium is under
  # the reference price: what the seller ends with if it is exercised (the
  # premium less the fee, and the strike), and what that stock is priced at.
  # Nil when the bid is at or over the price, or there is no reference price.
  defp under_price(bid, amount, reading) do
    spot = spot(reading)

    if spot && bid.strike_per_token + bid.premium_per_token < spot do
      %{
        tokens: F.tokens(amount, reading.unit),
        receive:
          Terms.usdc_for(amount, bid.strike_per_token, reading.unit) +
            Terms.sale(bid, amount, reading.unit).receive,
        worth: div(amount * spot, reading.unit)
      }
    end
  end

  # The listing or bid a link names, for its ticket: the list's own, else the
  # one read from the chain for the link, while it is open there.
  defp offer(_offered, _linked, _kind, id) when not is_integer(id), do: nil

  defp offer(offered, linked, kind, id) do
    Enum.find(offered, &(&1.id == id)) ||
      case linked do
        %{kind: ^kind, id: ^id, result: {:ok, %{record: record, now: now}}} ->
          if open?(kind, record, now), do: record

        _unread ->
          nil
      end
  end

  defp open?(:listing, listing, now), do: Terms.stage(listing, now) == :open
  defp open?(:bid, bid, now), do: Terms.bid_stage(bid, now) == :open

  # Why a link opens no ticket, from the contract's own state at the latest
  # block: the only case a link is turned away. Nil while there is a ticket,
  # or the link is still being read.
  defp shut(kind, :unknown, _linked), do: "There is no #{kind} by that number."

  defp shut(kind, id, %{kind: kind, id: id, result: result}) do
    case result do
      {:ok, %{record: record, now: now}} ->
        stage_words(kind, id, record, now)

      {:error, unknown} when unknown in [:unknown_listing, :unknown_bid] ->
        shut(kind, :unknown, nil)

      {:error, _unread} ->
        "#{name(kind)} #{id} couldn't be read just now. Try again in a moment."

      :reading ->
        nil
    end
  end

  defp shut(_kind, _id, _linked), do: nil

  defp stage_words(:listing, id, listing, now) do
    case Terms.stage(listing, now) do
      :open -> nil
      :stopped -> "Listing #{id} was stopped."
      :sold -> "Listing #{id} has sold out."
      _window -> "Listing #{id} has passed its expiry."
    end
  end

  defp stage_words(:bid, id, bid, now) do
    case Terms.bid_stage(bid, now) do
      :open -> nil
      :cancelled -> "Bid #{id} was stopped."
      :sold -> "Bid #{id} has nothing left to sell into."
      :expired -> "Bid #{id} has passed its expiry."
    end
  end

  defp name(:listing), do: "Listing"
  defp name(:bid), do: "Bid"

  # Why a listing or bid opened by its link is not in the list, for its
  # ticket to say: an expiry the site doesn't list, less than a whole token
  # left, or below the best fifty of its Friday (`rank`, best first). Nil for
  # one in the list, or one opened since the reading was taken.
  defp unlisted(offer, offered, reading, rank) do
    same = Enum.filter(offered, &(&1.expiry == offer.expiry))

    cond do
      Enum.any?(offered, &(&1.id == offer.id)) -> nil
      offer.expiry not in Terms.expiries(reading.now) -> :expiry
      Terms.dust?(offer, reading.unit) -> :dust
      length(same) == Book.shown() and rank.(offer) > rank.(List.last(same)) -> :ranked
      true -> nil
    end
  end

  defp unlisted_words(:expiry, _kind, _symbol),
    do: "Not in the list: its expiry isn't one the site lists."

  defp unlisted_words(:dust, _kind, symbol), do: "Not in the list: less than 1 #{symbol} is left."

  defp unlisted_words(:ranked, :bid, _symbol),
    do: "Not in the list: #{Book.shown()} bids on its Friday pay a seller more."

  defp unlisted_words(:ranked, :listing, _symbol),
    do: "Not in the list: #{Book.shown()} listings on its Friday cost less."

  defp spot(reading) do
    case Quote.spot(reading) do
      {:ok, spot} -> spot
      {:error, :price_unavailable} -> nil
    end
  end

  defp price_words(%{price: %{updated_at: at}, now: now} = reading, symbol) do
    if spot(reading),
      do:
        "Chainlink's price for #{symbol} on Base, #{age(now - at)}. A reference, not a price you can trade at.",
      else: "Chainlink's price for #{symbol} on Base is more than four days old."
  end

  defp price_words(_reading, symbol),
    do: "Chainlink's price for #{symbol} on Base couldn't be read just now."

  # Beside the figure: it is a reference, and how old.
  defp reference(%{price: %{updated_at: at}, now: now} = reading) do
    if spot(reading), do: "Reference · #{old(now - at)}", else: "Reference"
  end

  defp reference(_reading), do: "Reference"

  defp old(seconds) when seconds >= 2 * 86_400, do: "#{div(seconds, 86_400)} days old"
  defp old(seconds) when seconds >= 2 * 3_600, do: "#{div(seconds, 3_600)} hours old"
  defp old(_seconds), do: "under 2 hours old"

  # The best price a seller or a bidder can trade at now for the ticket's
  # Friday and strike, with its size: the highest open bid for a seller, the
  # lowest listing for a bidder; nothing when the book has none on those terms.
  defp live_price("sell", t, reading, symbol) do
    reading.bids
    |> Enum.filter(&same_terms?(&1, t))
    |> Enum.max_by(& &1.premium_per_token, fn -> nil end)
    |> live_words("Best bid", reading, symbol)
  end

  defp live_price("bid", t, reading, symbol) do
    reading.listings
    |> Enum.filter(&same_terms?(&1, t))
    |> Enum.min_by(& &1.premium_per_token, fn -> nil end)
    |> live_words("Lowest ask", reading, symbol)
  end

  defp same_terms?(offer, t), do: offer.expiry == t.expiry and offer.strike_per_token == t.strike

  defp live_words(nil, _name, _reading, _symbol), do: nil

  defp live_words(offer, name, reading, symbol),
    do:
      "#{name} #{F.usd(offer.premium_per_token)} · #{F.tokens(Terms.available(offer), reading.unit)} #{symbol}"

  defp age(seconds) when seconds >= 2 * 86_400, do: "updated #{div(seconds, 86_400)} days ago"
  defp age(seconds) when seconds >= 2 * 3_600, do: "updated #{div(seconds, 3_600)} hours ago"
  defp age(_seconds), do: "updated in the last two hours"

  defp multiplier(wad) do
    wad
    |> Decimal.new()
    |> Decimal.div(Decimal.new(1_000_000_000_000_000_000))
    |> Decimal.round(4)
    |> Decimal.to_string(:normal)
  end

  defp shares?(%{multiplier: wad}), do: wad != 1_000_000_000_000_000_000

  # Under the amount: its worth at the reference price, and its share count
  # when a token is more than one share.
  defp amount_hint(%{amount: nil}, _reading), do: nil

  defp amount_hint(%{amount: amount, value: value}, reading) do
    worth = if value, do: "≈ #{F.usd(value)}"
    Enum.join(Enum.reject([worth, shares(amount, reading)], &is_nil/1), " · ")
  end

  defp shares(raw, %{multiplier: wad, unit: unit} = reading) do
    if shares?(reading), do: "#{F.tokens(Chain.shares(raw, wad), unit)} shares"
  end
end
