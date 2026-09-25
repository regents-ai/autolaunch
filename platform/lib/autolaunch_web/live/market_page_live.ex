defmodule AutolaunchWeb.MarketPageLive do
  @moduledoc """
  An auction's page at `/auctions/<TICKER>/<tail>` or its token's at
  `/tokens/<TICKER>/<tail>` (see `AutolaunchWeb.Paths`), on either chain.

  Base and Robinhood keep their own pages. This finds the one listed auction
  the address names, picks its chain's page, hands that page the record it
  reads by, and passes every later callback straight to it. An address that
  names nothing, or an auction whose token has not launched, is the site's
  404.
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
    TokenLive
  }

  def mount(%{"symbol" => symbol, "tail" => tail}, session, socket) do
    {page, page_params} = page!(socket.assigns.live_action, auction!(symbol, tail))

    socket
    |> assign(market_page: page, market_page_params: page_params)
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

  defp auction!(symbol, tail) do
    case Paths.find_auction(symbol, tail) do
      {:ok, auction} -> auction
      :error -> raise NotFoundError
    end
  end

  # Each chain's page and the parameter it reads its record by.
  defp page!(:auction, auction) do
    if RobinhoodLab.chain?(auction.chain_id),
      do: {RobinhoodAuctionLive, %{"auction" => auction.auction_address}},
      else: {AuctionLive, %{"auction_id" => auction.id}}
  end

  defp page!(:token, auction) do
    if RobinhoodLab.chain?(auction.chain_id),
      do:
        {RobinhoodTokenLive,
         %{"token" => launched!(robinhood_token(auction)).auction.token_address}},
      else: {TokenLive, %{"token_id" => launched!(base_token(auction)).id}}
  end

  defp base_token(auction), do: Autolaunch.get_public_token_by_auction(auction.id, actor: nil)

  defp robinhood_token(%{token_address: address}) when is_binary(address),
    do: Autolaunch.get_robinhood_token(address, actor: nil)

  defp robinhood_token(_auction), do: {:ok, nil}

  defp launched!({:ok, %Autolaunch.Token{} = token}), do: token
  defp launched!(_not_launched), do: raise(NotFoundError)
end
