defmodule AutolaunchWeb.AuctionLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers
  import AutolaunchWeb.Components.MarketCard
  import AutolaunchWeb.Components.LaunchTrust
  import AutolaunchWeb.Components.AuctionBook
  import AutolaunchWeb.Components.AuctionHistory
  import AutolaunchWeb.Components.AuctionPage, only: [headline: 1, details_window: 1]
  import AutolaunchWeb.Components.RaiseProgress

  alias Autolaunch.AuctionBook
  alias Autolaunch.Chain.Rpc
  alias Autolaunch.Lab
  alias Autolaunch.LabMarketFeed
  alias Autolaunch.Stocks.LabMarketFeed, as: StocksMarketFeed
  alias AutolaunchWeb.{LiveListings, Paths, UsdValue}

  def mount(_params, _session, socket),
    do:
      {:ok,
       socket
       |> assign_market()
       |> LiveListings.subscribe()
       |> assign(my_positions: [])}

  # The identifier is read here so a patch to another auction reloads the page
  # instead of keeping the previous record on screen.
  def handle_params(%{"auction_id" => id}, _uri, socket) do
    {:noreply,
     socket
     |> assign(:record_id, id)
     |> assign_positions()
     |> load_page(reset: true)
     |> load_book(reset: true)
     |> load_history(reset: true)
     |> load_usd_rate()}
  end

  def handle_event("retry", _params, socket), do: {:noreply, load_page(socket, reset: true)}

  # Either feed may have moved; the combined reading decides whether the page
  # has anything new to show.
  def handle_info({:autolaunch_market_updated, _update}, socket) do
    market = market_snapshot()

    if market.generation > socket.assigns.market.generation do
      {:noreply,
       socket
       |> assign(:market, market)
       |> assign_positions()
       |> load_page(reset: false)
       |> load_book(reset: false)
       |> load_history(reset: false)}
    else
      {:noreply, socket}
    end
  end

  # This auction's saved record changed (its state, bids, minimum, bid terms or
  # treasury report), so the page reads it again in place, with the viewer's own
  # bids; the bid form stays.
  def handle_info({:autolaunch_listings_changed, auction_id}, socket) do
    if auction_id == socket.assigns.record_id,
      do: {:noreply, LiveListings.schedule(socket)},
      else: {:noreply, socket}
  end

  def handle_info(:reread_listings, socket),
    do:
      {:noreply,
       socket
       |> LiveListings.taken()
       |> assign_positions()
       |> load_page(reset: false)
       |> load_history(reset: false)}

  # A settlement card verified a step, so the bidder's stored positions changed.
  def handle_info({:bid_settlement_changed, _position_id}, socket),
    do: {:noreply, assign_positions(socket)}

  def handle_info({:stake_claimed_tokens, path}, socket),
    do: {:noreply, push_navigate(socket, to: path)}

  # LabMarket subscribes to both networks; this page represents a Base auction.
  def handle_info({:robinhood_market_updated, _update}, socket), do: {:noreply, socket}

  def render(assigns) do
    assigns =
      assign(assigns,
        local_lab?: Lab.test_chain?(),
        page_record: page_record(assigns.page),
        page_status: page_status(assigns.page, :error),
        creator_connections: page_connections(assigns.page),
        usd_rate: assigns.usd_rate.result
      )

    assigns =
      assign(
        assigns,
        market_snapshot: auction_market_snapshot(assigns.market, assigns.page_record),
        graduated_token: page_token(assigns.page)
      )

    assigns =
      assign(
        assigns,
        :bidding_ended?,
        bidding_ended?(assigns.page_record, assigns.market_snapshot)
      )

    assigns =
      assign(
        assigns,
        :outbid,
        if(bidding_open?(assigns.bidding_ended?), do: outbid(assigns.my_positions, assigns.book))
      )

    ~H"""
    <article
      :if={@page_status == :ready && @page_record}
      id="autolaunch-auction-detail"
      class="autolaunch-page auction-page"
    >
      <header class="autolaunch-heading">
        <.link navigate="/auctions" class="market-back">← Auctions</.link>
        <Regent.Structure.section_bar>
          <h1 class="rg-section-bar__label">{record_label(:auction, @page_record)}</h1>
        </Regent.Structure.section_bar>
      </header>
      <.outbid_banner
        :if={@outbid}
        bid_form="autolaunch-bid"
        return_to={if @page_record.minimum_reached, do: "autolaunch-position-#{@outbid.id}"}
      />
      <.headline
        record={@page_record}
        minimum={minimum(@page_record)}
        usd_rate={@usd_rate}
        details="auction-details"
      />
      <div class="auction-layout">
        <section class="auction-layout__chart" aria-label="Price and progress">
          <.auction_chart
            :if={@market_snapshot && @history.ok?}
            id="auction-chart"
            bids={@history.result.bids}
            points={@history.result.points}
            symbol={@page_record.quote_token_symbol}
            token_symbol={@page_record.token_symbol}
            usd_rate={@usd_rate}
            raised={@market_snapshot.currency_raised}
            start_block={@market_snapshot.start_block}
            end_block={@market_snapshot.end_block}
            block={@market_snapshot.block_number}
          />
          <.raise_progress
            :if={@market_snapshot}
            id="auction-raise-progress"
            state={@market_snapshot.state}
            raised={@market_snapshot.currency_raised}
            required={minimum(@page_record)}
            symbol={@page_record.quote_token_symbol}
            usd_rate={@usd_rate}
            block={@market_snapshot.block_number}
            start_block={@market_snapshot.start_block}
            end_block={@market_snapshot.end_block}
            chain={:base}
            test_chain={@local_lab?}
            bids={@page_record.bid_volume && Decimal.to_string(@page_record.bid_volume, :normal)}
          />
        </section>
        <aside class="auction-layout__bid" aria-label="Bid on this auction">
          <section
            :if={Autolaunch.Prelaunch.read_only?()}
            class="prelaunch-actions"
            aria-label="Bidding unavailable"
          >
            <h2>Place a bid</h2>
            <p>Bidding opens {Autolaunch.Prelaunch.opens_at_label()}.</p>
            <Regent.Primitives.button disabled>Place a bid</Regent.Primitives.button>
          </section>
          <.live_component
            :if={!Autolaunch.Prelaunch.read_only?() && !@bidding_ended?}
            module={AutolaunchWeb.BidComponent}
            id="autolaunch-bid"
            auction={@page_record}
            book={@book}
            authenticated={@account_control.kind == :signed_in}
            current_human_id={current_human_id(@access_context)}
            session_lease={@session_lease}
          />
          <section
            :if={bidding_open?(@bidding_ended?) && @book.ok? && @my_positions != []}
            id="autolaunch-my-bids"
            class="bid-panel"
            aria-label="Your bids"
          >
            <h3>Your bids on this auction</h3>
            <ul role="list" class="bid-positions">
              <li :for={position <- @my_positions}>
                <.live_component
                  module={AutolaunchWeb.OutbidComponent}
                  id={"autolaunch-position-#{position.id}"}
                  position={position}
                  book={@book}
                  authenticated={@account_control.kind == :signed_in}
                  current_human_id={current_human_id(@access_context)}
                  session_lease={@session_lease}
                />
              </li>
            </ul>
          </section>
          <section
            :if={!Autolaunch.Prelaunch.read_only?() && @bidding_ended?}
            id="autolaunch-settlement"
            class="bid-panel"
            aria-label="Bidding has ended"
          >
            <AutolaunchWeb.Components.BidForm.title
              id="autolaunch-settlement"
              title="Bidding has ended"
            />
            <p class="bid-ended">{ended_copy(@page_record)}</p>
            <p :if={@account_control.kind != :signed_in} class="bid-empty">
              <Regent.Primitives.button type="button" data-account-target="sign-in">
                Sign in to see your bids
              </Regent.Primitives.button>
            </p>
            <p :if={@account_control.kind == :signed_in && @my_positions == []} class="bid-empty">
              You placed no bids on this auction from your verified wallets.
            </p>
            <.live_component
              :for={position <- @my_positions}
              module={AutolaunchWeb.BidSettlementComponent}
              id={"autolaunch-settlement-#{position.id}"}
              position={position}
              market={@market_snapshot}
              authenticated={@account_control.kind == :signed_in}
              current_human_id={current_human_id(@access_context)}
              session_lease={@session_lease}
            />
          </section>
          <div :if={@local_lab?} id="autolaunch-lab-position"></div>
          <.live_component
            :if={AutolaunchWeb.TestFundsComponent.available?() && @account_control.kind == :signed_in}
            module={AutolaunchWeb.TestFundsComponent}
            id="autolaunch-test-funds"
            current_human_id={current_human_id(@access_context)}
            session_lease={@session_lease}
          />
        </aside>
        <div class="auction-layout__rest">
          <.auction_book
            :if={bidding_open?(@bidding_ended?) && @book.ok?}
            id="auction-book"
            book={@book.result}
            symbol={@page_record.quote_token_symbol}
            usd_rate={@usd_rate}
            color={@page_record.image_color}
            bid_form="autolaunch-bid"
            price_info={price_info(@page_record)}
          />
          <.auction_activity
            :if={@market_snapshot && @history.ok?}
            id="auction-activity"
            bids={@history.result.bids}
            symbol={@page_record.quote_token_symbol}
            block={@market_snapshot.block_number}
            start_block={@market_snapshot.start_block}
            end_block={@market_snapshot.end_block}
            chain={:base}
            test_chain={@local_lab?}
          />
          <section class="auction-info" aria-labelledby="auction-info-title">
            <h2 id="auction-info-title" class="auction-info__title">About this token</h2>
            <.detail_card
              kind={:auction}
              record={@page_record}
              trade_path={@graduated_token && Paths.token(@page_record)}
              status={settling_status(@page_record, @bidding_ended?)}
            >
              <:price_note>
                <UsdValue.usd
                  amount={@page_record.current_clearing_price}
                  rate={@usd_rate}
                  per="per token"
                />
              </:price_note>
            </.detail_card>
            <.launch_trust
              auction={@page_record}
              connections={@creator_connections}
              token_path={@graduated_token && Paths.token(@page_record) <> "#pool"}
            />
            <p
              :if={@page_record.state == :graduated && @graduated_token}
              id="auction-pool-link"
              class="autolaunch-live-market"
            >
              This auction graduated into its pool.
              <.link navigate={Paths.token(@page_record) <> "#pool"}>View the pool and its trading fees</.link>
            </p>
            <.treasury_security
              :if={@page_record.kind == :agent && !@local_lab?}
              report={report(@page_record)}
              surface="auction-detail"
            />
            <.lab_treasury_unavailable
              :if={@page_record.kind == :agent && @local_lab?}
              surface="auction-detail"
            />
          </section>
        </div>
      </div>
      <.details_window id="auction-details">
        <.exact_price
          id="auction-exact-price"
          summary="Exact clearing price"
          amount={@page_record.current_clearing_price}
          unit={@page_record.quote_token_symbol}
        />
        <dl class="autolaunch-live-market" aria-label="Auction terms">
          <div>
            <dt>Minimum to graduate</dt>
            <dd>
              <AutolaunchWeb.TokenDisplay.price
                amount={minimum(@page_record)}
                unit={@page_record.quote_token_symbol}
              />
              <UsdValue.usd amount={minimum(@page_record)} rate={@usd_rate} />
            </dd>
          </div>
          <div>
            <dt>Bids are paid in</dt>
            <dd>
              <span class="ticker">{@page_record.quote_token_symbol}</span>
              <span :if={@page_record.quote_token_decimals}>
                · {@page_record.quote_token_decimals} decimal places
              </span>
            </dd>
          </div>
          <div :if={@page_record.quote_token_address}>
            <dt>Currency address</dt>
            <dd class="autolaunch-exact-value">{@page_record.quote_token_address}</dd>
          </div>
        </dl>
        <dl :if={@market_snapshot} class="autolaunch-live-market" aria-label="Latest reading">
          <div>
            <dt>Read at block</dt><dd>{@market_snapshot.block_number}</dd>
          </div>
          <div>
            <dt>{raised_label(@page_record)}</dt><dd>
              <AutolaunchWeb.TokenDisplay.price
                amount={@market_snapshot.currency_raised}
                fallback="—"
              />
              <UsdValue.usd amount={@market_snapshot.currency_raised} rate={@usd_rate} />
            </dd>
          </div>
          <div>
            <dt>Tokens remaining</dt><dd>
              <AutolaunchWeb.TokenDisplay.price
                amount={@market_snapshot.remaining_supply}
                fallback="—"
              />
            </dd>
          </div>
          <div>
            <dt>Claim block</dt><dd>{@market_snapshot.claim_block}</dd>
          </div>
        </dl>
        <Regent.Primitives.disclosure
          :if={@market_snapshot}
          id="auction-exact-market-amounts"
          summary="Exact market amounts"
        >
          <dl class="autolaunch-live-market">
            <div>
              <dt>{raised_label(@page_record)}</dt><dd class="autolaunch-exact-value">
                {@market_snapshot.currency_raised}
              </dd>
            </div>
            <div>
              <dt>Tokens remaining</dt><dd class="autolaunch-exact-value">
                {@market_snapshot.remaining_supply}
              </dd>
            </div>
          </dl>
        </Regent.Primitives.disclosure>
      </.details_window>
    </article>

    <p :if={@page_status == :loading} class="autolaunch-page" role="status">Loading…</p>

    <section
      :if={@page_status == :empty}
      id="autolaunch-auction-detail"
      class="autolaunch-page autolaunch-empty"
    >
      <Regent.Structure.section_bar>
        <h1 class="rg-section-bar__label">Auction not found</h1>
      </Regent.Structure.section_bar>
      <p>No public auction exists at {@record_id}.</p>
      <.link navigate="/auctions">Return to Auctions</.link>
    </section>

    <section
      :if={@page_status == :error}
      id="autolaunch-auction-detail"
      class="autolaunch-page autolaunch-empty"
      role="alert"
    >
      <Regent.Structure.section_bar>
        <h1 class="rg-section-bar__label">Auction unavailable</h1>
      </Regent.Structure.section_bar>
      <p>This auction could not be loaded right now.</p>
      <Regent.Primitives.button phx-click="retry" variant="secondary">Retry</Regent.Primitives.button>
      <.link navigate="/auctions">Return to Auctions</.link>
    </section>
    """
  end

  defp load_page(socket, reset: reset) do
    id = socket.assigns.record_id
    assign_async(socket, :page, fn -> load_auction_page_with_token(id) end, reset: reset)
  end

  # The auction's confirmed bids and clearing prices, read apart from the page.
  defp load_history(socket, reset: reset) do
    id = socket.assigns.record_id

    assign_async(
      socket,
      :history,
      fn ->
        with {:ok, bids} <- Autolaunch.auction_bids(id, actor: nil),
             {:ok, points} <- Autolaunch.auction_price_points(id, actor: nil) do
          {:ok, %{history: %{bids: bids, points: points}}}
        end
      end,
      reset: reset
    )
  end

  # The price to get tokens and the bids around it, read from the auction
  # contract apart from the page, so a slow read never holds the auction back.
  defp load_book(socket, reset: reset) do
    id = socket.assigns.record_id

    assign_async(
      socket,
      :book,
      fn ->
        with {:ok, %Autolaunch.Auction{} = auction} <- Autolaunch.get_public_auction(id),
             {:ok, book} <- AuctionBook.base(auction) do
          {:ok, %{book: book}}
        else
          {:error, reason} -> {:error, reason}
          {:ok, nil} -> {:error, :not_found}
        end
      end,
      reset: reset
    )
  end

  defp bidding_open?(bidding_ended?), do: !Autolaunch.Prelaunch.read_only?() && !bidding_ended?

  # The first of the bidder's still-open bids that the price has passed.
  defp outbid(positions, %{ok?: true, result: book}) do
    Enum.find(positions, fn
      %{status: "active", max_price: max_price, auction: %{quote_token_decimals: decimals}} ->
        {:ok, price_q96} = Autolaunch.BidActions.price_q96(max_price, decimals)
        AuctionBook.standing(price_q96, book) == :outbid

      _settled ->
        false
    end)
  end

  defp outbid(_positions, _book), do: nil

  # The dollar price of the auction's currency, read apart from the page so a
  # slow price never holds the auction back and a market update never reads it
  # again.
  defp load_usd_rate(socket) do
    id = socket.assigns.record_id

    UsdValue.assign_rate(socket, :usd_rate, :base, fn ->
      with {:ok, uuid} <- Ash.Type.UUID.cast_input(id, []),
           {:ok, %Autolaunch.Auction{} = auction} <- Autolaunch.get_public_auction(uuid) do
        {:ok, %{usd_rate: UsdValue.rate(auction)}}
      else
        _missing -> {:error, :no_auction}
      end
    end)
  end

  # The signed-in bidder's own positions on this auction, for settlement once
  # bidding has ended.
  defp assign_positions(socket) do
    with actor when not is_nil(actor) <- human_actor(socket.assigns.access_context),
         {:ok, uuid} <- Ash.Type.UUID.cast_input(socket.assigns.record_id, []),
         {:ok, positions} <- Autolaunch.list_my_bid_positions(actor: actor) do
      assign(socket, :my_positions, Enum.filter(positions, &(&1.auction_id == uuid)))
    else
      _none -> assign(socket, :my_positions, [])
    end
  end

  # Between the end block and the feed's next reading the record still says
  # active; the page knows bidding is over and says so.
  defp settling_status(%{state: :active}, true), do: "Waiting to finish"
  defp settling_status(_record, _bidding_ended?), do: nil

  defp bidding_ended?(%{state: state}, _snapshot) when state in [:ended, :graduated, :failed],
    do: true

  defp bidding_ended?(_record, %{block_number: block, end_block: end_block}),
    do: block >= end_block

  defp bidding_ended?(_record, _snapshot), do: false

  # A Revstake token and REGENT both have 100 billion tokens, so its price in
  # REGENT compares the two whole tokens directly.
  defp price_info(%{kind: :agent}),
    do:
      "REGENT and this token both have 100 billion tokens, so a price of 1 REGENT per token values it the same as REGENT."

  defp price_info(_auction), do: nil

  defp ended_copy(%{state: :graduated, quote_token_symbol: symbol}),
    do:
      "The auction raised its minimum. Bids above the final price return their unspent #{symbol} and receive tokens; the rest return what was not spent."

  defp ended_copy(%{state: :failed, quote_token_symbol: symbol}),
    do: "The auction did not raise its minimum. Every bid returns its #{symbol} in full."

  defp ended_copy(%{minimum_reached: true, quote_token_symbol: symbol}),
    do:
      "Bidding has ended and the auction raised its minimum. Its trading pool opens once the auction is finished. Bids above the final price receive tokens and their unspent #{symbol}; the rest return what was not spent."

  defp ended_copy(%{quote_token_symbol: symbol}),
    do:
      "Bidding has ended. If the final count stays below the minimum, every bid returns its #{symbol} in full; if it reached the minimum, the trading pool opens once the auction is finished."

  # The auction with its FDV for the headline, and a graduated auction's token
  # row, when it exists, so the page can point at the pool that auction
  # graduated into.
  defp load_auction_page_with_token(id) do
    with {:ok, %{page: page}} <- load_auction_page(id),
         {:ok, record} <- with_fdv(page.record) do
      {:ok, %{page: %{page | record: record} |> Map.put(:token, graduated_token(record))}}
    end
  end

  defp with_fdv(nil), do: {:ok, nil}
  defp with_fdv(record), do: Ash.load(record, [:fdv], actor: nil, reuse_values?: true)

  defp graduated_token(%{state: :graduated, id: auction_id}) do
    case Autolaunch.get_public_token_by_auction(auction_id) do
      {:ok, token} -> token
      {:error, _reason} -> nil
    end
  end

  defp graduated_token(_record), do: nil

  # A failed auction's currency is refunded from the block it failed, so what
  # its contract still holds is what was bid, not what the launch keeps.
  defp raised_label(%{state: :failed, quote_token_symbol: symbol}),
    do: "#{symbol} bid before refunds"

  defp raised_label(%{quote_token_symbol: symbol}), do: "#{symbol} raised"

  defp minimum(%{required_currency_raised: required, quote_token_decimals: decimals}),
    do: required |> String.to_integer() |> Rpc.format_units(decimals)

  defp page_token(%{ok?: true, result: %{token: token}}), do: token
  defp page_token(_page), do: nil

  defp assign_market(socket) do
    if connected?(socket) and Process.whereis(LabMarketFeed) do
      Phoenix.PubSub.subscribe(Autolaunch.PubSub, LabMarketFeed.topic())
      assign(socket, :market, market_snapshot())
    else
      assign(socket, :market, empty_market())
    end
  end

  # Both feeds publish on one topic; their per-auction readings are disjoint,
  # and one generation counter has to move whenever either does.
  defp market_snapshot do
    agent = LabMarketFeed.snapshot()

    case Process.whereis(StocksMarketFeed) do
      nil ->
        agent

      _pid ->
        stocks = StocksMarketFeed.snapshot()

        %{
          agent
          | generation: agent.generation + stocks.generation,
            auctions: Map.merge(agent.auctions, stocks.auctions)
        }
    end
  end
end
