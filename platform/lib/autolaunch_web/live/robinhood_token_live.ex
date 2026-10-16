defmodule AutolaunchWeb.RobinhoodTokenLive do
  @moduledoc """
  One graduated Robinhood memestock token, read by its token address, which
  `AutolaunchWeb.MarketPageLive` hands it from the token's page address. The
  page shows the token as the Robinhood market feed stored it, with its price
  read from its pool, the trade widget (`AutolaunchWeb.Components.TokenTrade`)
  with Claim Rewards beneath it, and the launch's details. Everything else
  about the token is copied for an agent from beside Claim Rewards. When
  Robinhood cannot be read, the page says so and shows what was last read.
  """

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers,
    only: [connections_for: 2, creator_connections_for: 1, current_human_id: 1]

  import AutolaunchWeb.Components.MarketCard, only: [detail_card: 1]
  import AutolaunchWeb.Components.LaunchTrust
  import AutolaunchWeb.Components.PriceChart
  import AutolaunchWeb.Components.TokenHeading
  import AutolaunchWeb.Components.TokenTrade

  alias Autolaunch.MarketReadings
  alias Autolaunch.PoolFees
  alias Autolaunch.Robinhood.{Lab, Pool}
  alias AutolaunchWeb.Components.TokenTrade
  alias AutolaunchWeb.{LabMarket, Paths, ShareCard}

  def mount(%{"auction" => auction}, _session, socket),
    do:
      {:ok,
       socket
       |> assign(open?: Lab.configured?(), swap?: Lab.swap_configured?(), staked?: false)
       |> LabMarket.subscribe_market(auction)
       |> assign(:reading, MarketReadings.market(auction))
       |> LabMarket.assign_robinhood_stale()}

  # The address is read here so a patch to another token reloads the page
  # instead of keeping the previous launch on screen. `?trade=stake` opens the
  # widget on Stake.
  def handle_params(%{"token" => token} = params, _uri, socket) do
    socket = assign(socket, :trade, TokenTrade.pick(params["trade"], tabs(socket.assigns)))
    {:noreply, socket |> assign(:token_address, token) |> load_page()}
  end

  def handle_event("retry", _params, socket), do: {:noreply, load_page(socket)}

  def handle_event("trade", %{"tab" => tab}, socket),
    do: {:noreply, assign(socket, :trade, TokenTrade.pick(tab, tabs(socket.assigns)))}

  def handle_event("reload_pool", _params, socket), do: {:noreply, load_pool(socket, false)}

  # The staking part read the wallet's stake: Unstake is offered only while
  # there is one.
  def handle_info({:staked, staked?}, socket) do
    socket = assign(socket, :staked?, staked?)

    if socket.assigns.trade in tabs(socket.assigns),
      do: {:noreply, socket},
      else: {:noreply, assign(socket, :trade, :stake)}
  end

  # The staking card confirmed something that moved the pool's figures, so the
  # pool is read again. The previous figures stay on the page while the chain
  # answers, so the card that asked keeps its wallet, position and notice.
  def handle_info(:reload_pool, socket), do: {:noreply, load_pool(socket, false)}

  # The feed read a new figure for this token's auction: the stored token and
  # its reading move together.
  def handle_info({:shared_reading, {:auction_market, address}}, socket),
    do: {:noreply, socket |> assign(:reading, MarketReadings.market(address)) |> reload_token()}

  def handle_info({:shared_reading, {:market_feed, "robinhood"}}, socket),
    do: {:noreply, LabMarket.robinhood_stale(socket)}

  def render(assigns), do: page(assigns)

  defp page(assigns) do
    ~H"""
    <article
      :if={@open? && @token}
      id="autolaunch-robinhood-token"
      class="autolaunch-page token-page"
    >
      <header class="autolaunch-heading">
        <.link navigate="/tokens" class="market-back">← Tokens</.link>
        <.token_heading
          name={@token.name}
          symbol={@token.symbol}
          currency={@token.auction.quote_token_symbol}
          chain_id={@token.auction.chain_id}
          pool={if(@pool.ok?, do: @pool.result)}
        />
        <p :if={Lab.test_chain?()}>Robinhood test network. Test assets have no real value.</p>
      </header>
      <p :if={@robinhood_stale?} class="autolaunch-live-market" role="status">
        Robinhood could not be read just now, so this token shows what was last read.
      </p>
      <p :if={@token_failed?} class="autolaunch-live-market" role="status">
        This token could not be read again just now, so it shows what was last read.
      </p>
      <div class="token-page__layout">
        <div class="token-page__overview">
          <.detail_card kind={:token} record={@token}>
            <:chart :if={@pool.ok?}>
              <.price_chart
                id="robinhood-token-price-chart"
                label="Price since the pool opened"
                history={@pool.result.prices}
                unit={@pool.result.currency.symbol}
                color={@token.auction.image_color}
              />
            </:chart>
          </.detail_card>
        </div>
        <.buttons_stage id="token-side" class="token-page__side">
          <.trade_widget id="trade" tab={@trade} swap={@swap?} staked={@staked?}>
            <:pane :if={@swap?} tab={:swap}>
              <.live_component
                module={AutolaunchWeb.SwapComponent}
                id={"robinhood-trade-#{@token.auction.auction_address}"}
                launch={%{chain: :robinhood, auction: @token.auction}}
                symbol={@token.symbol}
                currency={@token.auction.quote_token_symbol}
                authenticated={@account_control.kind == :signed_in}
                current_human_id={current_human_id(@access_context)}
                session_lease={@session_lease}
              />
            </:pane>
            <:pane tab={:stake}>
              <.live_component
                :if={@pool.ok?}
                module={AutolaunchWeb.StakeComponent}
                id={"robinhood-stake-#{@token.auction.auction_address}"}
                part={:stake}
                mode={if @trade == :unstake, do: :unstake, else: :stake}
                launch={%{chain: :robinhood, auction: @token.auction}}
                pool={@pool.result}
                share_url={Paths.token_url(@token.auction)}
                share_image={ShareCard.token_image_url(@token.auction, DateTime.utc_now())}
                authenticated={@account_control.kind == :signed_in}
                current_human_id={current_human_id(@access_context)}
                session_lease={@session_lease}
              />
              <.pool_status :if={!@pool.ok?} pool={@pool} />
            </:pane>
          </.trade_widget>
          <.live_component
            :if={@pool.ok?}
            module={AutolaunchWeb.StakeComponent}
            id={"robinhood-claim-#{@token.auction.auction_address}"}
            part={:claim}
            launch={%{chain: :robinhood, auction: @token.auction}}
            pool={@pool.result}
            details={details(assigns)}
            authenticated={@account_control.kind == :signed_in}
            current_human_id={current_human_id(@access_context)}
            session_lease={@session_lease}
          />
          <.live_component
            :if={@pool.ok?}
            module={AutolaunchWeb.ConvertComponent}
            id={"robinhood-convert-#{@token.auction.auction_address}"}
            launch={%{chain: :robinhood, auction: @token.auction}}
            pool={@pool.result}
            authenticated={@account_control.kind == :signed_in}
            current_human_id={current_human_id(@access_context)}
            session_lease={@session_lease}
          />
        </.buttons_stage>
        <div class="token-page__details">
          <.token_facts
            auction={@token.auction}
            connections={@creator_connections.result}
            pool={if(@pool.ok?, do: @pool.result)}
            price={@token.price_quote}
            unit={@token.auction.quote_token_symbol}
          />
        </div>
      </div>
    </article>
    <.states
      open?={@open?}
      token={@token}
      token_failed?={@token_failed?}
      token_address={@token_address}
    />
    """
  end

  defp tabs(assigns), do: TokenTrade.tabs(assigns.swap?, assigns.staked?)

  # What Copy Full Token Details to Agent copies, as the page has read it
  # (`AutolaunchWeb.TokenDetails`).
  defp details(assigns) do
    %{token: token, pool: pool, fee_totals: fees, reading: reading} = assigns

    %{
      name: token.name,
      symbol: token.symbol,
      url: Paths.token_url(token.auction),
      auction: token.auction,
      pool: pool.result,
      fees: fees.result,
      supply: token.auction.token_supply,
      price: token.price_quote,
      treasury: nil,
      raised: reading && reading.currency_raised
    }
  end

  attr :open?, :boolean, required: true
  attr :token, :any, required: true
  attr :token_failed?, :boolean, required: true
  attr :token_address, :string, required: true

  defp states(assigns) do
    ~H"""
    <section
      :if={!@open? || (!@token && !@token_failed?)}
      id="autolaunch-robinhood-token"
      class="autolaunch-page autolaunch-empty"
    >
      <Regent.Structure.section_bar>
        <h1 class="rg-section-bar__label">Token not found</h1>
      </Regent.Structure.section_bar>
      <p :if={!@open?}>Robinhood tokens are not open on this site yet.</p>
      <p :if={@open?}>No graduated Robinhood token exists at {@token_address}.</p>
      <.link navigate="/tokens">Return to Tokens</.link>
    </section>

    <section
      :if={@open? && !@token && @token_failed?}
      id="autolaunch-robinhood-token"
      class="autolaunch-page autolaunch-empty"
      role="alert"
    >
      <Regent.Structure.section_bar>
        <h1 class="rg-section-bar__label">Token unavailable</h1>
      </Regent.Structure.section_bar>
      <p>This token could not be loaded right now.</p>
      <Regent.Primitives.button phx-click="retry" variant="secondary">Retry</Regent.Primitives.button>
      <.link navigate="/tokens">Return to Tokens</.link>
    </section>
    """
  end

  defp load_page(%{assigns: %{open?: false}} = socket),
    do: assign(socket, token: nil, token_failed?: false)

  # Another token's page starts from nothing, so a failed read never leaves
  # the previous token on screen.
  defp load_page(socket) do
    socket = socket |> assign(:token, nil) |> reload_token()
    token = socket.assigns.token

    socket
    |> assign_async(
      :creator_connections,
      fn ->
        {:ok,
         %{creator_connections: token && connections_for(token, creator_connections_for([token]))}}
      end,
      reset: true
    )
    |> load_pool(true)
  end

  defp reload_token(%{assigns: %{open?: false}} = socket), do: socket

  # A failed re-read keeps the token already on screen and says so.
  defp reload_token(socket) do
    case Autolaunch.get_robinhood_token(socket.assigns.token_address, actor: nil) do
      {:ok, token} -> assign(socket, token: token, token_failed?: false)
      {:error, _reason} -> assign(socket, :token_failed?, true)
    end
  end

  # The pool is its own read of the chain: the token renders from its stored
  # row at once, and the trade widget says when the pool is slow. The fees it
  # has charged arrive with it. A fresh page
  # starts from nothing; a re-read keeps the last figures until the new ones
  # arrive.
  defp load_pool(%{assigns: %{token: nil}} = socket, _reset?),
    do:
      assign(socket,
        pool: %Phoenix.LiveView.AsyncResult{},
        fee_totals: %Phoenix.LiveView.AsyncResult{}
      )

  defp load_pool(socket, reset?) do
    token = socket.assigns.token

    assign_async(
      socket,
      [:pool, :fee_totals],
      fn ->
        with {:ok, facts} <- Pool.read(token.auction),
             do: {:ok, %{pool: facts, fee_totals: PoolFees.totals(facts, token)}}
      end,
      reset: reset?
    )
  end
end
