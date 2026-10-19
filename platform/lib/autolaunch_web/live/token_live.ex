defmodule AutolaunchWeb.TokenLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers
  import AutolaunchWeb.Components.MarketCard, only: [detail_card: 1]
  import AutolaunchWeb.Components.LaunchTrust
  import AutolaunchWeb.Components.PriceChart
  import AutolaunchWeb.Components.TokenHeading
  import AutolaunchWeb.Components.TokenTrade

  alias Autolaunch.Lab
  alias Autolaunch.{Pool, PoolFees, TreasurySecurity}
  alias AutolaunchWeb.Components.{ShareLaunch, TokenTrade}
  alias AutolaunchWeb.{LabMarket, LiveListings, Paths, ShareCard}
  alias AutolaunchWeb.SwapComponent

  def mount(%{"auction_address" => address}, _session, socket),
    do:
      {:ok,
       socket
       |> assign(staked?: false, claimed?: false, balances_read: 0)
       |> LabMarket.subscribe_market(address)
       |> LiveListings.subscribe()}

  # The identifier is read here so a patch to another token reloads the page
  # instead of keeping the previous record on screen. `?trade=stake` opens the
  # widget on Stake.
  def handle_params(%{"token_id" => id} = params, _uri, socket) do
    socket = assign(socket, :trade, TokenTrade.pick(params["trade"], tabs(socket)))
    {:noreply, socket |> assign(:record_id, id) |> load_page()}
  end

  def handle_event("retry", _params, socket), do: {:noreply, load_page(socket)}

  def handle_event("trade", %{"tab" => tab}, socket),
    do: {:noreply, assign(socket, :trade, TokenTrade.pick(tab, tabs(socket)))}

  def handle_event("reload_pool", _params, socket), do: {:noreply, load_pool(socket, false)}

  def handle_event("refresh_balances", _params, socket), do: {:noreply, balances_read(socket)}

  # The staking part read the wallet's stake: Unstake is offered only while
  # there is one.
  def handle_info({:staked, staked?}, socket) do
    socket = assign(socket, :staked?, staked?)

    if socket.assigns.trade in tabs(socket),
      do: {:noreply, socket},
      else: {:noreply, assign(socket, :trade, :stake)}
  end

  # A swap or a conversion landed and moved the pool's figures, so the
  # pool is read again. The previous figures stay on the page while the fork
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

  # The market feed read a new figure for this token's auction: a trade moved
  # its pool, so the price and the pool are read again.
  def handle_info({:shared_reading, {:auction_market, _address}}, socket),
    do: {:noreply, refresh(socket)}

  # This token's auction saved a change, so the page reads it again in place.
  def handle_info({:autolaunch_listings_changed, auction_id}, socket) do
    if auction_id == page_auction_id(socket.assigns.page),
      do: {:noreply, LiveListings.schedule(socket)},
      else: {:noreply, socket}
  end

  def handle_info(:reread_listings, socket),
    do: {:noreply, socket |> LiveListings.taken() |> refresh()}

  def render(assigns) do
    page_record = page_record(assigns.page)

    assigns =
      assign(assigns,
        page_record: page_record,
        presentation: page_record && Autolaunch.Token.presentation(page_record),
        page_status: page_status(assigns.page, :error),
        creator_connections: page_connections(assigns.page)
      )

    page(assigns)
  end

  # The token's card with its price, the trade widget with Claim Rewards
  # beneath it, and the token's details. Everything else about the token
  # is copied for an agent from beside Claim Rewards.
  defp page(assigns) do
    ~H"""
    <article
      :if={@page_status == :ready && @page_record}
      id="autolaunch-token-detail"
      class="autolaunch-page token-page"
    >
      <header class="autolaunch-heading">
        <.link navigate="/tokens" class="market-back">← Tokens</.link>
        <.token_heading
          name={@presentation.name}
          symbol={@presentation.symbol}
          currency={SwapComponent.entry_symbol(@page_record.auction)}
          chain_id={@page_record.auction.chain_id}
          address={@page_record.auction.token_address}
          pool={if(@pool.ok?, do: @pool.result)}
        />
        <ShareLaunch.share_launch
          id="share-launch"
          auction={@page_record.auction}
          account_control={@account_control}
        />
      </header>
      <div class="token-page__layout">
        <div class="token-page__overview">
          <.detail_card kind={:token} record={@page_record}>
            <:chart :if={@pool.ok? || @pool.loading}>
              <.price_chart_reading :if={!@pool.ok?} />
              <.price_chart
                :if={@pool.ok?}
                id="token-price-chart"
                label="Price since the pool opened"
                history={@pool.result.prices}
                unit={@pool.result.currency.symbol}
                color={@presentation.image_color}
              />
            </:chart>
          </.detail_card>
        </div>
        <.buttons_stage id="token-side" class="token-page__side">
          <.trade_widget id="trade" tab={@trade} swap staked={@staked?}>
            <:pane tab={:swap}>
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
                balances_read={@balances_read}
              />
            </:pane>
            <:pane tab={:stake}>
              <.live_component
                :if={@pool.ok?}
                module={AutolaunchWeb.StakeComponent}
                id={"token-stake-#{@page_record.id}"}
                part={:stake}
                fee_asset={if @claimed?, do: @pool.result.currency.symbol}
                mode={if @trade == :unstake, do: :unstake, else: :stake}
                launch={%{chain: :base, auction: @page_record.auction}}
                pool={@pool.result}
                share_url={Paths.token_url(@page_record.auction)}
                share_image={ShareCard.token_image_url(@page_record.auction, DateTime.utc_now())}
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
            id={"token-claim-#{@page_record.id}"}
            part={:claim}
            launch={%{chain: :base, auction: @page_record.auction}}
            pool={@pool.result}
            details={details(assigns)}
            authenticated={@account_control.kind == :signed_in}
            current_human_id={current_human_id(@access_context)}
            session_lease={@session_lease}
            balances_read={@balances_read}
          />
          <.live_component
            :if={
              @pool.ok? && @pool.result.kind == :agent && !Lab.test_chain?() &&
                !Autolaunch.Prelaunch.read_only?()
            }
            module={AutolaunchWeb.SubjectWalletComponent}
            id={"token-payment-#{@page_record.id}"}
            subject_id={Autolaunch.LabProjection.subject_identity(@pool.result.token.address)}
            symbol={@presentation.symbol}
            authenticated={@account_control.kind == :signed_in}
            current_human_id={current_human_id(@access_context)}
            session_lease={@session_lease}
            client_key={@client_key}
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
        </.buttons_stage>
        <div class="token-page__details">
          <.token_facts
            auction={@page_record.auction}
            connections={@creator_connections}
            pool={if(@pool.ok?, do: @pool.result)}
            price={@page_record.price_quote}
            unit={SwapComponent.entry_symbol(@page_record.auction)}
          />
        </div>
      </div>
    </article>
    <.states page_status={@page_status} />
    """
  end

  defp tabs(socket), do: TokenTrade.tabs(true, socket.assigns.staked?)

  # What Copy Full Token Details to Agent copies, as the page has read it
  # (`AutolaunchWeb.TokenDetails`).
  defp details(assigns) do
    record = assigns.page_record

    %{
      name: assigns.presentation.name,
      symbol: assigns.presentation.symbol,
      url: Paths.token_url(record.auction),
      auction: record.auction,
      pool: assigns.pool.result,
      fees: assigns.fee_totals.result,
      supply: record.auction.token_supply,
      price: record.price_quote,
      treasury: treasury(record)
    }
  end

  defp treasury(%{auction: %{kind: :agent}} = record) do
    if Lab.test_chain?(), do: :unverified, else: TreasurySecurity.public_view(report(record))
  end

  defp treasury(_record), do: nil

  attr :page_status, :atom, required: true

  defp states(assigns) do
    ~H"""
    <div :if={@page_status == :loading} class="token-page__reading">
      <AutolaunchWeb.Components.Loading.placeholder label="Reading the token" />
    </div>

    <section
      :if={@page_status == :empty}
      id="autolaunch-token-detail"
      class="autolaunch-page autolaunch-empty"
    >
      <Regent.Structure.section_bar>
        <h1 class="rg-section-bar__label">Token not found</h1>
      </Regent.Structure.section_bar>
      <p>This token is no longer listed.</p>
      <.link navigate="/tokens" class="rg-button rg-button--primary">
        <span class="rg-button__label">Return to Tokens</span>
      </.link>
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

  # Refresh balances: the pool is read again at the latest block, and the swap
  # and staking parts read the wallet's balances, stake and rewards again,
  # once now and again when the new pool arrives.
  defp balances_read(socket),
    do: socket |> update(:balances_read, &(&1 + 1)) |> load_pool(false)

  # The pool is its own read of the chain: the token record renders as soon as
  # the database answers, and the trade widget says when the chain is slow.
  # The fees it has charged arrive with it. A site without a Base deployment
  # has no pool to read. A fresh page starts
  # from nothing; a re-read keeps the last figures until the new ones arrive.
  defp load_pool(socket, reset?) do
    if Lab.configured?(),
      do: read_pool(socket, reset?),
      else:
        assign(socket,
          pool: %Phoenix.LiveView.AsyncResult{},
          fee_totals: %Phoenix.LiveView.AsyncResult{}
        )
  end

  defp read_pool(socket, reset?) do
    id = socket.assigns.record_id

    assign_async(
      socket,
      [:pool, :fee_totals],
      fn ->
        with {:ok, %{page: %{record: %{auction: auction} = token}}} when is_map(auction) <-
               load_token_page(id),
             {:ok, facts} <- Pool.read(auction) do
          {:ok, %{pool: facts, fee_totals: PoolFees.totals(facts, token)}}
        else
          {:ok, _no_record} -> {:error, :not_graduated}
          {:error, reason} -> {:error, reason}
        end
      end,
      reset: reset?
    )
  end
end
