defmodule AutolaunchWeb.LabMarket do
  @moduledoc """
  What a page takes from the chain readings every visitor sees alike: each
  auction's reading (`Autolaunch.AuctionReading`), which its own public
  publication carries to open pages, and each deployment's newest block
  (`Autolaunch.ChainHead`), held in `Autolaunch.SharedReading`.

  A page subscribes to what it shows, then reads it once as a signed-out
  visitor. An auction's reading arrives as `%{topic: topic, payload: payload}` on its
  `public:` topic and the page keeps it only when it is newer (`newer/2`); a
  block arrives as `{:shared_reading, {:chain_head, feed}}` and the page reads
  `Autolaunch.ChainHead.fetch/1` again.
  """

  import Phoenix.Component, only: [assign: 3]
  import AutolaunchWeb.Components.AutolaunchHelpers, only: [signed_in_wallet: 1]

  alias Autolaunch.{AuctionReading, ChainHead, SharedReading}

  @feeds ["base", "stocks", "robinhood"]

  @doc "The deployment a Base auction of `kind` keeps time by."
  @spec feed(:agent | :stocks) :: String.t()
  def feed(:agent), do: "base"
  def feed(:stocks), do: "stocks"

  @doc """
  Assigns `robinhood_stale?`, whether the site could not read the Robinhood
  chain, and has the connected page told when that may have changed
  (`{:shared_reading, {:chain_head, "robinhood"}}`).
  """
  def assign_robinhood_stale(socket) do
    if Phoenix.LiveView.connected?(socket),
      do: SharedReading.subscribe(ChainHead.key("robinhood"))

    robinhood_stale(socket)
  end

  @doc "Reads `robinhood_stale?` again."
  def robinhood_stale(socket),
    do: assign(socket, :robinhood_stale?, ChainHead.stale?("robinhood"))

  @doc """
  Has the connected page told of each new block of every deployment
  (`{:shared_reading, {:chain_head, feed}}`): for a page of one person's own
  bids and holdings across auctions, which reads them again then.
  """
  def subscribe_heads(socket) do
    if Phoenix.LiveView.connected?(socket),
      do: Enum.each(@feeds, &SharedReading.subscribe(ChainHead.key(&1)))

    socket
  end

  @doc """
  Has the connected page of the signed-in wallet's own bids told when one of
  them is written (`{:autolaunch_bid_changed, bid_id}`, `Autolaunch.WalletBids`):
  an auction's reading job writes them with its row, apart from the block.
  """
  def subscribe_wallet_bids(socket) do
    wallet = signed_in_wallet(socket.assigns.access_context)
    if wallet && Phoenix.LiveView.connected?(socket), do: Autolaunch.WalletBids.subscribe(wallet)

    socket
  end

  @doc """
  Has the connected page told when the figures of auction `auction_id` are
  read again (`%{topic: topic, payload: payload}` on `AuctionReading.market_topic/1`).
  """
  def subscribe_market(socket, auction_id) do
    if Phoenix.LiveView.connected?(socket),
      do: Phoenix.PubSub.subscribe(Autolaunch.PubSub, AuctionReading.market_topic(auction_id))

    socket
  end

  @doc """
  Has the connected page of auction `auction_id` told when what it shows from
  the chain changes: the auction's figures, its own page's reading (on
  `AuctionReading.page_topic/1`) and each new block of `feed`.
  """
  def subscribe_auction(socket, auction_id, feed) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(Autolaunch.PubSub, AuctionReading.page_topic(auction_id))
      SharedReading.subscribe(ChainHead.key(feed))
    end

    subscribe_market(socket, auction_id)
  end

  @doc """
  Auction `auction_id`'s reading as a signed-out visitor reads it, in the
  shapes its publications carry: `{market, page}`, each nil while it has none.
  """
  @spec reading(Ash.UUID.t()) :: {map() | nil, map() | nil}
  def reading(auction_id) do
    case Autolaunch.get_auction_reading(auction_id, actor: nil) do
      {:ok, %AuctionReading{} = reading} ->
        {AuctionReading.market(reading), if(reading.page, do: AuctionReading.page(reading))}

      {:ok, nil} ->
        {nil, nil}
    end
  end

  @doc "The newer of a held payload and one just published: the one with the higher version."
  def newer(%{version: held} = payload, %{version: version}) when version <= held, do: payload
  def newer(_held, payload), do: payload
end
