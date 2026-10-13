defmodule AutolaunchWeb.Telemetry.Announcements do
  @moduledoc """
  Counts what the site announces to its open pages, by kind, as
  `[:autolaunch, :pages, :announced]`. Every open page acts on each
  announcement, so the rate at rest says whether pages are being told to
  refresh when nothing they show has changed. It listens on the topics the
  pages listen on and keeps nothing.
  """

  use GenServer

  alias Autolaunch.{LabMarketFeed, Listings, MarketTicker}
  alias Autolaunch.Robinhood.MarketFeed, as: RobinhoodMarketFeed

  @kinds %{
    autolaunch_listings_changed: :listings,
    autolaunch_market_updated: :base_market,
    robinhood_market_updated: :robinhood_market,
    market_ticker: :ticker
  }

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    for topic <- [
          Listings.topic(),
          LabMarketFeed.topic(),
          RobinhoodMarketFeed.topic(),
          MarketTicker.topic()
        ],
        do: Phoenix.PubSub.subscribe(Autolaunch.PubSub, topic)

    {:ok, nil}
  end

  @impl true
  def handle_info({kind, _payload}, state) when is_map_key(@kinds, kind) do
    :telemetry.execute([:autolaunch, :pages, :announced], %{count: 1}, %{kind: @kinds[kind]})
    {:noreply, state}
  end
end
