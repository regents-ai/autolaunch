defmodule AutolaunchWeb.AuctionLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers
  import AutolaunchWeb.Components.MarketCard

  alias Autolaunch.Lab
  alias Autolaunch.LabMarketFeed
  alias Autolaunch.Stocks.LabMarketFeed, as: StocksMarketFeed

  def mount(_params, _session, socket),
    do: {:ok, socket |> assign_market() |> assign(:my_positions, [])}

  # The identifier is read here so a patch to another auction reloads the page
  # instead of keeping the previous record on screen.
  def handle_params(%{"auction_id" => id}, _uri, socket) do
    {:noreply, socket |> assign(:record_id, id) |> assign_positions() |> load_page(reset: true)}
  end

  def handle_event("retry", _params, socket), do: {:noreply, load_page(socket, reset: true)}

  # Either feed may have moved; the combined reading decides whether the page
  # has anything new to show.
  def handle_info({:autolaunch_market_updated, _update}, socket) do
    market = market_snapshot()

    if market.generation > socket.assigns.market.generation do
      {:noreply,
       socket |> assign(:market, market) |> assign_positions() |> load_page(reset: false)}
    else
      {:noreply, socket}
    end
  end

  # A settlement card verified a step, so the bidder's stored positions changed.
  def handle_info({:bid_settlement_changed, _position_id}, socket),
    do: {:noreply, assign_positions(socket)}

  def render(assigns) do
    assigns =
      assign(assigns,
        local_lab?: Lab.enabled?(),
        page_record: page_record(assigns.page),
        page_status: page_status(assigns.page, :error),
        creator_connections: page_connections(assigns.page)
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

    ~H"""
    <article
      :if={@page_status == :ready && @page_record}
      id="autolaunch-auction-detail"
      class="autolaunch-page"
    >
      <header class="autolaunch-heading">
        <.link navigate="/auctions" class="market-back">← Auctions</.link>
        <Regent.Structure.section_bar>
          <h1 class="rg-section-bar__label">{record_label(:auction, @page_record)}</h1>
        </Regent.Structure.section_bar>
      </header>
      <div class="market-detail-layout">
        <section class="market-detail-summary" aria-label="Auction information">
          <.detail_card
            kind={:auction}
            record={@page_record}
            creator_connections={@creator_connections}
          />
          <.exact_price
            id="auction-exact-price"
            summary="Exact clearing price"
            amount={@page_record.current_clearing_price}
            unit={@page_record.quote_token_symbol}
          />
          <dl class="autolaunch-live-market" aria-label="Auction currency">
            <div>
              <dt>Bids are paid in</dt>
              <dd>
                {@page_record.quote_token_symbol}
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
          <p
            :if={@page_record.state == :graduated && @graduated_token}
            id="auction-pool-link"
            class="autolaunch-live-market"
          >
            This auction graduated into its pool.
            <.link navigate={"/tokens/#{@graduated_token.id}#pool"}>View the pool and fee lanes</.link>
          </p>
          <.treasury_security
            :if={!@local_lab?}
            report={report(@page_record)}
            surface="auction-detail"
          />
          <.lab_treasury_unavailable :if={@local_lab?} surface="auction-detail" />
          <dl :if={@local_lab? && @market_snapshot} class="autolaunch-live-market">
            <div>
              <dt>Fork block</dt><dd>{@market_snapshot.block_number}</dd>
            </div>
            <div>
              <dt>{@page_record.quote_token_symbol} raised</dt><dd>
                <AutolaunchWeb.TokenDisplay.price
                  amount={@market_snapshot.currency_raised}
                  fallback="—"
                />
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
            :if={@local_lab? && @market_snapshot}
            id="auction-exact-market-amounts"
            summary="Exact market amounts"
          >
            <dl class="autolaunch-live-market">
              <div>
                <dt>{@page_record.quote_token_symbol} raised</dt><dd class="autolaunch-exact-value">
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
        </section>
        <aside class="market-detail-action" aria-label="Bid on this auction">
          <section
            :if={Autolaunch.Prelaunch.read_only?()}
            class="prelaunch-actions"
            aria-label="Bidding unavailable"
          >
            <h2>Place a bid</h2>
            <p>Bidding will be available after contract deployment.</p>
            <Regent.Primitives.button disabled>Place a bid</Regent.Primitives.button>
          </section>
          <.live_component
            :if={!Autolaunch.Prelaunch.read_only?() && !@bidding_ended?}
            module={AutolaunchWeb.BidComponent}
            id="autolaunch-bid"
            auction={@page_record}
            authenticated={@account_control.kind == :signed_in}
            current_human_id={current_human_id(@access_context)}
            session_lease={@session_lease}
          />
          <section
            :if={!Autolaunch.Prelaunch.read_only?() && @bidding_ended?}
            id="autolaunch-settlement"
            class="bid-panel rg-panel rg-panel--surface"
            aria-label="Bidding has ended"
          >
            <header class="bid-heading">
              <Regent.Structure.section_bar>
                <h2 class="rg-section-bar__label">Bidding has ended</h2>
              </Regent.Structure.section_bar>
              <p>{ended_copy(@page_record)}</p>
            </header>
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
      </div>
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

  defp bidding_ended?(%{state: state}, _snapshot) when state in [:graduated, :failed], do: true

  defp bidding_ended?(_record, %{block_number: block, end_block: end_block}),
    do: block >= end_block

  defp bidding_ended?(_record, _snapshot), do: false

  defp ended_copy(%{state: :graduated, quote_token_symbol: symbol}),
    do:
      "The auction raised its minimum. Bids above the final price return their unspent #{symbol} and receive tokens; the rest return what was not spent."

  defp ended_copy(%{state: :failed, quote_token_symbol: symbol}),
    do: "The auction did not raise its minimum. Every bid returns its #{symbol} in full."

  defp ended_copy(%{quote_token_symbol: symbol}),
    do:
      "Bids are being settled. Unspent #{symbol} is returned first; tokens follow on a successful auction."

  # A graduated auction's token row, when it exists, so the page can point at
  # the pool that auction graduated into.
  defp load_auction_page_with_token(id) do
    with {:ok, %{page: page}} <- load_auction_page(id) do
      {:ok, %{page: Map.put(page, :token, graduated_token(page.record))}}
    end
  end

  defp graduated_token(%{state: :graduated, id: auction_id}) do
    case Autolaunch.get_public_token_by_auction(auction_id) do
      {:ok, token} -> token
      {:error, _reason} -> nil
    end
  end

  defp graduated_token(_record), do: nil

  defp page_token(%{ok?: true, result: %{token: token}}), do: token
  defp page_token(_page), do: nil

  defp assign_market(socket) do
    if connected?(socket) and Lab.enabled?() and Process.whereis(LabMarketFeed) do
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
