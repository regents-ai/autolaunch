defmodule AutolaunchWeb.CoveredCallsPortfolioComponent do
  @moduledoc """
  The portfolio's covered calls: for each market, the calls the signed-in
  wallet sold (with Stop selling, Collect USDC and Collect stock) and the calls
  it holds (with Exercise and Collect stock), each read now from the contract
  (`Autolaunch.CoveredCalls.covered_call_positions/2`). Every action of the
  wallet's side of a listing is its own wallet panel under the row, so every
  button there reviews its action, and is disabled, with the reason beside
  it, only while the chain makes it certain to fail (before Friday's close,
  Exercise says when it opens). A listing with nothing left to do for this
  wallet shows no buttons. The page re-reads it with
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
            <th scope="col">Calls</th>
            <th scope="col">Strike</th>
            <th scope="col">Exercise window</th>
            <th scope="col">Status</th>
          </tr>
        </thead>
        <tbody :for={row <- @rows} id={"#{@id}-#{row.side}-#{row.listing.id}"}>
          <tr>
            <td data-label="Calls">{describe(row.what, @unit, @symbol)}</td>
            <td data-label="Strike">{F.usd(row.listing.strike_per_token)}</td>
            <td data-label="Exercise window">{F.window_days(row.listing.expiry)}</td>
            <td data-label="Status">{row.status}</td>
          </tr>
          <tr :if={row.actions != []} class="portfolio__actions">
            <td colspan="4">
              <div>
                <.live_component
                  :for={kind <- row.actions}
                  module={CoveredCallComponent}
                  id={"#{@id}-#{kind}-#{row.listing.id}"}
                  kind={kind}
                  symbol={@symbol}
                  unit={@unit}
                  listing={row.listing}
                  holding={row.holding && row.holding.held}
                  session_lease={@session_lease}
                  current_human_id={@current_human_id}
                />
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <div :if={@rows == []} class="market-list__scroll market-list__empty">
      <h2>No covered calls yet</h2>
      <p>Calls you sell or buy on {@symbol} appear here.</p>
      <.link navigate={~p"/covered-calls"} class="rg-button rg-button--secondary">Covered calls</.link>
    </div>
    """
  end

  defp row(side, listing, holding, now) do
    stage = Terms.stage(listing, now)
    claimable = (holding && holding.claimable) || 0

    %{
      side: side,
      listing: listing,
      holding: holding,
      what: what(side, listing, holding),
      status: status(side, stage, listing, holding),
      actions: actions(side, stage, listing, holding, claimable)
    }
  end

  defp what(:sold, listing, _holding), do: {:sold, listing.filled, listing.amount}
  defp what(:held, _listing, %{held: held}), do: {:held, held}

  defp describe({:sold, filled, amount}, unit, symbol),
    do: "Sold #{F.tokens(filled, unit)} of #{F.tokens(amount, unit)} #{symbol}"

  defp describe({:held, held}, unit, symbol), do: "Holding #{F.tokens(held, unit)} #{symbol}"

  defp status(_side, :open, _listing, _holding), do: "Open"
  defp status(_side, :sold, _listing, _holding), do: "Sold out, open"

  defp status(_side, :exercise, listing, _holding),
    do: "Exercise open until #{F.window_closes(listing.expiry)}"

  defp status(_side, :closed, _listing, _holding), do: "Closed"

  # Every action of the wallet's side of a listing that the chain may still
  # allow, each disabled with its reason while it is certain to fail now:
  # Exercise while calls are held and the window has not closed, Stop selling
  # while some is unsold, and each Collect until the window has closed with
  # nothing left to collect. A listing with nothing left for this wallet
  # shows none.
  defp actions(side, stage, listing, holding, claimable) do
    open? = stage != :closed

    for {kind, offered?} <- [
          exercise: open? and holding != nil and holding.held > 0,
          cancel: side == :sold and unsold?(listing),
          collect_strike: side == :sold and (open? or Terms.strike_due(listing) > 0),
          claim: open? or claimable > 0
        ],
        offered?,
        do: kind
  end

  defp unsold?(listing), do: Terms.available(listing) > 0 and not listing.stock_returned
end
