defmodule AutolaunchWeb.PortfolioLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers

  alias AutolaunchWeb.LabMarket

  @history ~w(claimed exited returned)

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:refreshed_at, nil)
     |> assign(:status, :ready)
     |> assign(:positions, [])
     |> assign(:returnable_positions, [])
     |> assign(:claimable_positions, [])
     |> assign(:claimed_token_positions, [])
     |> assign(:market, LabMarket.subscribe(socket))
     |> load_signed_in_holdings()}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("refresh", _params, socket) do
    socket = load_signed_in_holdings(socket)

    {:noreply,
     assign(socket, :refreshed_at, if(socket.assigns.status == :ready, do: DateTime.utc_now()))}
  end

  # The lab feeds moved: positions may have become returnable or claimable.
  def handle_info({:autolaunch_market_updated, _update}, socket) do
    market = LabMarket.snapshot()

    if market.generation > socket.assigns.market.generation,
      do: {:noreply, socket |> assign(:market, market) |> load_signed_in_holdings()},
      else: {:noreply, socket}
  end

  # A settlement card verified a step, so the stored position changed.
  def handle_info({:bid_settlement_changed, _position_id}, socket),
    do: {:noreply, load_signed_in_holdings(socket)}

  def render(assigns) do
    {history, current} = Enum.split_with(assigns.positions, &(&1.status in @history))

    assigns =
      assign(assigns,
        history: history,
        current: Enum.sort_by(current, &(&1.status not in ["returnable", "claimable"]))
      )

    ~H"""
    <section id="autolaunch-holdings" class="autolaunch-page autolaunch-compact-detail">
      <header class="autolaunch-heading">
        <p class="autolaunch-kicker">Autolaunch · Portfolio</p>
        <Regent.Structure.section_bar>
          <h1 class="rg-section-bar__label">Your portfolio</h1>
        </Regent.Structure.section_bar>
        <p>Bids and tokens from your verified wallets.</p>
        <Regent.Primitives.button
          :if={@account_control.kind != :sign_in}
          id="portfolio-refresh"
          variant="secondary"
          phx-click="refresh"
        >
          Refresh
        </Regent.Primitives.button>
        <p :if={@refreshed_at} role="status" class="autolaunch-refresh-status">
          Updated {Calendar.strftime(@refreshed_at, "%H:%M:%S UTC")}
        </p>
      </header>

      <section :if={@account_control.kind == :sign_in} class="autolaunch-empty portfolio-sign-in">
        <h2>Connect to your portfolio</h2>
        <p>
          {if Autolaunch.Prelaunch.read_only?(),
            do: "Portfolios and account access will be available after contract deployment.",
            else: "Sign in to see bids and tokens from your verified wallets."}
        </p>
        <Regent.Primitives.button
          type="button"
          class="account-control__sign-in"
          data-account-target="sign-in"
          disabled={Autolaunch.Prelaunch.read_only?()}
        >Sign in</Regent.Primitives.button>
        <.link navigate="/">Keep exploring</.link>
      </section>

      <p
        :if={@account_control.kind != :sign_in && @status == :error}
        class="autolaunch-empty"
        role="alert"
      >
        Your portfolio is unavailable right now.
      </p>

      <div :if={@account_control.kind != :sign_in && @status == :ready}>
        <dl>
          <div>
            <dt>Bid positions</dt><dd>{length(@positions)}</dd>
          </div>
          <div>
            <dt>Returnable</dt><dd>{length(@returnable_positions)}</dd>
          </div>
          <div>
            <dt>Claimable</dt><dd>{length(@claimable_positions)}</dd>
          </div>
          <div>
            <dt>Held launch tokens</dt><dd>{length(@claimed_token_positions)}</dd>
          </div>
        </dl>

        <section id="autolaunch-bid-positions" aria-labelledby="autolaunch-bid-positions-title">
          <Regent.Structure.section_bar>
            <h2 class="rg-section-bar__label" id="autolaunch-bid-positions-title">Bid positions</h2>
          </Regent.Structure.section_bar>
          <p :if={@positions == []} class="autolaunch-empty">
            Bids from your verified wallets will appear here.
            <.link navigate="/auctions">Explore auctions</.link>
          </p>
          <p :if={@positions != [] && @current == []}>No active bids.</p>
          <.position_list
            :if={@current != []}
            positions={@current}
            market={@market}
            account_control={@account_control}
            access_context={@access_context}
            session_lease={@session_lease}
          />
        </section>

        <section
          :if={@claimed_token_positions != []}
          id="autolaunch-held-tokens"
          aria-labelledby="autolaunch-held-tokens-title"
        >
          <Regent.Structure.section_bar>
            <h2 class="rg-section-bar__label" id="autolaunch-held-tokens-title">
              Held launch tokens
            </h2>
          </Regent.Structure.section_bar>
          <ol :if={@claimed_token_positions != []} class="autolaunch-record-list">
            <li :for={position <- @claimed_token_positions}>
              <% presentation = position_token_presentation(position) %>
              <.link navigate={"/tokens/#{position.token.id}"}>
                <strong>{presentation.name} · {presentation.symbol}</strong>
                <span>Claimed from {bid_title(position)}</span>
              </.link>
            </li>
          </ol>
        </section>
        <Regent.Primitives.disclosure
          :if={@history != []}
          id="portfolio-history"
          summary={"Past bids · #{length(@history)}"}
        >
          <.position_list
            positions={@history}
            market={@market}
            account_control={@account_control}
            access_context={@access_context}
            session_lease={@session_lease}
          />
        </Regent.Primitives.disclosure>
      </div>
    </section>
    """
  end

  attr :positions, :list, required: true
  attr :market, :map, required: true
  attr :account_control, :map, required: true
  attr :access_context, :any, required: true
  attr :session_lease, :any, required: true

  # Every card is the settlement component: it shows the position, the exact
  # action its auction admits right now, or the reason nothing can be done yet.
  defp position_list(assigns) do
    ~H"""
    <ol class="autolaunch-record-list">
      <li :for={position <- @positions} id={"autolaunch-bid-#{position.bid_id}"}>
        <.live_component
          module={AutolaunchWeb.BidSettlementComponent}
          id={"autolaunch-settlement-#{position.id}"}
          position={position}
          market={LabMarket.reading(@market, position.auction_address)}
          authenticated={@account_control.kind == :signed_in}
          current_human_id={current_human_id(@access_context)}
          session_lease={@session_lease}
        />
        <.link navigate={"/auctions/#{position.auction_id}"}>View auction</.link>
      </li>
    </ol>
    """
  end

  defp load_signed_in_holdings(socket) do
    case human_actor(socket.assigns.access_context) do
      nil ->
        assign_holdings(socket, :ready)

      actor ->
        case load_holdings(actor) do
          {:ok, holdings} -> assign(socket, holdings)
          {:error, :unavailable} -> assign_holdings(socket, :error)
        end
    end
  end

  defp assign_holdings(socket, status) do
    assign(socket,
      status: status,
      positions: [],
      returnable_positions: [],
      claimable_positions: [],
      claimed_token_positions: []
    )
  end
end
