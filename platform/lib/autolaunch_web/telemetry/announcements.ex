defmodule AutolaunchWeb.Telemetry.Announcements do
  @moduledoc """
  Counts what the site announces to its open pages, by kind, as
  `[:autolaunch, :pages, :announced]`. Every open page acts on each
  announcement, so the rate at rest says whether pages are being told to
  refresh when nothing they show has changed. It listens on the topics the
  pages listen on and keeps nothing. Auction readings are not announced: a
  page hears its own auction's reading on that reading's topic, only when it
  changed (`Autolaunch.AuctionReading`).
  """

  use GenServer

  alias Autolaunch.{Listings, MarketTicker}

  @kinds %{autolaunch_listings_changed: :listings, market_ticker: :ticker}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    for topic <- [Listings.topic(), MarketTicker.topic()],
        do: Phoenix.PubSub.subscribe(Autolaunch.PubSub, topic)

    {:ok, nil}
  end

  @impl true
  def handle_info({kind, _payload}, state) when is_map_key(@kinds, kind) do
    :telemetry.execute([:autolaunch, :pages, :announced], %{count: 1}, %{kind: @kinds[kind]})
    {:noreply, state}
  end

  # A message shape these topics gain later is not counted, and never stops
  # the counter.
  def handle_info(_other, state), do: {:noreply, state}
end
