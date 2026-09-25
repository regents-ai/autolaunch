defmodule AutolaunchWeb.Live.PageTitle do
  @moduledoc """
  The browser tab title of each product page, so tabs, bookmarks and history
  say which page they hold. The home page keeps the layout's plain "Autolaunch".
  """

  import Phoenix.Component, only: [assign: 3]

  @titles %{
    AutolaunchWeb.StocksCreateLive => "Launch memestock",
    AutolaunchWeb.CreateLive => "Agentic Revenue Launch",
    AutolaunchWeb.AuctionsLive => "Auctions",
    AutolaunchWeb.AuctionLive => "Auction",
    AutolaunchWeb.RobinhoodAuctionLive => "Robinhood auction",
    AutolaunchWeb.TokensLive => "Tokens",
    AutolaunchWeb.TokenLive => "Token",
    AutolaunchWeb.RobinhoodTokenLive => "Robinhood token",
    AutolaunchWeb.PortfolioLive => "Portfolio",
    AutolaunchWeb.ProfileLive => "Profile",
    AutolaunchWeb.RegentLive => "REGENT",
    AutolaunchWeb.HowItWorksLive => "How Autolaunch works",
    AutolaunchWeb.ConvertLive => "REGENT's share of fees"
  }

  # An auction's or token's page names its tab once it knows which chain's
  # page it shows; see `AutolaunchWeb.MarketPageLive`.
  def on_mount(:default, _params, _session, %{view: AutolaunchWeb.MarketPageLive} = socket),
    do: {:cont, socket}

  def on_mount(:default, _params, _session, socket),
    do: {:cont, assign_title(socket, socket.view)}

  @doc "Names the tab after the product page `view`."
  def assign_title(socket, view),
    do: assign(socket, :page_title, Map.fetch!(@titles, view) <> " · Autolaunch")
end
