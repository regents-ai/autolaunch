defmodule AutolaunchWeb.PortfolioLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:refreshed_at, nil)
     |> assign(:status, :ready)
     |> assign(:positions, [])
     |> assign(:returnable_positions, [])
     |> assign(:claimed_token_positions, [])
     |> load_signed_in_holdings()}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("refresh", _params, socket) do
    socket = load_signed_in_holdings(socket)

    {:noreply,
     assign(socket, :refreshed_at, if(socket.assigns.status == :ready, do: DateTime.utc_now()))}
  end

  def render(assigns) do
    {history, current} =
      Enum.split_with(assigns.positions, &(&1.status in ["claimed", "exited", "returned"]))

    assigns =
      assign(assigns,
        history: history,
        current: Enum.sort_by(current, &(&1.status != "returnable"))
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
          <.position_list :if={@current != []} positions={@current} />
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
          <.position_list positions={@history} />
        </Regent.Primitives.disclosure>
      </div>
    </section>
    """
  end

  attr :positions, :list, required: true

  defp position_list(assigns) do
    ~H"""
    <ol class="autolaunch-record-list">
      <li :for={position <- @positions} id={"autolaunch-bid-#{position.bid_id}"}>
        <article>
          <p class="autolaunch-kicker">
            {display_status(position.status)}
          </p>
          <h3>{bid_title(position)}</h3>
          <dl>
            <div>
              <dt>Bid amount</dt><dd>{display_text(position.amount)}</dd>
            </div>
            <div>
              <dt>Maximum price</dt><dd>{display_text(position.max_price)}</dd>
            </div>
            <div>
              <dt>Current price</dt>
              <dd>{display_text(position.current_clearing_price)}</dd>
            </div>
            <div>
              <dt>Estimated tokens</dt>
              <dd>{display_text(position.estimated_tokens_if_end_now)}</dd>
            </div>
            <div>
              <dt>Wallet</dt><dd>{position.owner_address}</dd>
            </div>
            <div>
              <dt>Updated</dt><dd>{display_time(position.updated_at)}</dd>
            </div>
          </dl>

          <.link navigate={"/auctions/#{position.auction_id}"}>
            {if position.status == "returnable", do: "View return options", else: "View auction"}
          </.link>
        </article>
      </li>
    </ol>
    """
  end

  defp load_signed_in_holdings(socket) do
    case human_actor(socket.assigns.access_context) do
      nil ->
        assign(socket,
          status: :ready,
          positions: [],
          returnable_positions: [],
          claimed_token_positions: []
        )

      actor ->
        case load_holdings(actor) do
          {:ok, holdings} -> assign(socket, holdings)
          {:error, :unavailable} -> assign_holdings_error(socket)
        end
    end
  end

  defp assign_holdings_error(socket) do
    assign(socket,
      status: :error,
      positions: [],
      returnable_positions: [],
      claimed_token_positions: []
    )
  end
end
