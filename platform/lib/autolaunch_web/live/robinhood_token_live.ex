defmodule AutolaunchWeb.RobinhoodTokenLive do
  @moduledoc """
  One graduated Robinhood memestock token, read by its token address, which
  `AutolaunchWeb.MarketPageLive` hands it from the token's page address. The
  page shows the token as the site stored it, with its price
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
  import AutolaunchWeb.Components.TokenFigures
  import AutolaunchWeb.Components.TokenHeading
  import AutolaunchWeb.Components.TokenTrade

  alias Autolaunch.PoolFees
  alias Autolaunch.Robinhood.{Lab, Pool}
  alias AutolaunchWeb.Components.{CreatorLabel, ShareLaunch, TokenTrade}
  alias AutolaunchWeb.{LabMarket, Paths, ShareCard, UsdValue}

  def mount(%{"auction_id" => auction_id}, _session, socket),
    do:
      {:ok,
       socket
       |> assign(
         open?: Lab.configured?(),
         swap?: Lab.swap_configured?(),
         staked?: false,
         claimed?: false,
         balances_read: 0
       )
       |> LabMarket.subscribe_market(auction_id)
       |> assign(:reading, auction_id |> LabMarket.reading() |> elem(0))
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

  def handle_event("refresh_balances", _params, socket), do: {:noreply, balances_read(socket)}

  # The staking part read the wallet's stake: Unstake is offered only while
  # there is one.
  def handle_info({:staked, staked?}, socket) do
    socket = assign(socket, :staked?, staked?)

    if socket.assigns.trade in tabs(socket.assigns),
      do: {:noreply, socket},
      else: {:noreply, assign(socket, :trade, :stake)}
  end

  # A swap or a conversion landed and moved the pool's figures, so the
  # pool is read again. The previous figures stay on the page while the chain
  # answers, so the card that asked keeps its wallet, position and notice.
  def handle_info(:reload_pool, socket), do: {:noreply, load_pool(socket, false)}

  # A staking or claim step landed, so every wallet figure on the page is read
  # again, as Refresh balances does.
  def handle_info(:refresh_balances, socket), do: {:noreply, balances_read(socket)}

  # Claim Rewards confirmed a claim: the widget opens Stake, which says why to
  # stake, and a light swirls from the claim button (`from`) into it.
  def handle_info({:claimed, from}, socket),
    do:
      {:noreply,
       socket
       |> assign(claimed?: true, trade: :stake)
       |> push_event("stake-light", %{from: from})}

  # This token's auction was read with a new figure: the stored token and its
  # reading move together.
  def handle_info(%{topic: "public:auction_market:" <> _id} = notice, socket),
    do:
      {:noreply,
       socket
       |> assign(:reading, LabMarket.newer(socket.assigns.reading, notice.payload))
       |> reload_token()}

  def handle_info({:shared_reading, {:chain_head, "robinhood"}}, socket),
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
          address={@token.auction.token_address}
          pool={if(@pool.ok?, do: @pool.result)}
          own_chart={own_chart(@pool, "robinhood-token-price-chart")}
        />
        <CreatorLabel.creator
          :if={@creator_connections.ok?}
          auction={@token.auction}
          connections={@creator_connections.result}
        />
        <ShareLaunch.share_launch
          id="share-launch"
          auction={@token.auction}
          account_control={@account_control}
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
            <:figures>
              <.token_figures
                id="token-figures"
                price={@token.price_quote}
                market_cap={@token.market_cap}
                unit={@token.auction.quote_token_symbol}
                rate={@usd_rate}
                pool={@pool}
              />
            </:figures>
            <:chart :if={@pool.ok? || @pool.loading}>
              <.price_chart_reading :if={!@pool.ok?} />
              <.price_chart
                :if={@pool.ok?}
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
                balances_read={@balances_read}
              />
            </:pane>
            <:pane tab={:stake}>
              <.live_component
                :if={@pool.ok?}
                module={AutolaunchWeb.StakeComponent}
                id={"robinhood-stake-#{@token.auction.auction_address}"}
                part={:stake}
                fee_asset={if @claimed?, do: @pool.result.currency.symbol}
                mode={if @trade == :unstake, do: :unstake, else: :stake}
                launch={%{chain: :robinhood, auction: @token.auction}}
                pool={@pool.result}
                share_url={Paths.token_url(@token.auction)}
                share_image={ShareCard.token_image_url(@token.auction, DateTime.utc_now())}
                authenticated={@account_control.kind == :signed_in}
                current_human_id={current_human_id(@access_context)}
                session_lease={@session_lease}
                balances_read={@balances_read}
              />
              <.pool_status :if={!@pool.ok?} pool={@pool} />
            </:pane>
          </.trade_widget>
          <.claim_reading pool={@pool} />
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
            balances_read={@balances_read}
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

  # The page draws its own price chart once the pool has two prices to join.
  defp own_chart(%{ok?: true, result: %{prices: %{points: [_first, _second | _rest]}}}, id),
    do: id

  defp own_chart(_pool, _id), do: nil

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
      raised: reading && reading.market.currency_raised
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
    |> assign_async(
      :usd_rate,
      fn ->
        {:ok, %{usd_rate: token && UsdValue.auction_rate(UsdValue.rates(), token.auction)}}
      end,
      reset: true
    )
    |> load_pool(true)
  end

  defp reload_token(%{assigns: %{open?: false}} = socket), do: socket

  # A failed re-read keeps the token already on screen and says so.
  defp reload_token(socket) do
    case Autolaunch.get_robinhood_token(socket.assigns.token_address,
           actor: nil,
           load: [:market_cap]
         ) do
      {:ok, token} -> assign(socket, token: token, token_failed?: false)
      {:error, _reason} -> assign(socket, :token_failed?, true)
    end
  end

  # Refresh balances: the pool is read again at the latest block, and the swap
  # and staking parts read the wallet's balances, stake and rewards again,
  # once now and again when the new pool arrives.
  defp balances_read(socket),
    do: socket |> update(:balances_read, &(&1 + 1)) |> load_pool(false)

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
