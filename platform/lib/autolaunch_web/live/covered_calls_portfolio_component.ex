defmodule AutolaunchWeb.CoveredCallsPortfolioComponent do
  @moduledoc """
  The portfolio's covered calls: for each market, the calls the signed-in
  wallet sold and the calls it holds, each read now from the contract
  (`Autolaunch.CoveredCalls.covered_call_positions/2`). Under each listing its
  parts, as far as they have gone: how much sold and how much is still for
  sale, then how much was exercised, the calls held, and the stock to collect.
  A part with a next step has its own wallet panel beside it (Stop selling the
  rest, Collect USDC for the exercised part, Exercise, Collect the stock), so
  every button there reviews its action, and is disabled, with the reason
  beside it, only while the chain makes it certain to fail (before Friday's
  close, Exercise says when it opens). The page re-reads it with
  `send_update(id: ..., read: true)` after a press lands, when its Refresh is
  pressed and when a listing's expiry or window closes, and hands it what a
  confirmed action moved with `send_update(id: ..., done: done)`.
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
  # its listings; every other ask reads again.
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

  defp read(socket) do
    actor = %Human{human_account_id: socket.assigns.current_human_id}

    start_async(socket, :positions, fn ->
      {:ok, %{markets: markets}} = Deployment.current()

      Enum.map(markets, &read_market(&1, actor))
    end)
  end

  defp mine?(nil, _press), do: true

  defp mine?(markets, %{listing_id: id, wallet: wallet, seller: seller}) do
    Enum.any?(markets, fn
      {_symbol, {:ok, positions}} ->
        Address.equal?(positions.wallet, wallet) or Address.equal?(positions.wallet, seller) or
          id in listing_ids(positions)

      {_symbol, {:error, _reason}} ->
        true
    end)
  end

  # When the wallet's own listings next change what they allow.
  defp changes(%{book: book} = positions) do
    mine = listing_ids(positions)

    for %{id: id, expiry: expiry} <- book.listings,
        id in mine,
        at <- [expiry, expiry + Terms.exercise_window()],
        do: at
  end

  defp listing_ids(%{sold: sold, holdings: holdings}),
    do: Enum.map(sold, & &1.id) ++ Enum.map(holdings, & &1.listing_id)

  # A listing changes what it allows at its expiry and when its window
  # closes, with no press on the chain: the section reads again just after
  # the next of those times among the wallet's own listings, each counted from
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
    case CoveredCalls.covered_call_positions(market.symbol, actor: actor) do
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
    book = positions.book
    by_id = Map.new(book.listings, &{&1.id, &1})
    holdings = Map.new(positions.holdings, &{&1.listing_id, &1})

    rows =
      (Enum.map(positions.sold, &{:sold, &1}) ++
         for(
           %{listing_id: id} <- positions.holdings,
           by_id[id].seller != positions.wallet,
           do: {:held, by_id[id]}
         ))
      |> Enum.map(fn {side, listing} ->
        row(side, listing, holdings[listing.id], positions.now)
      end)
      # An open exercise window comes first: it is the one that closes soon.
      |> Enum.sort_by(&(&1.stage != :exercise))

    assigns =
      assign(assigns,
        rows: rows,
        unit: book.unit,
        now: positions.now,
        read_at: Calendar.strftime(positions.read_at, "%-d %b, %H:%M UTC")
      )

    ~H"""
    <p :if={@unread} class="portfolio__hint" role="alert">
      Your {@symbol} covered calls couldn't be read again just now; these are from {@read_at}.
    </p>
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
        <tbody :for={row <- @rows} id={"#{@id}-#{row.side}-#{row.listing.id}"}>
          <tr>
            <td data-label="Side">{side(row.side)}</td>
            <td data-label="Strike">{F.usd(row.listing.strike_per_token)}</td>
            <td :if={row.stage != :exercise} data-label="Exercise window">
              {F.window_days(row.listing.expiry)}
            </td>
            <td :if={row.stage == :exercise} data-label="Exercise window">
              <.closes
                id={"#{@id}-#{row.side}-#{row.listing.id}-closes"}
                at={row.listing.expiry + Terms.exercise_window()}
                now={@now}
              />
            </td>
            <td data-label="Status">
              <P.status tone={row.status.tone}>{row.status.label}</P.status>
            </td>
          </tr>
          <tr :if={row.parts != []} class="portfolio__actions">
            <td colspan="4">
              <ul class="covered-calls__parts" aria-label="Parts">
                <li
                  :for={part <- row.parts}
                  id={"#{@id}-#{row.side}-#{row.listing.id}-#{part.name}"}
                >
                  <strong>{part.label}</strong>
                  <span>{figure(part.figure, @unit, @symbol)}</span>
                  <.live_component
                    :if={part.step}
                    module={CoveredCallComponent}
                    id={"#{@id}-#{part.step}-#{row.listing.id}"}
                    kind={part.step}
                    variant="secondary"
                    symbol={@symbol}
                    unit={@unit}
                    listing={row.listing}
                    holding={row.holding && row.holding.held}
                    session_lease={@session_lease}
                    current_human_id={@current_human_id}
                  />
                </li>
              </ul>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <div :if={@rows == []} class="market-list__scroll market-list__empty">
      <h2>No covered calls yet</h2>
      <p>Calls you sell or buy on {@symbol} appear here.</p>
      <.link navigate={~p"/stock/covered-call"} class="rg-button rg-button--secondary">Covered calls</.link>
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

  defp row(side, listing, holding, now) do
    stage = Terms.stage(listing, now)

    %{
      side: side,
      stage: stage,
      listing: listing,
      holding: holding,
      status: status(side, stage),
      parts: parts(side, stage, listing, holding)
    }
  end

  defp side(:sold), do: "Seller"
  defp side(:held), do: "Buyer"

  # Each part of a listing for the wallet's side of it, as far as it has gone,
  # and the step each part still has. The seller can stop selling the unsold
  # part until its stock is returned, before the expiry or after it (For sale,
  # then Unsold); the strike for the exercised part is collected from the
  # expiry on; held calls are exercised in the window and lapse after it. To
  # collect is the stock no other part shows that comes back: what was stopped
  # or exercised, and for a seller from the expiry on the calls sold and not
  # exercised (its button saying so until the window closes, when the chain
  # also counts the unsold part in what it returns).
  @parts [:sold, :for_sale, :unsold, :exercised, :held, :lapsed, :to_collect]
  @after_expiry [:exercise, :closed]
  @no_holding %{held: 0, claimable: 0}

  defp parts(side, stage, listing, holding) do
    %{held: held, claimable: claimable} = holding || @no_holding
    unsold = unsold(side, listing)

    facts = %{
      side: side,
      stage: stage,
      listing: listing,
      held: held,
      unsold: unsold,
      to_collect: to_collect(side, stage, listing, claimable, unsold)
    }

    @parts |> Enum.map(&part(&1, facts)) |> Enum.reject(&is_nil/1)
  end

  defp part(:sold, %{side: :sold, listing: %{amount: amount, filled: filled}}) when amount > 0,
    do: %{name: :sold, label: "Sold", figure: {filled, amount}, step: nil}

  defp part(:for_sale, %{unsold: unsold, stage: stage})
       when unsold > 0 and stage not in @after_expiry,
       do: %{name: :for_sale, label: "For sale", figure: unsold, step: :cancel}

  defp part(:unsold, %{unsold: unsold, stage: stage})
       when unsold > 0 and stage in @after_expiry,
       do: %{name: :unsold, label: "Unsold", figure: unsold, step: :cancel}

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

  defp part(:to_collect, %{to_collect: to_collect}) when to_collect > 0,
    do: %{name: :to_collect, label: "To collect", figure: to_collect, step: :claim}

  defp part(_name, _facts), do: nil

  # What the seller has not sold, until its stock is returned.
  defp unsold(:sold, %{stock_returned: false} = listing), do: Terms.available(listing)
  defp unsold(_side, _listing), do: 0

  # The stock the chain lets the wallet claim, as the page counts it: for a
  # seller in the window also the calls sold and not exercised, and once the
  # window has closed without the unsold part, which shows as its own.
  defp to_collect(:sold, :exercise, %{stock_returned: false} = listing, claimable, _unsold),
    do: claimable + listing.filled - listing.exercised

  defp to_collect(:sold, :closed, _listing, claimable, unsold), do: claimable - unsold
  defp to_collect(_side, _stage, _listing, claimable, _unsold), do: claimable

  # The strike for the exercised part is collected through the window, and
  # after it while any is still due.
  defp strike_step(:exercise, _listing), do: :collect_strike
  defp strike_step(:closed, listing), do: if(Terms.strike_due(listing) > 0, do: :collect_strike)

  defp figure({part, whole}, unit, symbol),
    do: "#{F.tokens(part, unit)} of #{F.tokens(whole, unit)} #{symbol}"

  defp figure(amount, unit, symbol), do: "#{F.tokens(amount, unit)} #{symbol}"

  # Each stage as a short status and its tone: the exercise window is the one that asks for action.
  defp status(_side, :open), do: %{label: "Open", tone: "info"}
  defp status(_side, :sold), do: %{label: "Sold out", tone: "neutral"}
  defp status(_side, :stopped), do: %{label: "Stopped", tone: "neutral"}
  # Only a holder has something to do in the window.
  defp status(:held, :exercise), do: %{label: "Exercise", tone: "warning"}
  defp status(:sold, :exercise), do: %{label: "Exercising", tone: "neutral"}
  defp status(_side, :closed), do: %{label: "Closed", tone: "neutral"}
end
