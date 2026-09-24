defmodule AutolaunchWeb.PortfolioLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers

  alias Autolaunch.Robinhood.Positions, as: RobinhoodPositions
  alias Autolaunch.TokenHoldings
  alias AutolaunchWeb.LabMarket

  @history ~w(claimed exited returned)

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:refreshed_at, nil)
     |> assign(:status, :ready)
     |> assign(:positions, [])
     |> assign(:returnable_positions, [])
     |> assign(:claimable_positions, [])
     |> assign(:token_holdings, :loading)
     |> assign(:robinhood_positions, :loading)
     |> assign(:market, LabMarket.subscribe(socket))
     |> load_signed_in_holdings()}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("refresh", _params, socket) do
    socket = load_signed_in_holdings(socket)

    {:noreply,
     assign(socket, :refreshed_at, if(socket.assigns.status == :ready, do: DateTime.utc_now()))}
  end

  # The lab feeds moved: positions may have become returnable or claimable,
  # and a trade may have changed what the wallets hold.
  def handle_info({event, _update}, socket)
      when event in [:autolaunch_market_updated, :robinhood_market_updated] do
    market = LabMarket.snapshot()

    if market.generation > socket.assigns.market.generation,
      do: {:noreply, socket |> assign(:market, market) |> load_signed_in_holdings()},
      else: {:noreply, socket}
  end

  # A settlement card verified a step, so the stored position changed.
  def handle_info({:bid_settlement_changed, _position_id}, socket),
    do: {:noreply, load_signed_in_holdings(socket)}

  def handle_async(:token_holdings, {:ok, {:ok, holdings}}, socket),
    do: {:noreply, assign(socket, :token_holdings, holdings)}

  def handle_async(:token_holdings, _failed, socket),
    do: {:noreply, assign(socket, :token_holdings, :error)}

  def handle_async(:robinhood_positions, {:ok, {:ok, positions}}, socket),
    do: {:noreply, assign(socket, :robinhood_positions, positions)}

  def handle_async(:robinhood_positions, _failed, socket),
    do: {:noreply, assign(socket, :robinhood_positions, :error)}

  def render(assigns) do
    {history, current} = Enum.split_with(assigns.positions, &(&1.status in @history))

    assigns =
      assign(assigns,
        history: history,
        current: Enum.sort_by(current, &(&1.status not in ["returnable", "claimable"]))
      )

    ~H"""
    <section id="autolaunch-holdings" class="autolaunch-page autolaunch-compact-detail">
      <header class="autolaunch-heading">
        <p class="autolaunch-kicker">Autolaunch · Portfolio</p>
        <Regent.Structure.section_bar>
          <h1 class="rg-section-bar__label">Your portfolio</h1>
        </Regent.Structure.section_bar>
        <p>Bids and tokens from your verified wallets.</p>
        <Regent.Primitives.button
          :if={@account_control.kind != :sign_in}
          id="portfolio-refresh"
          variant="secondary"
          phx-click="refresh"
        >
          Refresh
        </Regent.Primitives.button>
        <p :if={@refreshed_at} role="status" class="autolaunch-refresh-status">
          Updated {Calendar.strftime(@refreshed_at, "%H:%M:%S UTC")}
        </p>
      </header>

      <section :if={@account_control.kind == :sign_in} class="autolaunch-empty portfolio-sign-in">
        <h2>Connect to your portfolio</h2>
        <p>Sign in to see bids and tokens from your verified wallets.</p>
        <Regent.Primitives.button
          type="button"
          class="account-control__sign-in"
          data-account-target="sign-in"
        >Sign in</Regent.Primitives.button>
        <.link navigate="/">Keep exploring</.link>
      </section>

      <p
        :if={@account_control.kind != :sign_in && @status == :error}
        class="autolaunch-empty"
        role="alert"
      >
        Your portfolio is unavailable right now.
      </p>

      <div :if={@account_control.kind != :sign_in && @status == :ready}>
        <dl>
          <div>
            <dt>Bid positions</dt><dd>{length(@positions)}</dd>
          </div>
          <div>
            <dt>Returnable</dt><dd>{length(@returnable_positions)}</dd>
          </div>
          <div>
            <dt>Claimable</dt><dd>{length(@claimable_positions)}</dd>
          </div>
          <div>
            <dt>Tokens held</dt>
            <dd>{if is_map(@token_holdings), do: length(@token_holdings.holdings), else: "–"}</dd>
          </div>
        </dl>

        <section id="autolaunch-held-tokens" aria-labelledby="autolaunch-held-tokens-title">
          <Regent.Structure.section_bar>
            <h2 class="rg-section-bar__label" id="autolaunch-held-tokens-title">Tokens</h2>
          </Regent.Structure.section_bar>
          <p :if={@token_holdings == :loading} class="autolaunch-empty" role="status">
            Reading your wallets…
          </p>
          <p :if={@token_holdings == :error} class="autolaunch-empty" role="alert">
            Your token balances are unavailable right now.
          </p>
          <p :if={is_map(@token_holdings) && @token_holdings.holdings == []} class="autolaunch-empty">
            Tokens held or staked by your verified wallets will appear here.
            <.link navigate="/tokens">Explore tokens</.link>
          </p>
          <ol
            :if={is_map(@token_holdings) && @token_holdings.holdings != []}
            class="autolaunch-record-list"
          >
            <li :for={holding <- @token_holdings.holdings}>
              <.link navigate={holding.href}>
                <strong>{holding.name} · {holding.symbol}</strong>
                <span>{holding_copy(holding)}</span>
                <span>{chain_name(holding.chain)}</span>
              </.link>
            </li>
          </ol>
          <p
            :if={is_map(@token_holdings) && @token_holdings.blocks != %{}}
            class="autolaunch-refresh-status"
          >
            {blocks_copy(@token_holdings.blocks)}
          </p>
        </section>

        <section id="autolaunch-bid-positions" aria-labelledby="autolaunch-bid-positions-title">
          <Regent.Structure.section_bar>
            <h2 class="rg-section-bar__label" id="autolaunch-bid-positions-title">Bid positions</h2>
          </Regent.Structure.section_bar>
          <p :if={@positions == []} class="autolaunch-empty">
            Bids from your verified wallets will appear here.
            <.link navigate="/auctions">Explore auctions</.link>
          </p>
          <p :if={@positions != [] && @current == []}>No active bids.</p>
          <p :if={@market.head} class="autolaunch-refresh-status">
            {chain_name(:base)} read at block {@market.head.number}
          </p>
          <.position_list
            :if={@current != []}
            positions={@current}
            market={@market}
            account_control={@account_control}
            access_context={@access_context}
            session_lease={@session_lease}
          />
        </section>

        <Regent.Primitives.disclosure
          :if={@history != []}
          id="portfolio-history"
          summary={"Past bids · #{length(@history)}"}
        >
          <.position_list
            positions={@history}
            market={@market}
            account_control={@account_control}
            access_context={@access_context}
            session_lease={@session_lease}
          />
        </Regent.Primitives.disclosure>

        <section
          :if={Autolaunch.Robinhood.Lab.configured?()}
          id="autolaunch-robinhood-bids"
          aria-labelledby="autolaunch-robinhood-bids-title"
        >
          <Regent.Structure.section_bar>
            <h2 class="rg-section-bar__label" id="autolaunch-robinhood-bids-title">
              Robinhood bids
            </h2>
          </Regent.Structure.section_bar>
          <p :if={@robinhood_positions == :loading} class="autolaunch-empty" role="status">
            Reading your wallets…
          </p>
          <p :if={@robinhood_positions == :error} class="autolaunch-empty" role="alert">
            Your Robinhood bids are unavailable right now.
          </p>
          <p
            :if={is_map(@robinhood_positions) && @robinhood_positions.positions == []}
            class="autolaunch-empty"
          >
            Bids from your verified wallets on Robinhood auctions will appear here.
            <.link navigate="/auctions">Explore auctions</.link>
          </p>
          <ol
            :if={is_map(@robinhood_positions) && @robinhood_positions.positions != []}
            class="autolaunch-record-list"
          >
            <li
              :for={position <- @robinhood_positions.positions}
              id={"autolaunch-robinhood-bid-#{position.auction}-#{position.bid_id}"}
            >
              <.link navigate={position.href}>
                <strong>{position.name} · {position.symbol}</strong>
                <span>
                  Bid #{position.bid_id} · {position.committed} {position.stock_symbol} · {standing_copy(
                    position
                  )}
                </span>
                <span>{short(position.wallet)}</span>
              </.link>
            </li>
          </ol>
          <p
            :if={is_map(@robinhood_positions) && @robinhood_positions.block}
            class="autolaunch-refresh-status"
          >
            {chain_name(:robinhood)} read at block {@robinhood_positions.block}
          </p>
        </section>
      </div>
    </section>
    """
  end

  # One line per token: what the wallets hold, what they staked, what they can claim.
  defp holding_copy(holding) do
    [
      "#{holding.held} #{holding.symbol} held",
      if(holding.staked != "0", do: "#{holding.staked} #{holding.symbol} staked"),
      claimable_copy(holding.claimable)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp claimable_copy([]), do: nil

  defp claimable_copy(claimable),
    do: "claim " <> Enum.map_join(claimable, " + ", &"#{&1.amount} #{&1.symbol}")

  defp blocks_copy(blocks),
    do:
      Enum.map_join(blocks, " · ", fn {chain, number} ->
        "#{chain_name(chain)} read at block #{number}"
      end)

  defp chain_name(:base), do: Autolaunch.Lab.network_name(Autolaunch.Lab.chain_id())

  defp chain_name(:robinhood),
    do: Autolaunch.Robinhood.Lab.network_name(Autolaunch.Robinhood.Lab.chain_id())

  # What the auction itself says about the bid, in the bidder's words.
  defp standing_copy(%{standing: :bidding}), do: "In the auction"

  defp standing_copy(%{standing: :refundable, refundable: amount, stock_symbol: symbol}),
    do: "#{amount} #{symbol} refundable: the auction did not reach its required raise"

  defp standing_copy(%{standing: :ended, stock_symbol: symbol}),
    do:
      "Bidding ended: if the final count stays below the required raise, this bid gets its #{symbol} back in full; if it reached it, what this bid did not spend comes back once the auction is finished"

  defp standing_copy(%{standing: :graduated, stock_symbol: symbol}),
    do: "Auction graduated: what this bid did not spend in #{symbol} has not been returned yet"

  defp standing_copy(%{standing: :returned}), do: "Returned"

  defp standing_copy(%{standing: :claimed}), do: "Claimed"

  defp standing_copy(%{standing: :filled, claim_block: block}),
    do: "Filled: tokens can be claimed from block #{block}"

  defp standing_copy(%{standing: :claimable}), do: "Filled: tokens ready to claim"

  defp short("0x" <> address),
    do: "0x#{String.slice(address, 0, 4)}…#{String.slice(address, -4, 4)}"

  attr :positions, :list, required: true
  attr :market, :map, required: true
  attr :account_control, :map, required: true
  attr :access_context, :any, required: true
  attr :session_lease, :any, required: true

  # Every card is the settlement component: it shows the position, the exact
  # action its auction admits right now, or the reason nothing can be done yet.
  defp position_list(assigns) do
    ~H"""
    <ol class="autolaunch-record-list">
      <li :for={position <- @positions} id={"autolaunch-bid-#{position.bid_id}"}>
        <.live_component
          module={AutolaunchWeb.BidSettlementComponent}
          id={"autolaunch-settlement-#{position.id}"}
          position={position}
          market={LabMarket.reading(@market, position.auction_address)}
          authenticated={@account_control.kind == :signed_in}
          current_human_id={current_human_id(@access_context)}
          session_lease={@session_lease}
        />
        <.link navigate={"/auctions/#{position.auction_id}"}>View auction</.link>
      </li>
    </ol>
    """
  end

  defp load_signed_in_holdings(socket) do
    case human_actor(socket.assigns.access_context) do
      nil ->
        assign_holdings(socket, :ready)

      actor ->
        socket = read_token_holdings(socket, actor)

        case load_holdings(actor) do
          {:ok, holdings} -> assign(socket, holdings)
          {:error, :unavailable} -> assign_holdings(socket, :error)
        end
    end
  end

  # Wallet balances and Robinhood bids come from the chain, so they arrive
  # after the page.
  defp read_token_holdings(socket, actor) do
    if connected?(socket),
      do:
        socket
        |> assign(:token_holdings, :loading)
        |> assign(:robinhood_positions, :loading)
        |> start_async(:token_holdings, fn -> TokenHoldings.read(actor) end)
        |> start_async(:robinhood_positions, fn -> RobinhoodPositions.read(actor) end),
      else: socket
  end

  defp assign_holdings(socket, status) do
    assign(socket,
      status: status,
      positions: [],
      returnable_positions: [],
      claimable_positions: []
    )
  end
end
