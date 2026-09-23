defmodule AutolaunchWeb.RobinhoodTokenLive do
  @moduledoc """
  One graduated Robinhood memestock token, named by its token address: the
  one page of that token. The chain is the only record of the launch, so the
  page reads the launch its token came from, names its creator when a
  signed-up account's wallet launched it, names the auction it graduated
  from, and hands the signed-in wallet the trading and staking cards.
  """

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers,
    only: [connections_for: 2, creator_connections_for: 1, current_human_id: 1]

  import AutolaunchWeb.Components.MarketCard, only: [detail_card: 1]

  alias Autolaunch.Chain.Address
  alias Autolaunch.Robinhood.{Auctions, Lab, Pool}

  def mount(_params, _session, socket),
    do: {:ok, assign(socket, open?: Lab.configured?(), swap?: swap_configured?())}

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
        {:noreply, socket |> assign(:token, address) |> load_page()}

      :error ->
        {:noreply,
         assign(socket,
           token: nil,
           launch: %Phoenix.LiveView.AsyncResult{},
           creator_connections: %Phoenix.LiveView.AsyncResult{},
           pool: %Phoenix.LiveView.AsyncResult{}
         )}
    end
  end

  def handle_event("retry", _params, socket), do: {:noreply, load_page(socket)}
  def handle_event("reload_pool", _params, socket), do: {:noreply, load_pool(socket, false)}

  # The staking card confirmed something that moved the pool's figures, so the
  # pool is read again. The previous figures stay on the page while the chain
  # answers, so the card that asked keeps its wallet, position and notice.
  def handle_info(:reload_pool, socket), do: {:noreply, load_pool(socket, false)}

  def render(assigns) do
    ~H"""
    <article
      :if={@open? && @token && @launch.ok?}
      id="autolaunch-robinhood-token"
      class="autolaunch-page"
    >
      <header class="autolaunch-heading">
        <.link navigate="/tokens" class="market-back">← Tokens</.link>
        <Regent.Structure.section_bar>
          <h1 class="rg-section-bar__label">{@launch.result.name} · {@launch.result.symbol}</h1>
        </Regent.Structure.section_bar>
        <p>{network_copy(Lab.test_chain?())}</p>
      </header>
      <.detail_card
        kind={:robinhood_token}
        record={@launch.result}
        creator_connections={@creator_connections.result}
      />
      <dl class="autolaunch-live-market" aria-label="Token facts">
        <div>
          <dt>Token address</dt>
          <dd class="autolaunch-exact-value">{@launch.result.token}</dd>
        </div>
        <div>
          <dt>Trades against</dt>
          <dd>
            {@launch.result.stock_symbol} · {@launch.result.stock_decimals} decimal places
            <span class="autolaunch-exact-value">{@launch.result.stock_address}</span>
          </dd>
        </div>
        <div>
          <dt>Raised in its auction</dt>
          <dd>{@launch.result.raised} {@launch.result.stock_symbol}</dd>
        </div>
      </dl>
      <.live_component
        :if={@swap?}
        module={AutolaunchWeb.SwapComponent}
        id={"robinhood-trade-#{@launch.result.auction}"}
        launch={%{chain: :robinhood, auction: @launch.result.auction}}
        symbol={@launch.result.symbol}
        currency={@launch.result.stock_symbol}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <p class="autolaunch-live-market">
        <.link navigate={"/robinhood/auctions/#{@launch.result.auction}"}>
          Open the auction this token graduated from
        </.link>
      </p>
      <.live_component
        :if={@pool.ok?}
        module={AutolaunchWeb.StakeComponent}
        id={"robinhood-stake-#{@launch.result.auction}"}
        launch={%{chain: :robinhood, auction: @launch.result.auction}}
        pool={@pool.result}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <.live_component
        :if={@pool.ok?}
        module={AutolaunchWeb.ConvertComponent}
        id={"robinhood-convert-#{@launch.result.auction}"}
        launch={%{chain: :robinhood, auction: @launch.result.auction}}
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

    <p :if={@open? && @token && @launch.loading} class="autolaunch-page" role="status">
      Loading…
    </p>

    <section
      :if={!@open? || !@token || @launch.failed == {:error, :not_found}}
      id="autolaunch-robinhood-token"
      class="autolaunch-page autolaunch-empty"
    >
      <Regent.Structure.section_bar>
        <h1 class="rg-section-bar__label">Token not found</h1>
      </Regent.Structure.section_bar>
      <p :if={!@open?}>Robinhood tokens are not open on this site yet.</p>
      <p :if={@open? && !@token}>That is not a token address.</p>
      <p :if={@open? && @token && @launch.failed}>
        No graduated Robinhood token exists at {@token}.
      </p>
      <.link navigate="/tokens">Return to Tokens</.link>
    </section>

    <section
      :if={@open? && @token && unreadable?(@launch)}
      id="autolaunch-robinhood-token"
      class="autolaunch-page autolaunch-empty"
      role="alert"
    >
      <Regent.Structure.section_bar>
        <h1 class="rg-section-bar__label">Token unavailable</h1>
      </Regent.Structure.section_bar>
      <p>This token could not be read from Robinhood right now.</p>
      <Regent.Primitives.button phx-click="retry" variant="secondary">Retry</Regent.Primitives.button>
      <.link navigate="/tokens">Return to Tokens</.link>
    </section>
    """
  end

  defp load_page(%{assigns: %{open?: false}} = socket) do
    assign(socket,
      launch: %Phoenix.LiveView.AsyncResult{},
      creator_connections: %Phoenix.LiveView.AsyncResult{},
      pool: %Phoenix.LiveView.AsyncResult{}
    )
  end

  defp load_page(socket) do
    token = socket.assigns.token

    socket
    |> assign_async(
      [:launch, :creator_connections],
      fn ->
        with {:ok, launch} <- Auctions.fetch_by_token(token) do
          {:ok,
           %{
             launch: launch,
             creator_connections: connections_for(launch, creator_connections_for([launch]))
           }}
        end
      end,
      reset: true
    )
    |> load_pool(true)
  end

  # The pool is its own read of the chain: the launch renders as soon as the
  # launchpad answers, and the staking card says when the pool is slow. A
  # fresh page starts from nothing; a re-read keeps the last figures until the
  # new ones arrive.
  defp load_pool(socket, reset?) do
    token = socket.assigns.token

    assign_async(
      socket,
      :pool,
      fn ->
        with {:ok, launch} <- Auctions.fetch_by_token(token),
             {:ok, facts} <- Pool.read(launch.auction) do
          {:ok, %{pool: facts}}
        end
      end,
      reset: reset?
    )
  end

  defp network_copy(true),
    do: "A Memestake token on the Robinhood test network. Test assets have no real value."

  defp network_copy(false), do: "A Memestake token on Robinhood Chain."

  defp unreadable?(%{failed: nil}), do: false

  defp unreadable?(%{failed: {:error, reason}}) when reason in [:not_found, :not_graduated],
    do: false

  defp unreadable?(_failed), do: true
end
