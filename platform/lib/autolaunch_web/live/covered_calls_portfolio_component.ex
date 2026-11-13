defmodule AutolaunchWeb.CoveredCallsPortfolioComponent do
  @moduledoc """
  The portfolio's covered calls: for each market, the calls the signed-in
  wallet sold, the calls it holds and the bids it made, each read now from the
  contract (`Autolaunch.CoveredCalls.read_covered_call_positions/2`), under a
  line naming the stock by issuer, chain and address, with the contract's
  address. Every row gives its exercise window as the times it opens and
  closes, in the reader's own time, and counts it down once open. Under each
  listing its parts, each on its own: how much sold and the premium that
  paid, how much is still for sale, the stock locked under calls a buyer can
  still exercise, how much was exercised, the calls held, and the stock to
  collect, which is only what the contract sends now. Under each bid how much
  was sold into it, the premium it still holds and what a refund sends now;
  calls sold into a bid are the bidder's held calls like any others. A part
  with a next step has its own wallet panel
  beside it (Stop selling the rest, Collect USDC for the exercised part,
  Exercise, Collect the stock; Raise, Stop and Refund a bid), so every button
  there reviews its action, and is disabled, with the reason beside it, only
  while the chain makes it certain to fail (before Friday's close, Exercise
  says when it opens). The page re-reads it with `send_update(id: ...,
  read: true)` after a press lands, when its Refresh is pressed and when a
  listing's or bid's expiry or a window closes, and hands it what a confirmed
  action moved with `send_update(id: ..., done: done)`.
  """
  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.CoveredCalls
  alias Autolaunch.CoveredCalls.{Deployment, Terms}
  alias AutolaunchWeb.CoveredCallComponent
  alias AutolaunchWeb.CoveredCallsFormat, as: F
  alias Phoenix.LiveView.AsyncResult
  alias Regent.Primitives, as: P
  alias RegentChain.Address

  # Refusals that mean the chain could not be read just now.
  @chain_unreadable [:chain_unavailable, :invalid_chain_response, :invalid_block_header]

  @impl true
  def mount(socket),
    do:
      {:ok,
       assign(socket,
         positions: AsyncResult.loading(),
         read_for: nil,
         done: nil,
         due: nil,
         unread: []
       )}

  # A press reads again only when it came from this wallet or was on one of
  # its listings or bids; every other ask reads again.
  @impl true
  def update(%{read: true, pressed: press}, socket),
    do: {:ok, if(mine?(socket.assigns.positions.result, press), do: read(socket), else: socket)}

  def update(%{read: true}, socket), do: {:ok, read(socket)}
  def update(%{done: done}, socket), do: {:ok, assign(socket, done: done)}

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if socket.assigns.read_for == socket.assigns.current_human_id,
      do: {:ok, socket},
      else: {:ok, socket |> assign(read_for: socket.assigns.current_human_id) |> read()}
  end

  @impl true
  def handle_event("dismiss_done", _params, socket), do: {:noreply, assign(socket, done: nil)}

  # A market the chain can't be read for just now keeps what was last read of
  # it, with a note, so its rows and any review open on them stay where they
  # are. Any other refusal (the wallet is no longer the account's) shows as is.
  @impl true
  def handle_async(:positions, {:ok, markets}, socket) do
    before = Map.new(socket.assigns.positions.result || [])

    {kept, unread} =
      Enum.map_reduce(markets, [], fn
        {symbol, {:error, reason}} = failed, unread ->
          case {reason in @chain_unreadable, before[symbol]} do
            {true, {:ok, _positions} = last} -> {{symbol, last}, [symbol | unread]}
            _shown_as_is -> {failed, unread}
          end

        read, unread ->
          {read, unread}
      end)

    {:noreply,
     socket
     |> assign(positions: AsyncResult.ok(socket.assigns.positions, kept), unread: unread)
     |> read_when_due(kept)}
  end

  def handle_async(:positions, {:exit, reason}, socket),
    do:
      {:noreply, assign(socket, positions: AsyncResult.failed(socket.assigns.positions, reason))}

  # A new read stops the one still running, so asks never stack.
  defp read(socket) do
    actor = %Human{human_account_id: socket.assigns.current_human_id}

    socket
    |> cancel_async(:positions)
    |> start_async(:positions, fn ->
      {:ok, %{markets: markets}} = Deployment.current()

      Enum.map(markets, &read_market(&1, actor))
    end)
  end

  defp mine?(nil, _press), do: true

  defp mine?(markets, press) do
    Enum.any?(markets, fn
      {_symbol, {:ok, positions}} ->
        Enum.any?(
          [press.wallet, press.seller, press.bidder],
          &Address.equal?(positions.wallet, &1)
        ) or
          press.listing_id in listing_ids(positions) or
          press.bid_id in Enum.map(positions.bids, & &1.id)

      {_symbol, {:error, _reason}} ->
        true
    end)
  end

  # When the wallet's own listings and bids next change what they allow.
  defp changes(%{sold: sold, holdings: holdings, bids: bids}) do
    for(
      %{expiry: expiry} <- sold ++ Enum.map(holdings, & &1.listing),
      at <- [expiry, expiry + Terms.exercise_window()],
      do: at
    ) ++ Enum.map(bids, & &1.expiry)
  end

  defp listing_ids(%{sold: sold, holdings: holdings}),
    do: Enum.map(sold, & &1.id) ++ Enum.map(holdings, & &1.listing_id)

  # A listing changes what it allows at its expiry and when its window
  # closes, and a bid at its expiry, with no press on the chain: the section
  # reads again just after the next of those times among the wallet's own
  # listings and bids, each counted from
  # the block its figures were read at: a read that lands on a node a moment
  # behind a change, or fails and keeps older figures, is timed again for it
  # (the page passes `:covered_calls_due` back as `read: true`).
  defp read_when_due(socket, markets) do
    if socket.assigns.due, do: Process.cancel_timer(socket.assigns.due)

    wait =
      markets
      |> Enum.flat_map(fn
        {_symbol, {:ok, positions}} ->
          List.wrap(Terms.next_wait(changes(positions), positions.now))

        {_symbol, {:error, _reason}} ->
          []
      end)
      |> Enum.min(fn -> nil end)

    assign(socket,
      due: wait && Process.send_after(self(), :covered_calls_due, (wait + 5) * 1_000)
    )
  end

  defp read_market(market, actor) do
    case CoveredCalls.read_covered_call_positions(market.symbol, actor: actor) do
      {:ok, positions} -> {market.symbol, {:ok, positions}}
      {:error, error} -> {market.symbol, {:error, CoveredCalls.reason(error)}}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="portfolio__section" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"} class="portfolio__title">Covered calls</h2>
      <CoveredCallComponent.toast
        :if={@done}
        id={"#{@id}-done"}
        done={@done}
        dismiss="dismiss_done"
        target={@myself}
        portfolio={false}
      />
      <p :if={@positions.failed} class="portfolio__hint" role="alert">
        Your covered calls are unavailable right now.
      </p>
      <div :if={@positions.loading} class="market-list__scroll" aria-busy="true">
        <span class="loading-block"></span>
      </div>
      <.market
        :for={{symbol, read} <- @positions.result || []}
        id={@id}
        symbol={symbol}
        read={read}
        unread={symbol in @unread}
        myself={@myself}
        session_lease={@session_lease}
        current_human_id={@current_human_id}
      />
    </section>
    """
  end

  defp market(%{read: {:error, :wallet_required}} = assigns) do
    ~H"""
    <p class="portfolio__hint" role="alert">
      Your account has no wallet yet, so it has no {@symbol} covered calls.
    </p>
    """
  end

  defp market(%{read: {:error, _reason}} = assigns) do
    ~H"""
    <p class="portfolio__hint" role="alert">
      Your {@symbol} covered calls couldn't be read just now.
    </p>
    """
  end

  defp market(%{read: {:ok, positions}} = assigns) do
    holdings = Map.new(positions.holdings, &{&1.listing_id, &1})

    rows =
      (Enum.map(positions.sold, &{:sold, &1}) ++
         for(
           %{listing: listing} <- positions.holdings,
           listing.seller != positions.wallet,
           do: {:held, listing}
         ))
      |> Enum.map(fn {side, listing} ->
        row(side, listing, holdings[listing.id], positions.unit, positions.now)
      end)
      |> Enum.concat(Enum.map(positions.bids, &bid_row(&1, positions.unit, positions.now)))
      # An open exercise window comes first: it is the one that closes soon.
      |> Enum.sort_by(&(&1.stage != :exercise))

    assigns =
      assign(assigns,
        rows: rows,
        market: positions.market,
        unit: positions.unit,
        now: positions.now,
        read_at: Calendar.strftime(positions.read_at, "%-d %b, %H:%M UTC")
      )

    ~H"""
    <p :if={@unread} class="portfolio__hint" role="alert">
      Your {@symbol} covered calls couldn't be read again just now; these are from {@read_at}.
    </p>
    <div :if={@rows != []} id={"#{@id}-#{@symbol}-identity"} class="covered-calls__identity">
      <CoveredCallComponent.stock id={"#{@id}-#{@symbol}-stock"} market={@market} />
      <p class="covered-calls__stock">
        Contract <P.address id={"#{@id}-#{@symbol}-contract"} address={@market.contract} />
      </p>
    </div>
    <div :if={@rows != []} class="market-list__scroll">
      <table class="market-list__table portfolio__table covered-calls__table">
        <caption class="visually-hidden">Your {@symbol} covered calls</caption>
        <thead>
          <tr>
            <th scope="col">Side</th>
            <th scope="col">Strike</th>
            <th scope="col">Exercise window</th>
            <th scope="col">Status</th>
          </tr>
        </thead>
        <tbody :for={row <- @rows} id={"#{@id}-#{row.key}"}>
          <tr>
            <td data-label="Side">{row.side}</td>
            <td data-label="Strike">{F.usd(row.strike)}</td>
            <td :if={row.window == :ahead} data-label="Exercise window">
              <span class="covered-calls__window">
                <span>
                  Opens
                  <CoveredCallComponent.local_time
                    id={"#{@id}-#{row.key}-window-opens"}
                    at={row.expiry}
                  />
                </span>
                <span>
                  Closes
                  <CoveredCallComponent.local_time
                    id={"#{@id}-#{row.key}-window-closes"}
                    at={row.expiry + Terms.exercise_window()}
                  />
                </span>
              </span>
            </td>
            <td :if={row.window == :open} data-label="Exercise window">
              <.closes
                id={"#{@id}-#{row.key}-closes"}
                at={row.expiry + Terms.exercise_window()}
                now={@now}
              />
            </td>
            <td :if={row.window == :past} data-label="Exercise window">
              {F.window(row.expiry)}
            </td>
            <td data-label="Status">
              <P.status tone={row.status.tone}>{row.status.label}</P.status>
            </td>
          </tr>
          <tr :if={row.parts != []} class="portfolio__actions">
            <td colspan="4">
              <ul class="covered-calls__parts" aria-label="Parts">
                <li :for={part <- row.parts} id={"#{@id}-#{row.key}-#{part.name}"}>
                  <strong>{part.label}</strong>
                  <span>{figure(part.figure, @unit, @symbol)}</span>
                  <small :if={part[:note]}>{part.note}</small>
                  <.live_component
                    :if={part.step}
                    module={CoveredCallComponent}
                    id={"#{@id}-#{part.step}-#{row.id}"}
                    kind={part.step}
                    variant="secondary"
                    symbol={@symbol}
                    unit={@unit}
                    session_lease={@session_lease}
                    current_human_id={@current_human_id}
                    {row.on}
                  />
                </li>
              </ul>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <div :if={@rows == []} class="market-list__scroll market-list__empty">
      <h2>No calls</h2>
      <p>Calls you sell or buy on {@symbol} appear here.</p>
      <.link navigate={~p"/stock/covered-call"} class="rg-button rg-button--secondary">Trade calls</.link>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :at, :integer, required: true, doc: "when the window closes, Unix seconds"
  attr :now, :integer, required: true, doc: "the chain's time at the reading"

  # An open window's time left, counted down in the browser from the chain's
  # time at the reading (`Countdown`), over when it closes in the reader's time.
  defp closes(assigns) do
    ~H"""
    <span class="covered-calls__closes">
      <strong id={@id} phx-hook="Countdown" data-closes={@at} data-now={@now}>
        {F.closes_in(@at - @now)}
      </strong>
      <span><CoveredCallComponent.local_time id={"#{@id}-at"} at={@at} /></span>
    </span>
    """
  end

  # A row: its key in the page's ids, the listing's or bid's id for its
  # panels', what its panels act on (`on`), and its figures, status and parts.
  defp row(side, listing, holding, unit, now) do
    stage = Terms.stage(listing, now)

    %{
      key: "#{side}-#{listing.id}",
      id: listing.id,
      on: %{listing: listing, holding: holding && holding.held},
      side: side(side),
      strike: listing.strike_per_token,
      expiry: listing.expiry,
      stage: stage,
      window: window(listing.expiry, stage, now),
      status: status(side, stage),
      parts: parts(side, stage, listing, holding, unit)
    }
  end

  defp bid_row(bid, unit, now) do
    stage = Terms.bid_stage(bid, now)

    %{
      key: "bid-#{bid.id}",
      id: bid.id,
      on: %{bid: bid},
      side: "Bidder",
      strike: bid.strike_per_token,
      expiry: bid.expiry,
      stage: stage,
      window: window(bid.expiry, stage, now),
      status: bid_status(stage),
      parts: bid_parts(bid, stage, unit)
    }
  end

  # Where a row's exercise window stands: still ahead, open (a listing in its
  # window), or past.
  defp window(expiry, _stage, now) when now < expiry, do: :ahead
  defp window(_expiry, :exercise, _now), do: :open
  defp window(_expiry, _stage, _now), do: :past

  defp side(:sold), do: "Seller"
  defp side(:held), do: "Buyer"

  # A bid's parts: how much was sold into it, of what it asks while it is open
  # or expired (a closed bid's amount is only what was sold), raised while it is
  # open; the premium it still holds for the rest, which Stop frees while it is
  # open; and what a refund sends now (the freed premium, and after the expiry
  # what was never spent).
  defp bid_parts(bid, stage, unit) do
    [
      bid.amount > 0 &&
        %{
          name: :sold,
          label: "Sold",
          figure: if(stage == :sold, do: bid.filled, else: {bid.filled, bid.amount}),
          step: if(stage == :open, do: :raise_bid)
        },
      stage == :open &&
        %{
          name: :escrow,
          label: "Unspent",
          figure: {:usd, Terms.escrow_left(bid, unit)},
          step: :cancel_bid
        },
      bid.refundable > 0 &&
        %{name: :refund, label: "Refund", figure: {:usd, bid.refundable}, step: :refund_bid}
    ]
    |> Enum.filter(& &1)
  end

  # Each part of a listing for the wallet's side of it, each amount on its own,
  # and the step each part still has. Sold is what buyers bought, and Premium
  # what that paid the seller. The seller can stop selling the unsold part
  # before the expiry (For sale) and through the window (Unsold). Locked is
  # the stock under calls sold and not exercised until the window closes: a
  # buyer can still take it, so it is never counted as stock to collect. The
  # strike for the exercised part is collected from the expiry on; held calls
  # are exercised in the window and lapse after it. To collect is exactly what
  # the contract sends the wallet now (`claimable`): for a seller once the
  # window has closed that is all the stock not exercised, the unsold part
  # with it, said in words beside it.
  @parts [:sold, :premium, :for_sale, :unsold, :locked, :exercised, :held, :lapsed, :to_collect]
  @after_expiry [:exercise, :closed]
  @no_holding %{held: 0, claimable: 0}

  defp parts(side, stage, listing, holding, unit) do
    %{held: held, claimable: claimable} = holding || @no_holding

    facts = %{
      side: side,
      stage: stage,
      listing: listing,
      unit: unit,
      held: held,
      unsold: unsold(side, listing),
      locked: locked(side, stage, listing),
      to_collect: claimable
    }

    @parts |> Enum.map(&part(&1, facts)) |> Enum.reject(&is_nil/1)
  end

  defp part(:sold, %{side: :sold, listing: %{amount: amount, filled: filled}}) when amount > 0,
    do: %{name: :sold, label: "Sold", figure: {filled, amount}, step: nil}

  # What the sold part paid: its premium less the 1% fee, as the listing's
  # totals count it. The contract rounds each purchase on its own, so what
  # arrived can differ by a millionth of a dollar a purchase.
  defp part(:premium, %{side: :sold, listing: %{filled: filled} = listing, unit: unit})
       when filled > 0 do
    premium = Terms.usdc_for(filled, listing.premium_per_token, unit)

    %{
      name: :premium,
      label: "Premium",
      figure: {:about_usd, premium - Terms.fee(premium)},
      note: "Paid to your wallet as buyers bought",
      step: nil
    }
  end

  defp part(:for_sale, %{unsold: unsold, stage: stage})
       when unsold > 0 and stage not in @after_expiry,
       do: %{name: :for_sale, label: "For sale", figure: unsold, step: :cancel}

  defp part(:unsold, %{unsold: unsold, stage: :exercise}) when unsold > 0,
    do: %{name: :unsold, label: "Unsold", figure: unsold, step: :cancel}

  defp part(:locked, %{locked: locked, listing: listing}) when locked > 0 do
    %{
      name: :locked,
      label: "Locked",
      figure: locked,
      note: "Returns after #{F.window_closes(listing.expiry)} unless exercised",
      step: nil
    }
  end

  defp part(:exercised, %{side: :sold, stage: stage, listing: %{filled: filled} = listing})
       when stage in @after_expiry and filled > 0 do
    %{
      name: :exercised,
      label: "Exercised",
      figure: {listing.exercised, filled},
      step: strike_step(stage, listing)
    }
  end

  defp part(:held, %{held: held, stage: stage}) when held > 0 and stage != :closed,
    do: %{name: :held, label: "Held", figure: held, step: :exercise}

  defp part(:lapsed, %{held: held, stage: :closed}) when held > 0,
    do: %{name: :lapsed, label: "Lapsed", figure: held, step: nil}

  defp part(:to_collect, %{to_collect: to_collect} = facts) when to_collect > 0 do
    %{
      name: :to_collect,
      label: "To collect",
      figure: to_collect,
      note: returned(facts),
      step: :claim
    }
  end

  defp part(_name, _facts), do: nil

  # What the seller has not sold, until its stock is returned.
  defp unsold(:sold, %{stock_returned: false} = listing), do: Terms.available(listing)
  defp unsold(_side, _listing), do: 0

  # The seller's stock under calls sold and not exercised, until the window
  # closes: buyers may still exercise them.
  defp locked(:sold, stage, %{stock_returned: false} = listing) when stage != :closed,
    do: listing.filled - listing.exercised

  defp locked(_side, _stage, _listing), do: 0

  # Once the window has closed, what a seller's collection is made of.
  defp returned(%{side: :sold, stage: :closed, listing: %{stock_returned: false}} = facts) do
    %{listing: listing, unsold: unsold, unit: unit} = facts

    [{unsold, "unsold"}, {listing.filled - listing.exercised, "not exercised"}]
    |> Enum.filter(fn {amount, _words} -> amount > 0 end)
    |> Enum.map_join(", ", fn {amount, words} -> "#{F.tokens(amount, unit)} #{words}" end)
    |> case do
      "" -> nil
      words -> words
    end
  end

  defp returned(_facts), do: nil

  # The strike for the exercised part is collected through the window, and
  # after it while any is still due.
  defp strike_step(:exercise, _listing), do: :collect_strike
  defp strike_step(:closed, listing), do: if(Terms.strike_due(listing) > 0, do: :collect_strike)

  defp figure({:usd, micro}, _unit, _symbol), do: F.usd(micro)
  defp figure({:about_usd, micro}, _unit, _symbol), do: "≈ " <> F.usd(micro)

  defp figure({part, whole}, unit, symbol),
    do: "#{F.tokens(part, unit)} of #{F.tokens(whole, unit)} #{symbol}"

  defp figure(amount, unit, symbol), do: "#{F.tokens(amount, unit)} #{symbol}"

  # Each stage as a short status and its tone: the exercise window is the one that asks for action.
  # A holder's calls are theirs until they exercise or the window closes,
  # however much of the listing is left for others.
  defp status(:held, stage) when stage in [:open, :sold], do: %{label: "Held", tone: "info"}
  defp status(_side, :open), do: %{label: "Open", tone: "info"}
  defp status(_side, :sold), do: %{label: "Sold out", tone: "neutral"}
  defp status(_side, :stopped), do: %{label: "Stopped", tone: "neutral"}
  # Only a holder has something to do in the window.
  defp status(:held, :exercise), do: %{label: "Exercise", tone: "warning"}
  defp status(:sold, :exercise), do: %{label: "Window open", tone: "neutral"}
  defp status(_side, :closed), do: %{label: "Closed", tone: "neutral"}

  # A bid stopped after part of it sold reads as sold (`Terms.bid_stage/2`), so
  # both read as closed.
  defp bid_status(:open), do: %{label: "Open", tone: "info"}
  defp bid_status(:sold), do: %{label: "Closed", tone: "neutral"}
  defp bid_status(:cancelled), do: %{label: "Stopped", tone: "neutral"}
  defp bid_status(:expired), do: %{label: "Expired", tone: "neutral"}
end
