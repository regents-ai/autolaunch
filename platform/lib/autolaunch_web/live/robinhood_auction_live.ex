defmodule AutolaunchWeb.RobinhoodAuctionLive do
  @moduledoc """
  One Robinhood Memestake auction, named by its address. The page shows the
  auction as the Robinhood market feed stored it (its token's name,
  description, website and image, its state and minimum) with the feed's
  latest reading of what it raised and the chain's clock. It names its
  creator when a signed-up account's wallet launched it, shows how far it is
  toward its minimum and roughly when bidding ends, hands the signed-in
  wallet the bid step, and once the launch has graduated, points at the
  token's own page, where it trades and stakes. When Robinhood cannot be
  read, the page says so and shows what was last read.
  """

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers,
    only: [connections_for: 2, creator_connections_for: 1, current_human_id: 1]

  import AutolaunchWeb.Components.MarketCard, only: [detail_card: 1]
  import AutolaunchWeb.Components.AuctionBook
  import AutolaunchWeb.Components.RaiseProgress

  alias Autolaunch.AuctionBook
  alias Autolaunch.Chain.{Address, Rpc}
  alias Autolaunch.Robinhood.Lab
  alias Autolaunch.Stocks.MarketData
  alias AutolaunchWeb.{LabMarket, UsdValue}

  def mount(_params, _session, socket),
    do:
      {:ok,
       socket
       |> assign(open?: Lab.configured?(), market: LabMarket.subscribe(socket))
       |> assign_usd_prices()}

  def handle_params(%{"auction" => auction}, _uri, socket) do
    case Address.normalize(auction) do
      {:ok, address} -> {:noreply, socket |> assign(:auction, address) |> load_launch()}
      :error -> {:noreply, assign(socket, auction: nil, launch: nil)}
    end
  end

  # The feed read Robinhood again: the stored auction and its reading move
  # together.
  def handle_info({:robinhood_market_updated, _update}, socket),
    do: {:noreply, socket |> assign(:market, LabMarket.snapshot()) |> reload_launch()}

  def handle_info({:autolaunch_market_updated, _update}, socket),
    do: {:noreply, assign(socket, :market, LabMarket.snapshot())}

  def render(assigns) do
    assigns =
      assign(assigns,
        usd_rate: usd_rate(assigns.usd_prices, assigns.launch),
        reading: assigns.launch && LabMarket.reading(assigns.market, assigns.auction)
      )

    ~H"""
    <article :if={@open? && @launch} id="autolaunch-robinhood-auction" class="autolaunch-page">
      <header class="autolaunch-heading">
        <.link navigate="/auctions" class="market-back">← Auctions</.link>
        <Regent.Structure.section_bar>
          <h1 class="rg-section-bar__label">{@launch.title} · {@launch.token_symbol}</h1>
        </Regent.Structure.section_bar>
        <p>{network_copy(Lab.test_chain?())}</p>
      </header>
      <p :if={@market.robinhood_stale?} class="autolaunch-live-market" role="status">
        Robinhood could not be read just now, so this auction shows what was last read.
      </p>
      <div class="market-detail-layout">
        <.detail_card
          kind={:auction}
          record={@launch}
          creator_connections={@creator_connections.result}
        >
          <:price_note>
            <UsdValue.usd
              amount={@launch.current_clearing_price}
              rate={@usd_rate}
              per="per token"
            />
          </:price_note>
        </.detail_card>
        <aside class="market-detail-action" aria-label="Bid on this auction">
          <.live_component
            module={AutolaunchWeb.RobinhoodStockBidComponent}
            id="autolaunch-robinhood-bid"
            auction={@auction}
            ended={ended_copy(@launch)}
            token_symbol={@launch.token_symbol}
            stake_path={
              if @launch.state == :graduated, do: "/robinhood/tokens/#{@launch.token_address}#stake"
            }
            book={(@book.ok? && @book.result) || nil}
            authenticated={@account_control.kind == :signed_in}
            current_human_id={current_human_id(@access_context)}
            session_lease={@session_lease}
          />
        </aside>
        <section class="market-detail-summary" aria-label="Auction information">
          <.auction_book
            :if={@launch.state == :active && @book.ok?}
            id="robinhood-auction-book"
            book={@book.result}
            symbol={@launch.quote_token_symbol}
            usd_rate={@usd_rate}
            color={@launch.image_color}
            bid_form="autolaunch-robinhood-bid"
          />
          <.raise_progress
            :if={@reading}
            id="robinhood-raise-progress"
            state={@launch.state}
            raised={@reading.currency_raised}
            required={required(@launch)}
            symbol={@launch.quote_token_symbol}
            usd_rate={@usd_rate}
            block={@reading.clock}
            start_block={@launch.start_block}
            end_block={@launch.end_block}
            chain={:robinhood}
            test_chain={Lab.test_chain?()}
            bids={@launch.bid_volume && Decimal.to_string(@launch.bid_volume, :normal)}
          />
          <dl class="autolaunch-live-market" aria-label="Auction facts">
            <div>
              <dt>Minimum to graduate</dt>
              <dd>
                {required(@launch)} {@launch.quote_token_symbol}
                <UsdValue.usd amount={required(@launch)} rate={@usd_rate} />
              </dd>
            </div>
            <div>
              <dt>Bids are paid in</dt>
              <dd>USDG, converted into {@launch.quote_token_symbol} inside each bid</dd>
            </div>
            <div :if={@reading}>
              <dt>{raised_label(@launch)}</dt>
              <dd>
                {@reading.currency_raised} {@launch.quote_token_symbol}
                <UsdValue.usd amount={@reading.currency_raised} rate={@usd_rate} />
              </dd>
            </div>
            <div>
              <dt>Auction address</dt>
              <dd class="autolaunch-exact-value">{@launch.auction_address}</dd>
            </div>
          </dl>
          <p
            :if={@launch.state == :graduated}
            id="robinhood-token-link"
            class="autolaunch-live-market"
          >
            This auction graduated.
            <.link navigate={"/robinhood/tokens/#{@launch.token_address}"}>
              Open {@launch.token_symbol}, its token, to trade and stake it
            </.link>
          </p>
        </section>
      </div>
    </article>

    <section
      :if={!@open? || !@launch}
      id="autolaunch-robinhood-auction"
      class="autolaunch-page autolaunch-empty"
    >
      <Regent.Structure.section_bar>
        <h1 class="rg-section-bar__label">Auction not found</h1>
      </Regent.Structure.section_bar>
      <p :if={!@open?}>Robinhood auctions are not open on this site yet.</p>
      <p :if={@open? && !@auction}>That is not an auction address.</p>
      <p :if={@open? && @auction}>No Robinhood auction exists at {@auction}.</p>
      <.link navigate="/auctions">Return to Auctions</.link>
    </section>
    """
  end

  defp load_launch(%{assigns: %{open?: false}} = socket),
    do: assign(socket, launch: nil)

  defp load_launch(socket) do
    socket = reload_launch(socket)
    launch = socket.assigns.launch
    auction = socket.assigns.auction

    socket
    |> assign_async(
      :creator_connections,
      fn ->
        {:ok,
         %{
           creator_connections:
             launch && connections_for(launch, creator_connections_for([launch]))
         }}
      end,
      reset: true
    )
    |> assign_async(
      :book,
      fn -> with {:ok, book} <- AuctionBook.robinhood(auction), do: {:ok, %{book: book}} end,
      reset: true
    )
  end

  defp reload_launch(%{assigns: %{open?: false}} = socket), do: socket

  # Not an address: there is no auction to read again.
  defp reload_launch(%{assigns: %{auction: nil}} = socket), do: socket

  defp reload_launch(socket) do
    {:ok, launch} = Autolaunch.get_robinhood_auction(socket.assigns.auction, actor: nil)
    assign(socket, :launch, launch)
  end

  # The minimum is stored in the stock's smallest unit.
  defp required(launch),
    do:
      launch.required_currency_raised
      |> String.to_integer()
      |> Rpc.format_units(launch.quote_token_decimals)

  # Robinhood's stock prices, read beside the launch so a slow price never
  # holds the auction back.
  defp assign_usd_prices(socket),
    do:
      UsdValue.assign_rate(socket, :usd_prices, :robinhood, fn ->
        {:ok, %{usd_prices: MarketData.prices(:robinhood)}}
      end)

  defp usd_rate(%{result: prices}, %{quote_token_symbol: symbol}),
    do: UsdValue.stock_rate(prices, symbol)

  defp usd_rate(_prices, _launch), do: nil

  # A failed auction's contract still holds what was bid until each bid is
  # returned, so that figure is not what the launch keeps.
  defp raised_label(%{state: :failed, quote_token_symbol: symbol}),
    do: "#{symbol} bid before refunds"

  defp raised_label(%{quote_token_symbol: symbol}), do: "#{symbol} raised"

  defp ended_copy(%{state: :graduated, quote_token_symbol: symbol}),
    do:
      "The auction raised its minimum. Bids at or above the final price receive tokens, and every bid gets back the #{symbol} it did not spend."

  defp ended_copy(%{state: :failed, quote_token_symbol: symbol}),
    do: "The auction did not raise its minimum. Every bid gets its #{symbol} back in full."

  defp ended_copy(%{state: :ended, minimum_reached: true, quote_token_symbol: symbol}),
    do:
      "Bidding has ended and the auction raised its minimum. Its trading pool opens once the auction is finished. Bids at or above the final price receive tokens, and every bid gets back the #{symbol} it did not spend."

  defp ended_copy(%{state: :ended, quote_token_symbol: symbol}),
    do:
      "Bidding has ended. If the final count stays below the minimum, every bid gets its #{symbol} back in full; if it reached the minimum, the trading pool opens once the auction is finished."

  defp ended_copy(_launch), do: nil

  defp network_copy(true),
    do: "A Memestake auction on the Robinhood test network. Test assets have no real value."

  defp network_copy(false), do: "A Memestake auction on Robinhood Chain."
end
