defmodule AutolaunchWeb.RobinhoodTokenLive do
  @moduledoc """
  One graduated Robinhood memestock token, read by its token address, which
  `AutolaunchWeb.MarketPageLive` hands it from the token's page address. The page shows the token and the launch it came
  from as the Robinhood market feed stored them, with the feed's latest
  reading of what its auction raised. It names its creator when a signed-up
  account's wallet launched it, names the auction it graduated from, and
  hands the signed-in wallet the trading and staking cards, whose figures are
  read from the chain. When Robinhood cannot be read, the page says so and
  shows what was last read. At `/next/tokens/…` it shows the new page
  (`AutolaunchWeb.Components.TokenNext`) beside the current one.
  """

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers,
    only: [connections_for: 2, creator_connections_for: 1, current_human_id: 1]

  import AutolaunchWeb.Components.MarketCard, only: [detail_card: 1]
  import AutolaunchWeb.Components.LaunchTrust
  import AutolaunchWeb.Components.PriceChart
  import AutolaunchWeb.Components.StakeSummary
  import AutolaunchWeb.Components.TokenHeading
  import AutolaunchWeb.Components.TokenNext

  alias Autolaunch.PoolFees
  alias Autolaunch.Robinhood.{Lab, Pool}
  alias Autolaunch.Stocks.MarketData
  alias AutolaunchWeb.{LabMarket, Paths, ShareCard, TokenDisplay}

  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket,
         open?: Lab.configured?(),
         swap?: Lab.swap_configured?(),
         market: LabMarket.subscribe(socket)
       )}

  # The address is read here so a patch to another token reloads the page
  # instead of keeping the previous launch on screen.
  def handle_params(%{"token" => token} = params, _uri, socket) do
    amount = if is_binary(params["stake"]), do: String.slice(params["stake"], 0, 256), else: ""
    socket = assign(socket, :stake_amount, amount)

    {:noreply, socket |> assign(:token_address, token) |> load_page()}
  end

  def handle_event("retry", _params, socket), do: {:noreply, load_page(socket)}
  def handle_event("reload_pool", _params, socket), do: {:noreply, load_pool(socket, false)}

  # The staking card confirmed something that moved the pool's figures, so the
  # pool is read again. The previous figures stay on the page while the chain
  # answers, so the card that asked keeps its wallet, position and notice.
  def handle_info(:reload_pool, socket), do: {:noreply, load_pool(socket, false)}

  # The feed read Robinhood again: the stored token and its reading move
  # together.
  def handle_info({:robinhood_market_updated, _update}, socket),
    do: {:noreply, socket |> assign(:market, LabMarket.snapshot()) |> reload_token()}

  def handle_info({:autolaunch_market_updated, _update}, socket),
    do: {:noreply, assign(socket, :market, LabMarket.snapshot())}

  def render(assigns) do
    assigns =
      assign(
        assigns,
        :reading,
        assigns.token && LabMarket.reading(assigns.market, assigns.token.auction.auction_address)
      )

    page(assigns)
  end

  # The new page, in preview at /next/tokens/…: one reward followed from the
  # trade to the claim beside the staking card, then the market, the locked
  # liquidity and the launch's details.
  defp page(%{design: :next} = assigns) do
    ~H"""
    <article
      :if={@open? && @token}
      id="autolaunch-robinhood-token"
      class="autolaunch-page token-page token-next"
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
        <p>{network_copy(Lab.test_chain?())}</p>
        <p class="token-next-preview">
          This is the new token page.
          <.link navigate={Paths.token(@token.auction)}>Open the current page</.link>
        </p>
      </header>
      <p :if={@market.robinhood_stale?} class="autolaunch-live-market" role="status">
        Robinhood could not be read just now, so this token shows what was last read.
      </p>
      <p :if={@token_failed?} class="autolaunch-live-market" role="status">
        This token could not be read again just now, so it shows what was last read.
      </p>
      <.detail_card kind={:token} record={@token} />
      <div class="token-next-layout">
        <div class="token-next-layout__main">
          <.reward_trace
            :if={@pool.ok?}
            id="robinhood-token-reward-trace"
            pool={@pool.result}
            supply={@token.auction.token_supply}
          />
        </div>
        <section id="stake" class="token-stake token-next-layout__side" aria-label="Staking">
          <.stake_summary
            :if={@pool.ok?}
            id="robinhood-token-staked"
            pool={@pool.result}
            supply={@token.auction.token_supply}
            label="Memestake"
            fees={@fee_totals.result}
            rate={@usd_rate.result}
          />
          <.live_component
            :if={@pool.ok?}
            module={AutolaunchWeb.StakeComponent}
            id={"robinhood-stake-#{@token.auction.auction_address}"}
            launch={%{chain: :robinhood, auction: @token.auction.auction_address}}
            pool={@pool.result}
            initial_amount={@stake_amount}
            share_url={Paths.token_url(@token.auction)}
            share_image={ShareCard.token_image_url(@token.auction, DateTime.utc_now())}
            authenticated={@account_control.kind == :signed_in}
            current_human_id={current_human_id(@access_context)}
            session_lease={@session_lease}
            design={:next}
            supply={@token.auction.token_supply}
          />
          <p :if={@pool.loading} role="status">Reading the staking figures…</p>
          <p :if={@pool.failed == {:error, :not_graduated}} class="autolaunch-live-market">
            This token has not been moved into its pool yet. Staking opens once it is.
          </p>
          <div :if={unreadable?(@pool)} role="alert" class="autolaunch-empty">
            <p>The staking figures could not be read just now.</p>
            <Regent.Primitives.button phx-click="reload_pool" variant="secondary">
              Read again
            </Regent.Primitives.button>
          </div>
        </section>
      </div>
      <.price_chart
        :if={@pool.ok?}
        id="robinhood-token-price-chart"
        label="Price since the pool opened"
        history={@pool.result.prices}
        unit={@pool.result.currency.symbol}
        color={@token.auction.image_color}
      />
      <dl class="autolaunch-live-market" aria-label="Token facts">
        <div>
          <dt>Token address</dt>
          <dd class="autolaunch-exact-value">{@token.auction.token_address}</dd>
        </div>
        <div>
          <dt>Trades against</dt>
          <dd>
            <span class="ticker">{@token.auction.quote_token_symbol}</span>
            · <span class="figure__value">{@token.auction.quote_token_decimals}</span>
            decimal places
            <span class="autolaunch-exact-value">{@token.auction.quote_token_address}</span>
          </dd>
        </div>
        <div :if={@reading}>
          <dt>Raised in its auction</dt>
          <dd>
            <TokenDisplay.written
              value={@reading.currency_raised}
              unit={@token.auction.quote_token_symbol}
            />
          </dd>
        </div>
      </dl>
      <.live_component
        :if={@swap?}
        module={AutolaunchWeb.SwapComponent}
        id={"robinhood-trade-#{@token.auction.auction_address}"}
        agent_tools
        launch={%{chain: :robinhood, auction: @token.auction.auction_address}}
        symbol={@token.symbol}
        currency={@token.auction.quote_token_symbol}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <p class="autolaunch-live-market">
        <.link navigate={Paths.next_auction(@token.auction)}>
          Open the auction this token graduated from
        </.link>
      </p>
      <.liquidity :if={@pool.ok?} id="robinhood-token-liquidity" pool={@pool.result} />
      <.launch_trust
        auction={@token.auction}
        connections={@creator_connections.result}
        pool={if(@pool.ok?, do: @pool.result)}
        design={:next}
      />
      <.live_component
        :if={@pool.ok?}
        module={AutolaunchWeb.ConvertComponent}
        id={"robinhood-convert-#{@token.auction.auction_address}"}
        launch={%{chain: :robinhood, auction: @token.auction.auction_address}}
        pool={@pool.result}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <p :if={@pool.ok?} class="autolaunch-live-market">
        Read at block {@pool.result.block.number}.
        <Regent.Primitives.button phx-click="reload_pool" variant="secondary">
          Read again
        </Regent.Primitives.button>
      </p>
    </article>
    <.states
      open?={@open?}
      token={@token}
      token_failed?={@token_failed?}
      token_address={@token_address}
    />
    """
  end

  defp page(assigns) do
    ~H"""
    <article :if={@open? && @token} id="autolaunch-robinhood-token" class="autolaunch-page token-page">
      <header class="autolaunch-heading">
        <.link navigate="/tokens" class="market-back">← Tokens</.link>
        <.token_heading
          name={@token.name}
          symbol={@token.symbol}
          currency={@token.auction.quote_token_symbol}
          chain_id={@token.auction.chain_id}
          pool={if(@pool.ok?, do: @pool.result)}
        />
        <p>{network_copy(Lab.test_chain?())}</p>
      </header>
      <p :if={@market.robinhood_stale?} class="autolaunch-live-market" role="status">
        Robinhood could not be read just now, so this token shows what was last read.
      </p>
      <p :if={@token_failed?} class="autolaunch-live-market" role="status">
        This token could not be read again just now, so it shows what was last read.
      </p>
      <.detail_card
        kind={:token}
        record={@token}
      />
      <section id="stake" class="token-stake" aria-label="Staking">
        <.stake_summary
          :if={@pool.ok?}
          id="robinhood-token-staked"
          pool={@pool.result}
          supply={@token.auction.token_supply}
          label="Memestake"
          fees={@fee_totals.result}
          rate={@usd_rate.result}
        />
        <.live_component
          :if={@pool.ok?}
          module={AutolaunchWeb.StakeComponent}
          id={"robinhood-stake-#{@token.auction.auction_address}"}
          launch={%{chain: :robinhood, auction: @token.auction.auction_address}}
          pool={@pool.result}
          initial_amount={@stake_amount}
          share_url={Paths.token_url(@token.auction)}
          share_image={ShareCard.token_image_url(@token.auction, DateTime.utc_now())}
          authenticated={@account_control.kind == :signed_in}
          current_human_id={current_human_id(@access_context)}
          session_lease={@session_lease}
        />
      </section>
      <.price_chart
        :if={@pool.ok?}
        id="robinhood-token-price-chart"
        label="Price since the pool opened"
        history={@pool.result.prices}
        unit={@pool.result.currency.symbol}
        color={@token.auction.image_color}
      />
      <dl class="autolaunch-live-market" aria-label="Token facts">
        <div>
          <dt>Token address</dt>
          <dd class="autolaunch-exact-value">{@token.auction.token_address}</dd>
        </div>
        <div>
          <dt>Trades against</dt>
          <dd>
            <span class="ticker">{@token.auction.quote_token_symbol}</span>
            · <span class="figure__value">{@token.auction.quote_token_decimals}</span>
            decimal places
            <span class="autolaunch-exact-value">{@token.auction.quote_token_address}</span>
          </dd>
        </div>
        <div :if={@reading}>
          <dt>Raised in its auction</dt>
          <dd>
            <TokenDisplay.written
              value={@reading.currency_raised}
              unit={@token.auction.quote_token_symbol}
            />
          </dd>
        </div>
      </dl>
      <.live_component
        :if={@swap?}
        module={AutolaunchWeb.SwapComponent}
        id={"robinhood-trade-#{@token.auction.auction_address}"}
        agent_tools
        launch={%{chain: :robinhood, auction: @token.auction.auction_address}}
        symbol={@token.symbol}
        currency={@token.auction.quote_token_symbol}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <p class="autolaunch-live-market">
        <.link navigate={Paths.auction(@token.auction)}>
          Open the auction this token graduated from
        </.link>
      </p>
      <.launch_trust
        auction={@token.auction}
        connections={@creator_connections.result}
        pool={if(@pool.ok?, do: @pool.result)}
      />
      <.live_component
        :if={@pool.ok?}
        module={AutolaunchWeb.ConvertComponent}
        id={"robinhood-convert-#{@token.auction.auction_address}"}
        launch={%{chain: :robinhood, auction: @token.auction.auction_address}}
        pool={@pool.result}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <p :if={@pool.loading} role="status">Reading the staking figures…</p>
      <p :if={@pool.ok?} class="autolaunch-live-market">
        Read at block {@pool.result.block.number}.
        <Regent.Primitives.button phx-click="reload_pool" variant="secondary">
          Read again
        </Regent.Primitives.button>
      </p>
      <p :if={@pool.failed == {:error, :not_graduated}} class="autolaunch-live-market">
        This token has not been moved into its pool yet. Staking opens once it is.
      </p>
      <div :if={unreadable?(@pool)} role="alert" class="autolaunch-empty">
        <p>The staking figures could not be read just now.</p>
        <Regent.Primitives.button phx-click="reload_pool" variant="secondary">
          Read again
        </Regent.Primitives.button>
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
  # row at once, and the staking card says when the pool is slow. The fees it
  # has charged and its stock's dollar price arrive with it. A fresh page
  # starts from nothing; a re-read keeps the last figures until the new ones
  # arrive.
  defp load_pool(%{assigns: %{token: nil}} = socket, _reset?),
    do:
      assign(socket,
        pool: %Phoenix.LiveView.AsyncResult{},
        fee_totals: %Phoenix.LiveView.AsyncResult{},
        usd_rate: %Phoenix.LiveView.AsyncResult{}
      )

  defp load_pool(socket, reset?) do
    token = socket.assigns.token

    assign_async(
      socket,
      [:pool, :fee_totals, :usd_rate],
      fn ->
        with {:ok, facts} <- Pool.read(token.auction.auction_address) do
          {:ok,
           %{
             pool: facts,
             fee_totals: PoolFees.totals(facts, token),
             usd_rate: usd_rate(token.auction.quote_token_symbol)
           }}
        end
      end,
      reset: reset?
    )
  end

  defp usd_rate(symbol) do
    if Lab.test_chain?(),
      do: :test_network,
      else: MarketData.stock_price(:robinhood, symbol)
  end

  defp network_copy(true),
    do: "A Memestake token on the Robinhood test network. Test assets have no real value."

  defp network_copy(false), do: "A Memestake token on Robinhood Chain."

  defp unreadable?(%{failed: nil}), do: false
  defp unreadable?(%{failed: {:error, :not_graduated}}), do: false
  defp unreadable?(_failed), do: true
end
