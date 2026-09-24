defmodule AutolaunchWeb.Live.PageTitle do
  @moduledoc """
  The browser tab title of each product page, so tabs, bookmarks and history
  say which page they hold. The home page keeps the layout's plain "Autolaunch".
  """

  import Phoenix.Component, only: [assign: 3]

  @titles %{
    AutolaunchWeb.CreateLive => "Create a launch",
    AutolaunchWeb.AuctionsLive => "Auctions",
    AutolaunchWeb.AuctionLive => "Auction",
    AutolaunchWeb.RobinhoodAuctionLive => "Robinhood auction",
    AutolaunchWeb.TokensLive => "Tokens",
    AutolaunchWeb.TokenLive => "Token",
    AutolaunchWeb.RobinhoodTokenLive => "Robinhood token",
    AutolaunchWeb.PortfolioLive => "Portfolio",
    AutolaunchWeb.RegentLive => "REGENT",
    AutolaunchWeb.HowItWorksLive => "How Autolaunch works",
    AutolaunchWeb.ConvertLive => "REGENT's share of fees"
  }

  def on_mount(:default, _params, _session, socket),
    do: {:cont, assign(socket, :page_title, Map.fetch!(@titles, socket.view) <> " · Autolaunch")}
end
