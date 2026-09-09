defmodule AutolaunchWeb.AuctionLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers
  import AutolaunchWeb.Components.MarketCard

  alias Autolaunch.Lab
  alias Autolaunch.LabMarketFeed
  alias Autolaunch.Stocks.LabMarketFeed, as: StocksMarketFeed

  def mount(_params, _session, socket), do: {:ok, assign_market(socket)}

  # The identifier is read here so a patch to another auction reloads the page
  # instead of keeping the previous record on screen.
  def handle_params(%{"auction_id" => id}, _uri, socket) do
    {:noreply, socket |> assign(:record_id, id) |> load_page(reset: true)}
  end

  def handle_event("retry", _params, socket), do: {:noreply, load_page(socket, reset: true)}

  # Either feed may have moved; the combined reading decides whether the page
  # has anything new to show.
  def handle_info({:autolaunch_market_updated, _update}, socket) do
    market = market_snapshot()

    if market.generation > socket.assigns.market.generation do
      {:noreply, socket |> assign(:market, market) |> load_page(reset: false)}
    else
      {:noreply, socket}
    end
  end

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
        :market_snapshot,
        auction_market_snapshot(assigns.market, assigns.page_record)
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
          <.treasury_security
            :if={!@local_lab?}
            report={report(@page_record)}
            surface="auction-detail"
          />
          <.lab_treasury_unavailable :if={@local_lab?} surface="auction-detail" />
          <dl :if={@local_lab? && @market_snapshot} class="autolaunch-live-market">
            <div>
              <dt>Local block</dt><dd>{@market_snapshot.block_number}</dd>
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
            :if={!Autolaunch.Prelaunch.read_only?()}
            module={AutolaunchWeb.BidComponent}
            id="autolaunch-bid"
            auction={@page_record}
            authenticated={@account_control.kind == :signed_in}
            current_human_id={current_human_id(@access_context)}
            session_lease={@session_lease}
          />
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
    assign_async(socket, :page, fn -> load_auction_page(id) end, reset: reset)
  end

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
