defmodule AutolaunchWeb.RobinhoodAuctionLive do
  @moduledoc """
  One Robinhood Memestake auction, named by its address. The chain is the only
  record of these auctions: the page reads the launch (its token's name,
  description, website and image, its state and what it raised), names its
  creator when a signed-up account's wallet launched it, shows how far it is
  toward its minimum and roughly when bidding ends, hands the signed-in
  wallet the bid step, and once the launch has graduated, points at the
  token's own page, where it trades and stakes.
  """

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers,
    only: [connections_for: 2, creator_connections_for: 1, current_human_id: 1]

  import AutolaunchWeb.Components.MarketCard, only: [detail_card: 1]
  import AutolaunchWeb.Components.RaiseProgress

  alias Autolaunch.Chain.Address
  alias Autolaunch.Robinhood.{Auctions, Lab}

  def mount(_params, _session, socket), do: {:ok, assign(socket, :open?, Lab.configured?())}

  def handle_params(%{"auction" => auction}, _uri, socket) do
    case Address.normalize(auction) do
      {:ok, address} -> {:noreply, socket |> assign(:auction, address) |> load_launch()}
      :error -> {:noreply, assign(socket, auction: nil, launch: %Phoenix.LiveView.AsyncResult{})}
    end
  end

  def handle_event("retry", _params, socket), do: {:noreply, load_launch(socket)}

  def render(assigns) do
    ~H"""
    <article
      :if={@open? && @auction && @launch.ok?}
      id="autolaunch-robinhood-auction"
      class="autolaunch-page"
    >
      <header class="autolaunch-heading">
        <.link navigate="/auctions" class="market-back">← Auctions</.link>
        <Regent.Structure.section_bar>
          <h1 class="rg-section-bar__label">{@launch.result.name} · {@launch.result.symbol}</h1>
        </Regent.Structure.section_bar>
        <p>{network_copy(Lab.test_chain?())}</p>
      </header>
      <div class="market-detail-layout">
        <section class="market-detail-summary" aria-label="Auction information">
          <.detail_card
            kind={:robinhood_auction}
            record={@launch.result}
            creator_connections={@creator_connections.result}
          />
          <.raise_progress
            id="robinhood-raise-progress"
            state={@launch.result.state}
            raised={@launch.result.raised}
            required={@launch.result.required}
            symbol={@launch.result.stock_symbol}
            block={@launch.result.clock}
            start_block={@launch.result.start_block}
            end_block={@launch.result.end_block}
            chain={:robinhood}
            test_chain={Lab.test_chain?()}
          />
          <dl class="autolaunch-live-market" aria-label="Auction facts">
            <div>
              <dt>Minimum to graduate</dt>
              <dd>{@launch.result.required} {@launch.result.stock_symbol}</dd>
            </div>
            <div>
              <dt>Bids are paid in</dt>
              <dd>USDG, converted into {@launch.result.stock_symbol} inside each bid</dd>
            </div>
            <div>
              <dt>{raised_label(@launch.result)}</dt>
              <dd>{@launch.result.raised} {@launch.result.stock_symbol}</dd>
            </div>
            <div>
              <dt>Auction address</dt>
              <dd class="autolaunch-exact-value">{@launch.result.auction}</dd>
            </div>
          </dl>
          <p
            :if={@launch.result.state == :graduated}
            id="robinhood-token-link"
            class="autolaunch-live-market"
          >
            This auction graduated.
            <.link navigate={"/robinhood/tokens/#{@launch.result.token}"}>
              Open {@launch.result.symbol}, its token, to trade and stake it
            </.link>
          </p>
        </section>
        <aside class="market-detail-action" aria-label="Bid on this auction">
          <.live_component
            module={AutolaunchWeb.RobinhoodStockBidComponent}
            id="autolaunch-robinhood-bid"
            auction={@auction}
            ended={ended_copy(@launch.result)}
            authenticated={@account_control.kind == :signed_in}
            current_human_id={current_human_id(@access_context)}
            session_lease={@session_lease}
          />
        </aside>
      </div>
    </article>

    <p :if={@open? && @auction && @launch.loading} class="autolaunch-page" role="status">
      Loading…
    </p>

    <section
      :if={!@open? || !@auction || @launch.failed == {:error, :not_found}}
      id="autolaunch-robinhood-auction"
      class="autolaunch-page autolaunch-empty"
    >
      <Regent.Structure.section_bar>
        <h1 class="rg-section-bar__label">Auction not found</h1>
      </Regent.Structure.section_bar>
      <p :if={!@open?}>Robinhood auctions are not open on this site yet.</p>
      <p :if={@open? && !@auction}>That is not an auction address.</p>
      <p :if={@open? && @auction && @launch.failed}>
        No Robinhood auction exists at {@auction}.
      </p>
      <.link navigate="/auctions">Return to Auctions</.link>
    </section>

    <section
      :if={@open? && @auction && unreadable?(@launch)}
      id="autolaunch-robinhood-auction"
      class="autolaunch-page autolaunch-empty"
      role="alert"
    >
      <Regent.Structure.section_bar>
        <h1 class="rg-section-bar__label">Auction unavailable</h1>
      </Regent.Structure.section_bar>
      <p>This auction could not be read from Robinhood right now.</p>
      <Regent.Primitives.button phx-click="retry" variant="secondary">Retry</Regent.Primitives.button>
      <.link navigate="/auctions">Return to Auctions</.link>
    </section>
    """
  end

  defp load_launch(%{assigns: %{open?: false}} = socket),
    do:
      assign(socket,
        launch: %Phoenix.LiveView.AsyncResult{},
        creator_connections: %Phoenix.LiveView.AsyncResult{}
      )

  defp load_launch(socket) do
    auction = socket.assigns.auction

    assign_async(
      socket,
      [:launch, :creator_connections],
      fn ->
        with {:ok, launch} <- Auctions.fetch(auction) do
          {:ok,
           %{
             launch: launch,
             creator_connections: connections_for(launch, creator_connections_for([launch]))
           }}
        end
      end,
      reset: true
    )
  end

  # A failed auction's contract still holds what was bid until each bid is
  # returned, so that figure is not what the launch keeps.
  defp raised_label(%{state: :failed, stock_symbol: symbol}), do: "#{symbol} bid before refunds"
  defp raised_label(%{stock_symbol: symbol}), do: "#{symbol} raised"

  defp ended_copy(%{state: :graduated, stock_symbol: symbol}),
    do:
      "The auction raised its minimum. Bids at or above the final price receive tokens, and every bid gets back the #{symbol} it did not spend."

  defp ended_copy(%{state: :failed, stock_symbol: symbol}),
    do: "The auction did not raise its minimum. Every bid gets its #{symbol} back in full."

  defp ended_copy(_launch), do: nil

  defp network_copy(true),
    do: "A Memestake auction on the Robinhood test network. Test assets have no real value."

  defp network_copy(false), do: "A Memestake auction on Robinhood Chain."

  defp unreadable?(%{failed: nil}), do: false
  defp unreadable?(%{failed: {:error, :not_found}}), do: false
  defp unreadable?(_failed), do: true
end
