defmodule AutolaunchWeb.PortfolioLive do
  @moduledoc """
  The signed-in account's bids and tokens, in the auctions list's format.

  Each bid is a list row: its token, what it put in, its maximum price, where
  it stands and its auction's time. Under it sit its buttons: the auction's
  page (the token's once it has launched), withdrawing or claiming when the
  auction allows it, and bidding more while bidding is open. Each token the
  wallets hold or stake is a row with its page, Buy, Sell and Stake. Every
  wallet step happens in the same components the auction and token pages use,
  opened here in a dialog, or for a Base bid's early return, under its row.

  Where an open Base bid stands comes from its auction's price book, read
  after the page; under a bid that is outbid or sharing at the price, the
  early return says when its unspent money can come back, as on the auction
  page.
  """

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [human_actor: 1, current_human_id: 1]

  import AutolaunchWeb.Components.MarketCard,
    only: [
      assign_figure_rates: 1,
      auction_status: 1,
      figure_rate: 2,
      list_token: 1
    ]

  import AutolaunchWeb.Components.SwapModal

  alias Autolaunch.AuctionBook
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Robinhood.Positions, as: RobinhoodPositions
  alias Autolaunch.{Token, TokenHoldings}
  alias AutolaunchWeb.Components.AuctionBook, as: AuctionBookComponent

  alias AutolaunchWeb.{
    BidSettlementComponent,
    LabMarket,
    Paths,
    RobinhoodStockBidComponent,
    TokenDisplay,
    UsdValue
  }

  @history ~w(claimed returned)
  @robinhood_history [:returned, :claimed]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       refreshed_at: nil,
       status: :ready,
       positions: [],
       token_holdings: :loading,
       robinhood_positions: :loading,
       books: %{},
       dialog: nil,
       robinhood_swap?: RobinhoodLab.swap_configured?(),
       market: LabMarket.subscribe(socket)
     )
     |> assign_figure_rates()
     |> load_signed_in_holdings()}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("refresh", _params, socket) do
    socket = load_signed_in_holdings(socket)

    {:noreply,
     assign(socket, :refreshed_at, if(socket.assigns.status == :ready, do: DateTime.utc_now()))}
  end

  # Each dialog is named by the record its form acts on; the dialog's own
  # close names the same record.
  def handle_event("open_bid", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :dialog, %{kind: :bid, id: id})}

  def handle_event("open_settlement", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :dialog, %{kind: :settle, id: id})}

  def handle_event("open_robinhood", %{"id" => id, "mode" => mode}, socket)
      when mode in ~w(bid settle),
      do: {:noreply, assign(socket, :dialog, %{kind: :robinhood, id: id, mode: mode})}

  def handle_event("open_trade", %{"id" => id, "direction" => direction}, socket)
      when direction in ~w(buy sell),
      do:
        {:noreply,
         assign(socket, :dialog, %{
           kind: :trade,
           id: id,
           direction: String.to_existing_atom(direction)
         })}

  def handle_event("close_trade", %{"id" => id}, socket) do
    case socket.assigns.dialog do
      %{id: ^id} -> {:noreply, assign(socket, :dialog, nil)}
      _other -> {:noreply, socket}
    end
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

  def handle_info({:stake_claimed_tokens, path}, socket),
    do: {:noreply, push_navigate(socket, to: path)}

  # A swap confirmed, so the wallets hold something else now.
  def handle_info(:reload_pool, socket), do: {:noreply, load_signed_in_holdings(socket)}

  def handle_async(:token_holdings, {:ok, {:ok, holdings}}, socket),
    do: {:noreply, assign(socket, :token_holdings, holdings)}

  def handle_async(:token_holdings, _failed, socket),
    do: {:noreply, assign(socket, :token_holdings, :error)}

  def handle_async(:robinhood_positions, {:ok, {:ok, positions}}, socket),
    do: {:noreply, assign(socket, :robinhood_positions, positions)}

  def handle_async(:robinhood_positions, _failed, socket),
    do: {:noreply, assign(socket, :robinhood_positions, :error)}

  def handle_async(:books, {:ok, books}, socket), do: {:noreply, assign(socket, :books, books)}
  def handle_async(:books, _failed, socket), do: {:noreply, socket}

  def render(assigns) do
    {history, current} = Enum.split_with(assigns.positions, &(&1.status in @history))
    robinhood = if is_list(assigns.robinhood_positions), do: assigns.robinhood_positions, else: []
    {robinhood_history, robinhood_current} = Enum.split_with(robinhood, &past_robinhood?/1)

    assigns =
      assign(assigns,
        history: history,
        current: Enum.sort_by(current, &(&1.status == "active")),
        robinhood_history: robinhood_history,
        robinhood_current: Enum.sort_by(robinhood_current, &(robinhood_action(&1) == nil)),
        robinhood?: Autolaunch.Robinhood.Lab.configured?(),
        opens: opens(),
        signed_in?: assigns.account_control.kind == :signed_in,
        human_id: current_human_id(assigns.access_context)
      )

    ~H"""
    <section id="autolaunch-holdings" class="memestock portfolio">
      <header class="memestock__header">
        <h1>Portfolio</h1>
        <Regent.Primitives.button
          :if={@account_control.kind != :sign_in}
          id="portfolio-refresh"
          variant="secondary"
          phx-click="refresh"
        >
          Refresh
        </Regent.Primitives.button>
      </header>
      <p class="memestock__hint portfolio__lede">
        Bids and tokens from your verified wallets.<span :if={@refreshed_at} role="status">
          Updated {Calendar.strftime(@refreshed_at, "%H:%M UTC")}.
        </span>
        <span :if={@opens && @account_control.kind != :sign_in}>
          Bidding and trading open {@opens}.
        </span>
      </p>

      <section
        :if={@account_control.kind == :sign_in}
        class="rg-panel rg-panel--surface memestock__sign-in portfolio__sign-in"
      >
        <h2>Connect to your portfolio</h2>
        <p class="memestock__hint">Sign in to see bids and tokens from your verified wallets.</p>
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

      <section
        :if={@account_control.kind != :sign_in && @status == :ready}
        id="autolaunch-bid-positions"
        class="portfolio__section"
        aria-labelledby="portfolio-bids-title"
      >
        <h2 id="portfolio-bids-title" class="portfolio__title">Your bids</h2>
        <div
          :if={@current != [] || @robinhood_current != [] || @robinhood_positions == :loading}
          class="market-list__scroll"
        >
          <table class="market-list__table portfolio__table">
            <caption class="visually-hidden">Your bids</caption>
            <.bid_head />
            <.base_bid
              :for={position <- @current}
              position={position}
              book={@books[position.auction.id]}
              rates={@rates}
              opens={@opens}
              signed_in?={@signed_in?}
              human_id={@human_id}
              session_lease={@session_lease}
            />
            <.robinhood_bid
              :for={position <- @robinhood_current}
              position={position}
              rates={@rates}
              opens={@opens}
            />
            <tbody :if={@robinhood? && @robinhood_positions == :loading}>
              <tr class="market-list__skeleton" aria-hidden="true">
                <td colspan="5"></td>
              </tr>
            </tbody>
          </table>
        </div>
        <p :if={@robinhood? && @robinhood_positions == :error} class="memestock__hint" role="alert">
          Your Robinhood bids are unavailable right now.
        </p>
        <div
          :if={@current == [] && @robinhood_current == [] && @robinhood_positions != :loading}
          class="market-list__scroll market-list__empty"
        >
          <h2>No open bids</h2>
          <p>Bids from your verified wallets will appear here.</p>
          <.link navigate="/auctions" class="rg-button rg-button--secondary">Explore auctions</.link>
        </div>

        <Regent.Primitives.disclosure
          :if={@history != [] || @robinhood_history != []}
          id="portfolio-history"
          class="portfolio__history"
          summary={"Past bids · #{length(@history) + length(@robinhood_history)}"}
        >
          <div class="market-list__scroll">
            <table class="market-list__table portfolio__table">
              <caption class="visually-hidden">Past bids</caption>
              <.bid_head />
              <.base_bid
                :for={position <- @history}
                position={position}
                rates={@rates}
                opens={@opens}
                signed_in?={@signed_in?}
                human_id={@human_id}
                session_lease={@session_lease}
              />
              <.robinhood_bid
                :for={position <- @robinhood_history}
                position={position}
                rates={@rates}
                opens={@opens}
              />
            </table>
          </div>
        </Regent.Primitives.disclosure>
      </section>

      <section
        :if={@account_control.kind != :sign_in && @status == :ready}
        id="autolaunch-held-tokens"
        class="portfolio__section"
        aria-labelledby="portfolio-tokens-title"
      >
        <h2 id="portfolio-tokens-title" class="portfolio__title">Your tokens</h2>
        <p :if={@token_holdings == :error} class="memestock__hint" role="alert">
          Your token balances are unavailable right now.
        </p>
        <div
          :if={@token_holdings == :loading || (is_list(@token_holdings) && @token_holdings != [])}
          class="market-list__scroll"
        >
          <table class="market-list__table portfolio__table portfolio__table--tokens">
            <caption class="visually-hidden">Your tokens</caption>
            <thead>
              <tr>
                <th scope="col">Token</th>
                <th scope="col">Held</th>
                <th scope="col">Staked</th>
                <th scope="col">Rewards</th>
              </tr>
            </thead>
            <.holding
              :for={
                {holding, index} <-
                  Enum.with_index(if is_list(@token_holdings), do: @token_holdings, else: [])
              }
              id={"portfolio-token-#{index}"}
              holding={holding}
              robinhood_swap?={@robinhood_swap?}
              opens={@opens}
            />
            <tbody :if={@token_holdings == :loading}>
              <tr class="market-list__skeleton" aria-hidden="true">
                <td colspan="4"></td>
              </tr>
            </tbody>
          </table>
        </div>
        <div :if={@token_holdings == []} class="market-list__scroll market-list__empty">
          <h2>No tokens yet</h2>
          <p>Tokens held or staked by your verified wallets will appear here.</p>
          <.link navigate="/tokens" class="rg-button rg-button--secondary">Explore tokens</.link>
        </div>
      </section>

      <.dialog
        dialog={@dialog}
        positions={@positions}
        robinhood={@robinhood_current ++ @robinhood_history}
        holdings={if is_list(@token_holdings), do: @token_holdings, else: []}
        market={@market}
        signed_in?={@signed_in?}
        human_id={@human_id}
        session_lease={@session_lease}
      />
    </section>
    """
  end

  defp bid_head(assigns) do
    ~H"""
    <thead>
      <tr>
        <th scope="col">Token</th>
        <th scope="col">Your bid</th>
        <th scope="col">Max price</th>
        <th scope="col">Action</th>
        <th scope="col">Status</th>
      </tr>
    </thead>
    """
  end

  attr :position, :map, required: true, doc: "a stored Base bid with its auction and token"
  attr :book, :map, default: nil, doc: "its auction's price book, once read"
  attr :rates, :any, required: true
  attr :opens, :string, default: nil
  attr :signed_in?, :boolean, required: true
  attr :human_id, :integer, default: nil
  attr :session_lease, :any, required: true

  # One Base bid: its list row, whose name opens its page and whose action
  # is its settlement once the auction allows one, else where it stands and
  # Bid more while bidding is open; under a bid that is outbid or sharing at
  # the price, its early return.
  defp base_bid(assigns) do
    %{position: position, book: book} = assigns
    auction = position.auction
    live? = auction.state == :active

    assigns =
      assign(assigns,
        auction: auction,
        path:
          if(match?(%Token{}, position.token),
            do: Paths.token(auction),
            else: Paths.auction(auction)
          ),
        rate: figure_rate(assigns.rates, auction),
        settle: settle_label(position),
        live?: live?,
        standing: if(live? && book, do: AuctionBook.bid_standing(position, auction, book))
      )

    ~H"""
    <tbody id={"autolaunch-bid-#{@position.id}"}>
      <tr class="market-list__row">
        <.list_token
          name={@auction.title}
          symbol={@auction.token_symbol}
          unit={@auction.quote_token_symbol}
          image={@auction.image}
          chain="Base"
          path={@path}
        />
        <td>
          <TokenDisplay.price amount={@position.amount} unit={@auction.quote_token_symbol} />
          <small :if={@rate}><UsdValue.usd amount={@position.amount} rate={@rate} /></small>
        </td>
        <td>
          <TokenDisplay.price amount={@position.max_price} unit={@auction.quote_token_symbol} />
        </td>
        <td>
          <div class="portfolio__action">
            <Regent.Primitives.button
              :if={@settle}
              phx-click="open_settlement"
              phx-value-id={@position.id}
            >
              {@settle}
            </Regent.Primitives.button>
            <span :if={!@settle}>{base_standing(@position, @standing)}</span>
            <Regent.Primitives.button
              :if={@live?}
              variant="secondary"
              phx-click="open_bid"
              phx-value-id={@auction.id}
              disabled={!!@opens}
            >
              Bid more
            </Regent.Primitives.button>
          </div>
        </td>
        <td><.auction_status id={"portfolio-time-#{@position.id}"} auction={@auction} /></td>
      </tr>
      <tr
        :if={@position.status == "active" && @standing in [:outbid, :sharing]}
        class="portfolio__actions"
      >
        <td colspan="5">
          <.live_component
            module={BidSettlementComponent}
            id={"portfolio-early-#{@position.id}"}
            early
            position={@position}
            recheck={@book.block}
            authenticated={@signed_in?}
            current_human_id={@human_id}
            session_lease={@session_lease}
          />
        </td>
      </tr>
    </tbody>
    """
  end

  attr :position, :map,
    required: true,
    doc: "a Robinhood bid from `Autolaunch.Robinhood.Positions`"

  attr :rates, :any, required: true
  attr :opens, :string, default: nil

  # One Robinhood bid: its list row, whose name opens its page and whose
  # action is what its auction admits. A bid on an auction this site does not
  # list has no page and no action here.
  defp robinhood_bid(assigns) do
    %{position: position} = assigns
    listing = position.listing

    assigns =
      assign(assigns,
        listing: listing,
        path: robinhood_path(position),
        rate: listing && figure_rate(assigns.rates, listing),
        action: listing && robinhood_action(position)
      )

    ~H"""
    <tbody id={"autolaunch-robinhood-bid-#{@position.auction}-#{@position.bid_id}"}>
      <tr class="market-list__row">
        <.list_token
          name={@position.name}
          symbol={@position.symbol}
          unit={@position.stock_symbol}
          image={@position.image}
          chain="Robinhood"
          path={@path}
        />
        <td>
          <TokenDisplay.price amount={@position.committed} unit={@position.stock_symbol} />
          <small :if={@rate}><UsdValue.usd amount={@position.committed} rate={@rate} /></small>
        </td>
        <td><TokenDisplay.price amount={@position.max_price} unit={@position.stock_symbol} /></td>
        <td>
          <div class="portfolio__action">
            <Regent.Primitives.button
              :if={@action in [:withdraw, :claim]}
              phx-click="open_robinhood"
              phx-value-id={@listing.id}
              phx-value-mode="settle"
            >
              {if @action == :claim, do: "Claim", else: "Withdraw"}
            </Regent.Primitives.button>
            <span :if={@action not in [:withdraw, :claim]}>{robinhood_standing(@position)}</span>
            <Regent.Primitives.button
              :if={@action == :early}
              phx-click="open_robinhood"
              phx-value-id={@listing.id}
              phx-value-mode="bid"
            >
              Withdraw
            </Regent.Primitives.button>
            <Regent.Primitives.button
              :if={@listing && @listing.state == :active}
              variant="secondary"
              phx-click="open_robinhood"
              phx-value-id={@listing.id}
              phx-value-mode="bid"
              disabled={!!@opens}
            >
              Bid more
            </Regent.Primitives.button>
          </div>
        </td>
        <td>
          <.auction_status
            :if={@listing}
            id={"portfolio-time-#{@position.auction}-#{@position.bid_id}"}
            auction={@listing}
          />
          <span :if={!@listing}>-</span>
        </td>
      </tr>
    </tbody>
    """
  end

  attr :id, :string, required: true
  attr :holding, :map, required: true, doc: "a token from `Autolaunch.TokenHoldings`"
  attr :robinhood_swap?, :boolean, required: true
  attr :opens, :string, default: nil

  # One token the wallets hold or stake: its list row, whose name opens its
  # page, then Buy and Sell in the swap dialog, and Stake on its page.
  defp holding(assigns) do
    %{holding: holding} = assigns
    token = holding.token

    assigns =
      assign(assigns,
        token: token,
        path: token && Paths.token(token.auction),
        image: token && Token.presentation(token).image,
        tradable?: token && tradable?(token, assigns.robinhood_swap?)
      )

    ~H"""
    <tbody id={@id}>
      <tr class="market-list__row">
        <.list_token
          name={@holding.name}
          symbol={@holding.symbol}
          unit={@holding.unit}
          image={@image}
          chain={if @holding.chain == :robinhood, do: "Robinhood", else: "Base"}
          path={@path}
        />
        <td>{@holding.held}</td>
        <td>{@holding.staked}</td>
        <td>{rewards(@holding.claimable)}</td>
      </tr>
      <tr :if={@token} class="portfolio__actions">
        <td colspan="4">
          <div class="portfolio__buttons">
            <Regent.Primitives.button
              :if={@tradable?}
              phx-click="open_trade"
              phx-value-id={@token.id}
              phx-value-direction="buy"
              disabled={!!@opens}
            >
              Buy
            </Regent.Primitives.button>
            <Regent.Primitives.button
              :if={@tradable?}
              variant="secondary"
              phx-click="open_trade"
              phx-value-id={@token.id}
              phx-value-direction="sell"
              disabled={!!@opens}
            >
              Sell
            </Regent.Primitives.button>
            <.link navigate={@path <> "#stake"} class="rg-button rg-button--secondary">
              {if @holding.claimable != [], do: "Stake or claim rewards", else: "Stake"}
            </.link>
          </div>
        </td>
      </tr>
    </tbody>
    """
  end

  attr :dialog, :map, default: nil
  attr :positions, :list, required: true
  attr :robinhood, :list, required: true
  attr :holdings, :list, required: true
  attr :market, :map, required: true
  attr :signed_in?, :boolean, required: true
  attr :human_id, :integer, default: nil
  attr :session_lease, :any, required: true

  # The open dialog, for the record it names while that record is still on
  # the page.
  defp dialog(%{dialog: %{kind: :bid, id: id}} = assigns) do
    assigns =
      assign(
        assigns,
        :auction,
        Enum.find_value(assigns.positions, &(&1.auction.id == id && &1.auction))
      )

    ~H"""
    <.bid_modal
      :if={@auction}
      id={"portfolio-bid-#{@auction.id}"}
      auction={@auction}
      authenticated={@signed_in?}
      current_human_id={@human_id}
      session_lease={@session_lease}
    />
    """
  end

  defp dialog(%{dialog: %{kind: :settle, id: id}} = assigns) do
    assigns = assign(assigns, :position, Enum.find(assigns.positions, &(&1.id == id)))

    ~H"""
    <.settlement_modal
      :if={@position}
      id={"portfolio-settle-#{@position.id}"}
      position={@position}
      market={LabMarket.reading(@market, @position.auction_address)}
      authenticated={@signed_in?}
      current_human_id={@human_id}
      session_lease={@session_lease}
    />
    """
  end

  defp dialog(%{dialog: %{kind: :robinhood, id: id, mode: mode}} = assigns) do
    position = Enum.find(assigns.robinhood, &(&1.listing && &1.listing.id == id))
    listing = position && position.listing

    assigns =
      assign(assigns,
        listing: listing,
        mode: mode,
        ended:
          if(listing && mode == "settle", do: RobinhoodStockBidComponent.ended_copy(listing)),
        stake_path: if(listing && position.token, do: Paths.token(listing) <> "#stake")
      )

    ~H"""
    <.robinhood_bid_modal
      :if={@listing}
      id={"portfolio-robinhood-#{@mode}-#{@listing.id}"}
      auction={@listing}
      ended={@ended}
      stake_path={@stake_path}
      authenticated={@signed_in?}
      current_human_id={@human_id}
      session_lease={@session_lease}
    />
    """
  end

  defp dialog(%{dialog: %{kind: :trade, id: id, direction: direction}} = assigns) do
    assigns =
      assign(assigns,
        token: Enum.find_value(assigns.holdings, &(&1.token && &1.token.id == id && &1.token)),
        direction: direction
      )

    ~H"""
    <.swap_modal
      :if={@token}
      id={"portfolio-trade-#{@direction}-#{@token.id}"}
      token={@token}
      direction={@direction}
      authenticated={@signed_in?}
      current_human_id={@human_id}
      session_lease={@session_lease}
    />
    """
  end

  defp dialog(assigns), do: ~H""

  # Until the contracts are deployed no bid or trade opens.
  defp opens do
    if Autolaunch.Prelaunch.read_only?(), do: Autolaunch.Prelaunch.opens_at_label()
  end

  # The page of an auction the bid is in: its token's once it has graduated.
  defp robinhood_path(%{token: %Token{}, listing: listing}), do: Paths.token(listing)
  defp robinhood_path(%{listing: %{} = listing}), do: Paths.auction(listing)
  defp robinhood_path(_position), do: nil

  defp settle_label(%{status: "returnable"} = position),
    do: if(BidSettlementComponent.spent?(position), do: "Claim", else: "Withdraw")

  defp settle_label(%{status: "claimable"}), do: "Claim"
  defp settle_label(_position), do: nil

  # What a Robinhood bid's auction admits now: its unspent money back once
  # the auction has settled, its tokens once they can be claimed, or, while
  # bidding is open, the early return a bid that is not buying may have.
  defp robinhood_action(%{standing: standing}) when standing in [:refundable, :graduated],
    do: :withdraw

  defp robinhood_action(%{standing: :claimable}), do: :claim
  defp robinhood_action(%{standing: standing}) when standing in [:sharing, :outbid], do: :early
  defp robinhood_action(_position), do: nil

  defp past_robinhood?(%{standing: standing}), do: standing in @robinhood_history

  # Where a Base bid stands: against its auction's price while bidding is
  # open and the book has been read, otherwise from its stored settlement.
  defp base_standing(%{status: "active"}, standing) when standing != nil,
    do: AuctionBookComponent.standing_label(standing)

  defp base_standing(%{status: "active", auction: %{state: :active}}, nil), do: "In the auction"
  defp base_standing(%{status: "active"}, nil), do: "Bidding ended"

  defp base_standing(%{status: "claimed"}, _standing), do: "Completed"

  defp base_standing(%{status: "returned", tokens_filled: filled}, _standing)
       when is_binary(filled) and filled not in ["", "0"],
       do: "Tokens claimable soon"

  defp base_standing(%{status: "returned"}, _standing), do: "Completed"

  # Where a Robinhood bid stands, in the auction's own terms.
  defp robinhood_standing(%{standing: standing}) when standing in [:in, :sharing, :outbid],
    do: AuctionBookComponent.standing_label(standing)

  defp robinhood_standing(%{standing: :ended}), do: "Bidding ended"

  defp robinhood_standing(%{standing: :refundable, refundable: amount, stock_symbol: symbol}),
    do: "#{amount} #{symbol} to withdraw"

  defp robinhood_standing(%{standing: :graduated, stock_symbol: symbol}),
    do: "Unspent #{symbol} to withdraw"

  defp robinhood_standing(%{standing: :filled}), do: "Tokens claimable soon"
  defp robinhood_standing(%{standing: :claimable}), do: "Tokens ready to claim"

  defp robinhood_standing(%{standing: standing}) when standing in [:returned, :claimed],
    do: "Completed"

  defp rewards([]), do: "-"
  defp rewards(claimable), do: Enum.map_join(claimable, " + ", &"#{&1.amount} #{&1.symbol}")

  defp load_signed_in_holdings(socket) do
    case human_actor(socket.assigns.access_context) do
      nil ->
        assign(socket, status: :ready, positions: [])

      actor ->
        socket = read_chain_holdings(socket, actor)

        case Autolaunch.list_my_bid_positions(actor: actor) do
          {:ok, positions} ->
            socket |> assign(status: :ready, positions: positions) |> read_books(positions)

          {:error, _error} ->
            assign(socket, status: :error, positions: [])
        end
    end
  end

  # The price books of the auctions still taking bids that the open Base bids
  # are in; a book that cannot be read leaves its bids' standing unread.
  defp read_books(socket, positions) do
    auctions =
      for %{status: "active", auction: %{state: :active} = auction} <- positions,
          uniq: true,
          do: auction

    if connected?(socket),
      do: start_async(socket, :books, fn -> books(auctions) end),
      else: socket
  end

  defp books(auctions) do
    for auction <- auctions,
        {:ok, book} <- [AuctionBook.base(auction)],
        into: %{},
        do: {auction.id, book}
  end

  # Wallet balances and Robinhood bids come from the chain, so they arrive
  # after the page.
  defp read_chain_holdings(socket, actor) do
    if connected?(socket),
      do:
        socket
        |> start_async(:token_holdings, fn -> TokenHoldings.read(actor) end)
        |> start_async(:robinhood_positions, fn -> RobinhoodPositions.read(actor) end),
      else: socket
  end
end
