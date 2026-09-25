defmodule AutolaunchWeb.TokenLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers
  import AutolaunchWeb.Components.MarketCard
  import AutolaunchWeb.Components.LaunchTrust
  import AutolaunchWeb.Components.PoolSection
  import AutolaunchWeb.Components.PriceChart

  alias Autolaunch.Lab
  alias Autolaunch.Pool
  alias AutolaunchWeb.{LabMarket, LiveListings, Paths, ShareCard}
  alias AutolaunchWeb.SwapComponent

  def mount(_params, _session, socket) do
    LabMarket.subscribe(socket)
    {:ok, LiveListings.subscribe(socket)}
  end

  # The identifier is read here so a patch to another token reloads the page
  # instead of keeping the previous record on screen.
  def handle_params(%{"token_id" => id} = params, _uri, socket) do
    amount = if is_binary(params["stake"]), do: String.slice(params["stake"], 0, 256), else: ""
    socket = assign(socket, :stake_amount, amount)
    {:noreply, socket |> assign(:record_id, id) |> load_page()}
  end

  def handle_event("retry", _params, socket), do: {:noreply, load_page(socket)}
  def handle_event("reload_pool", _params, socket), do: {:noreply, load_pool(socket, false)}

  # The staking card confirmed something that moved the pool's figures, so the
  # pool is read again. The previous figures stay on the page while the fork
  # answers, so the card that asked keeps its wallet, position and notice.
  def handle_info(:reload_pool, socket), do: {:noreply, load_pool(socket, false)}

  # The market feed saw this token's auction change: a trade moved its pool,
  # so the price and the pool are read again. Other tokens' changes are not
  # this page's business.
  def handle_info({:autolaunch_market_updated, %{auction_ids: auction_ids}}, socket) do
    if page_auction_id(socket.assigns.page) in auction_ids,
      do: {:noreply, refresh(socket)},
      else: {:noreply, socket}
  end

  # This token's auction saved a change, so the page reads it again in place.
  def handle_info({:autolaunch_listings_changed, auction_id}, socket) do
    if auction_id == page_auction_id(socket.assigns.page),
      do: {:noreply, LiveListings.schedule(socket)},
      else: {:noreply, socket}
  end

  def handle_info(:reread_listings, socket),
    do: {:noreply, socket |> LiveListings.taken() |> refresh()}

  # LabMarket subscribes to both networks; this page represents a Base token.
  def handle_info({:robinhood_market_updated, _update}, socket), do: {:noreply, socket}

  def render(assigns) do
    page_record = page_record(assigns.page)

    assigns =
      assign(assigns,
        local_lab?: Lab.test_chain?(),
        page_record: page_record,
        presentation: page_record && Autolaunch.Token.presentation(page_record),
        page_status: page_status(assigns.page, :error),
        creator_connections: page_connections(assigns.page)
      )

    ~H"""
    <article
      :if={@page_status == :ready && @page_record}
      id="autolaunch-token-detail"
      class="autolaunch-page"
    >
      <header class="autolaunch-heading">
        <.link navigate="/tokens" class="market-back">← Tokens</.link>
        <Regent.Structure.section_bar>
          <h1 class="rg-section-bar__label">{record_label(:token, @page_record)}</h1>
        </Regent.Structure.section_bar>
      </header>
      <.detail_card
        kind={:token}
        record={@page_record}
      />
      <.price_chart
        :if={@pool.ok?}
        id="token-price-chart"
        label="Price since the pool opened"
        history={@pool.result.prices}
        unit={@pool.result.currency.symbol}
        color={@presentation.image_color}
      />
      <.exact_price
        id="token-exact-price"
        summary="Price to 18 decimals"
        amount={@page_record.price_quote}
        unit={SwapComponent.entry_symbol(@page_record.auction)}
      />
      <.live_component
        module={AutolaunchWeb.SwapComponent}
        id={"token-trade-#{@page_record.id}"}
        launch={%{chain: :base, auction: @page_record.auction}}
        symbol={@presentation.symbol}
        image={@presentation.image}
        currency={SwapComponent.entry_symbol(@page_record.auction)}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <p :if={@page_record.auction.auction_address} class="autolaunch-live-market">
        <.link navigate={Paths.auction(@page_record.auction)}>Open the auction this token launched from</.link>
      </p>
      <.launch_trust
        auction={@page_record.auction}
        connections={@creator_connections}
        pool={if(@pool.ok?, do: @pool.result)}
      />
      <.pool_facts pool={@pool} />
      <section id="stake" aria-label="Staking">
        <.live_component
          :if={@pool.ok?}
          module={AutolaunchWeb.StakeComponent}
          id={"token-stake-#{@page_record.id}"}
          launch={%{chain: :base, auction: @page_record.auction}}
          pool={@pool.result}
          initial_amount={@stake_amount}
          share_url={Paths.token_url(@page_record.auction)}
          share_image={ShareCard.token_image_url(@page_record.auction, DateTime.utc_now())}
          authenticated={@account_control.kind == :signed_in}
          current_human_id={current_human_id(@access_context)}
          session_lease={@session_lease}
        />
      </section>
      <.live_component
        :if={
          @pool.ok? && @pool.result.kind == :agent && !@local_lab? &&
            !Autolaunch.Prelaunch.read_only?()
        }
        module={AutolaunchWeb.SubjectWalletComponent}
        id={"token-payment-#{@page_record.id}"}
        subject_id={Autolaunch.LabProjection.subject_identity(@pool.result.token.address)}
        symbol={@presentation.symbol}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <.live_component
        :if={@pool.ok? && @pool.result.kind == :stocks}
        module={AutolaunchWeb.ConvertComponent}
        id={"token-convert-#{@page_record.id}"}
        launch={%{chain: :base, auction: @page_record.auction}}
        pool={@pool.result}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <.treasury_security
        :if={@page_record.auction.kind == :agent && !@local_lab?}
        report={report(@page_record)}
        surface="token-detail"
      />
      <.lab_treasury_unavailable
        :if={@page_record.auction.kind == :agent && @local_lab?}
        surface="token-detail"
      />
    </article>

    <p :if={@page_status == :loading} class="autolaunch-page" role="status">Loading…</p>

    <section
      :if={@page_status == :empty}
      id="autolaunch-token-detail"
      class="autolaunch-page autolaunch-empty"
    >
      <Regent.Structure.section_bar>
        <h1 class="rg-section-bar__label">Token not found</h1>
      </Regent.Structure.section_bar>
      <p>No public token exists at {@record_id}.</p>
      <.link navigate="/tokens">Return to Tokens</.link>
    </section>

    <section
      :if={@page_status == :error}
      id="autolaunch-token-detail"
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

  defp load_page(socket) do
    id = socket.assigns.record_id

    socket
    |> assign_async(:page, fn -> load_token_page(id) end, reset: true)
    |> load_pool(true)
  end

  # A re-read keeps the record and the pool on the page until the new ones
  # arrive, so the page never blanks while the chain answers.
  defp refresh(socket) do
    id = socket.assigns.record_id

    socket
    |> assign_async(:page, fn -> load_token_page(id) end, reset: false)
    |> load_pool(false)
  end

  defp page_auction_id(%{ok?: true, result: %{record: %{auction: %{id: id}}}}), do: id
  defp page_auction_id(_page), do: nil

  # The pool is its own read of the chain: the token record renders as soon as
  # the database answers, and the pool section says when the chain is slow. A
  # site without a Base deployment has no pool to read. A fresh page starts
  # from nothing; a re-read keeps the last figures until the new ones arrive.
  defp load_pool(socket, reset?) do
    if Lab.configured?(),
      do: read_pool(socket, reset?),
      else: assign(socket, :pool, %Phoenix.LiveView.AsyncResult{})
  end

  defp read_pool(socket, reset?) do
    id = socket.assigns.record_id

    assign_async(
      socket,
      :pool,
      fn ->
        with {:ok, %{page: %{record: %{auction: auction}}}} when is_map(auction) <-
               load_token_page(id),
             {:ok, facts} <- Pool.read(auction) do
          {:ok, %{pool: facts}}
        else
          {:ok, _no_record} -> {:error, :not_graduated}
          {:error, reason} -> {:error, reason}
        end
      end,
      reset: reset?
    )
  end
end
