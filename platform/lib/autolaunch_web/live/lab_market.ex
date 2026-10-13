defmodule AutolaunchWeb.LabMarket do
  @moduledoc """
  What a page takes from the market feeds' shared readings
  (`Autolaunch.MarketReadings`). A page subscribes to the keys of what it
  shows, reads them once, and reads a key again on its
  `{:shared_reading, key}`; it is told of a key only when that reading changed.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Autolaunch.{MarketReadings, SharedReading}

  @feeds ["base", "stocks", "robinhood"]

  @doc """
  Assigns `robinhood_stale?`, whether the Robinhood feed could not read its
  chain, and has the connected page told when that changes
  (`{:shared_reading, {:market_feed, "robinhood"}}`).
  """
  def assign_robinhood_stale(socket) do
    if Phoenix.LiveView.connected?(socket),
      do: SharedReading.subscribe(MarketReadings.feed_key("robinhood"))

    robinhood_stale(socket)
  end

  @doc "Reads `robinhood_stale?` again."
  def robinhood_stale(socket),
    do: assign(socket, :robinhood_stale?, MarketReadings.stale?("robinhood"))

  @doc """
  Has the connected page told whenever a feed stores readings at a new block
  (`{:shared_reading, {:market_head, feed}}`): for a page of one person's own
  bids and holdings across auctions, which reads them again then.
  """
  def subscribe_heads(socket) do
    if Phoenix.LiveView.connected?(socket),
      do: Enum.each(@feeds, &SharedReading.subscribe(MarketReadings.head_key(&1)))

    socket
  end

  @doc """
  Has the connected page told when the figures of the auction at `address`
  change (`{:shared_reading, {:auction_market, address}}`). An auction with no
  contract yet has none.
  """
  def subscribe_market(socket, address) do
    if is_binary(address) and Phoenix.LiveView.connected?(socket),
      do: SharedReading.subscribe(MarketReadings.market_key(address))

    socket
  end

  @doc """
  Has the connected page of the auction at `address` told when what it shows
  from the chain changes: the auction's figures, its own page's reading
  (`{:shared_reading, {:auction_page, address}}`) and each new block of
  `feed` (`{:shared_reading, {:market_head, feed}}`).
  """
  def subscribe_auction(socket, address, feed) do
    if is_binary(address) and Phoenix.LiveView.connected?(socket) do
      SharedReading.subscribe(MarketReadings.page_key(address))
      SharedReading.subscribe(MarketReadings.head_key(feed))
    end

    subscribe_market(socket, address)
  end
end
