defmodule AutolaunchWeb.PortfolioLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:status, :ready)
     |> assign(:positions, [])
     |> assign(:returnable_positions, [])
     |> assign(:claimed_token_positions, [])
     |> load_signed_in_holdings()}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("refresh", _params, socket), do: {:noreply, load_signed_in_holdings(socket)}

  def render(assigns) do
    ~H"""
    <div id="account-control" data-account-kind={@account_control.kind}>
      <button phx-click="refresh">Refresh</button>
    </div>

    <section id="autolaunch-holdings" class="autolaunch-page">
      <header class="autolaunch-heading">
        <p class="autolaunch-kicker">Autolaunch · Portfolio</p>
        <h1>Your portfolio</h1>
        <p>Review bid positions and launch tokens connected to your verified wallets.</p>
      </header>

      <p :if={@account_control.kind == :sign_in} class="autolaunch-empty">
        Sign in to view your portfolio.
      </p>

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
          <h2 id="autolaunch-bid-positions-title">Bid positions</h2>
          <p :if={@positions == []} class="autolaunch-empty">
            Bids from your verified wallets will appear here.
          </p>
          <ol :if={@positions != []} class="autolaunch-record-list">
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
                <p :if={position.status == "returnable"}>
                  This position can be returned. No return is started from this page.
                </p>
                <.link navigate={"/auctions/#{position.auction_id}"}>
                  View auction
                </.link>
              </article>
            </li>
          </ol>
        </section>

        <section
          id="autolaunch-returnable-positions"
          aria-labelledby="autolaunch-returnable-positions-title"
        >
          <h2 id="autolaunch-returnable-positions-title">Ready to return</h2>
          <p :if={@returnable_positions == []} class="autolaunch-empty">
            No positions are returnable.
          </p>
          <ul :if={@returnable_positions != []}>
            <li :for={position <- @returnable_positions}>
              {bid_title(position)} · {display_text(position.amount)}
            </li>
          </ul>
          <p :if={@returnable_positions != []}>
            Returns are display-only here. This page never opens a wallet or starts a transaction.
          </p>
        </section>

        <section id="autolaunch-held-tokens" aria-labelledby="autolaunch-held-tokens-title">
          <h2 id="autolaunch-held-tokens-title">Held launch tokens</h2>
          <p :if={@claimed_token_positions == []} class="autolaunch-empty">
            Claimed launch tokens will appear here.
          </p>
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
      </div>
    </section>
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
