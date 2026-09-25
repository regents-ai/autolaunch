defmodule AutolaunchWeb.MarketPageLive do
  @moduledoc """
  An auction's page at `/auctions/<TICKER>/<tail>` or its token's at
  `/tokens/<TICKER>/<tail>` (see `AutolaunchWeb.Paths`), on either chain.

  Base and Robinhood keep their own pages. This finds the one listed auction
  the address names, picks its chain's page, hands that page the record it
  reads by, and passes every later callback straight to it. It also gives the
  first render, the one link previews read, the page's share details
  (`AutolaunchWeb.ShareCard`). An address that names nothing, or an auction
  whose token has not launched, is the site's 404.
  """
  use AutolaunchWeb, :live_view

  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias AutolaunchWeb.Live.PageTitle

  alias AutolaunchWeb.{
    AuctionLive,
    NotFoundError,
    Paths,
    RobinhoodAuctionLive,
    RobinhoodTokenLive,
    ShareCard,
    TokenLive
  }

  def mount(%{"symbol" => symbol, "tail" => tail}, session, socket) do
    {page, page_params, share} = page!(socket.assigns.live_action, symbol, tail)

    socket
    |> assign(market_page: page, market_page_params: page_params)
    |> assign(:share, if(connected?(socket), do: nil, else: share))
    |> PageTitle.assign_title(page)
    |> then(&page.mount(page_params, session, &1))
  end

  def handle_params(params, uri, socket) do
    %{market_page: page, market_page_params: page_params} = socket.assigns
    page.handle_params(Map.merge(params, page_params), uri, socket)
  end

  def handle_event(event, params, socket),
    do: socket.assigns.market_page.handle_event(event, params, socket)

  def handle_info(message, socket), do: socket.assigns.market_page.handle_info(message, socket)

  def render(assigns), do: assigns.market_page.render(assigns)

  # Each chain's page, the parameter it reads its record by, and the page's
  # share details.
  defp page!(:auction, symbol, tail) do
    case Paths.find_auction(symbol, tail) do
      {:ok, auction} -> auction_page(auction)
      :error -> raise NotFoundError
    end
  end

  defp page!(:token, symbol, tail) do
    case Paths.find_token(symbol, tail) do
      {:ok, auction, token} -> token_page(auction, token)
      :error -> raise NotFoundError
    end
  end

  defp auction_page(auction) do
    if RobinhoodLab.chain?(auction.chain_id),
      do:
        {RobinhoodAuctionLive, %{"auction" => auction.auction_address}, ShareCard.meta(auction)},
      else: {AuctionLive, %{"auction_id" => auction.id}, ShareCard.meta(auction)}
  end

  defp token_page(auction, token) do
    if RobinhoodLab.chain?(auction.chain_id),
      do:
        {RobinhoodTokenLive, %{"token" => auction.token_address}, ShareCard.token_meta(auction)},
      else: {TokenLive, %{"token_id" => token.id}, ShareCard.token_meta(auction)}
  end
end
