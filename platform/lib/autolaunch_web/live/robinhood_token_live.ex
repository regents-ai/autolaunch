defmodule AutolaunchWeb.RobinhoodTokenLive do
  @moduledoc """
  One graduated Robinhood memestock token, named by its token address: the
  one page of that token. The page shows the token and the launch it came
  from as the Robinhood market feed stored them, with the feed's latest
  reading of what its auction raised. It names its creator when a signed-up
  account's wallet launched it, names the auction it graduated from, and
  hands the signed-in wallet the trading and staking cards, whose figures are
  read from the chain. When Robinhood cannot be read, the page says so and
  shows what was last read.
  """

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers,
    only: [connections_for: 2, creator_connections_for: 1, current_human_id: 1]

  import AutolaunchWeb.Components.MarketCard, only: [detail_card: 1]
  import AutolaunchWeb.Components.PriceChart

  alias Autolaunch.Chain.Address
  alias Autolaunch.Robinhood.{Lab, Pool}
  alias AutolaunchWeb.LabMarket

  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket,
         open?: Lab.configured?(),
         swap?: swap_configured?(),
         market: LabMarket.subscribe(socket)
       )}

  # Trading is offered only by a deployment that names its router and quoter.
  defp swap_configured? do
    case Lab.current() do
      {:ok, config} -> match?({:ok, _addresses}, Lab.swap_addresses(config))
      {:error, _reason} -> false
    end
  end

  # The address is read here so a patch to another token reloads the page
  # instead of keeping the previous launch on screen.
  def handle_params(%{"token" => token}, _uri, socket) do
    case Address.normalize(token) do
      {:ok, address} ->
        {:noreply, socket |> assign(:token_address, address) |> load_page()}

      :error ->
        {:noreply, assign(socket, token_address: nil, token: nil)}
    end
  end

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

    ~H"""
    <article :if={@open? && @token} id="autolaunch-robinhood-token" class="autolaunch-page">
      <header class="autolaunch-heading">
        <.link navigate="/tokens" class="market-back">← Tokens</.link>
        <Regent.Structure.section_bar>
          <h1 class="rg-section-bar__label">{@token.name} · {@token.symbol}</h1>
        </Regent.Structure.section_bar>
        <p>{network_copy(Lab.test_chain?())}</p>
      </header>
      <p :if={@market.robinhood_stale?} class="autolaunch-live-market" role="status">
        Robinhood could not be read just now, so this token shows what was last read.
      </p>
      <.detail_card
        kind={:token}
        record={@token}
        creator_connections={@creator_connections.result}
      />
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
            {@token.auction.quote_token_symbol} · {@token.auction.quote_token_decimals} decimal places
            <span class="autolaunch-exact-value">{@token.auction.quote_token_address}</span>
          </dd>
        </div>
        <div :if={@reading}>
          <dt>Raised in its auction</dt>
          <dd>{@reading.currency_raised} {@token.auction.quote_token_symbol}</dd>
        </div>
      </dl>
      <.live_component
        :if={@swap?}
        module={AutolaunchWeb.SwapComponent}
        id={"robinhood-trade-#{@token.auction.auction_address}"}
        launch={%{chain: :robinhood, auction: @token.auction.auction_address}}
        symbol={@token.symbol}
        currency={@token.auction.quote_token_symbol}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <p class="autolaunch-live-market">
        <.link navigate={"/robinhood/auctions/#{@token.auction.auction_address}"}>
          Open the auction this token graduated from
        </.link>
      </p>
      <.live_component
        :if={@pool.ok?}
        module={AutolaunchWeb.StakeComponent}
        id={"robinhood-stake-#{@token.auction.auction_address}"}
        launch={%{chain: :robinhood, auction: @token.auction.auction_address}}
        pool={@pool.result}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
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

    <section
      :if={!@open? || !@token}
      id="autolaunch-robinhood-token"
      class="autolaunch-page autolaunch-empty"
    >
      <Regent.Structure.section_bar>
        <h1 class="rg-section-bar__label">Token not found</h1>
      </Regent.Structure.section_bar>
      <p :if={!@open?}>Robinhood tokens are not open on this site yet.</p>
      <p :if={@open? && !@token_address}>That is not a token address.</p>
      <p :if={@open? && @token_address}>
        No graduated Robinhood token exists at {@token_address}.
      </p>
      <.link navigate="/tokens">Return to Tokens</.link>
    </section>
    """
  end

  defp load_page(%{assigns: %{open?: false}} = socket), do: assign(socket, token: nil)

  defp load_page(socket) do
    socket = reload_token(socket)
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

  defp reload_token(socket) do
    {:ok, token} = Autolaunch.get_robinhood_token(socket.assigns.token_address, actor: nil)
    assign(socket, :token, token)
  end

  # The pool is its own read of the chain: the token renders from its stored
  # row at once, and the staking card says when the pool is slow. A fresh page
  # starts from nothing; a re-read keeps the last figures until the new ones
  # arrive.
  defp load_pool(%{assigns: %{token: nil}} = socket, _reset?),
    do: assign(socket, :pool, %Phoenix.LiveView.AsyncResult{})

  defp load_pool(socket, reset?) do
    auction = socket.assigns.token.auction.auction_address

    assign_async(
      socket,
      :pool,
      fn -> with {:ok, facts} <- Pool.read(auction), do: {:ok, %{pool: facts}} end,
      reset: reset?
    )
  end

  defp network_copy(true),
    do: "A Memestake token on the Robinhood test network. Test assets have no real value."

  defp network_copy(false), do: "A Memestake token on Robinhood Chain."

  defp unreadable?(%{failed: nil}), do: false
  defp unreadable?(%{failed: {:error, :not_graduated}}), do: false
  defp unreadable?(_failed), do: true
end
