defmodule AutolaunchWeb.LabMarket do
  @moduledoc false

  alias Autolaunch.LabMarketFeed
  alias Autolaunch.Robinhood.MarketFeed, as: RobinhoodMarketFeed
  alias Autolaunch.Stocks.LabMarketFeed, as: StocksMarketFeed

  @empty %{generation: 0, head: nil, degraded?: false, robinhood_stale?: false, auctions: %{}}

  @doc """
  Subscribes the connected page to the Base market topic and the Robinhood
  market topic, each when its feed runs, and answers the current snapshot.
  """
  def subscribe(socket) do
    if Phoenix.LiveView.connected?(socket) do
      if running?(LabMarketFeed),
        do: Phoenix.PubSub.subscribe(Autolaunch.PubSub, LabMarketFeed.topic())

      if running?(RobinhoodMarketFeed),
        do: Phoenix.PubSub.subscribe(Autolaunch.PubSub, RobinhoodMarketFeed.topic())

      snapshot()
    else
      @empty
    end
  end

  @doc """
  Every running feed's per-auction readings by lowercase auction address, with
  one generation counter that moves whenever any of them does. The head and
  `degraded?` are the Base feed's; `robinhood_stale?` says the Robinhood feed's
  last read of its chain failed.
  """
  def snapshot do
    @empty
    |> join_base(running?(LabMarketFeed) && LabMarketFeed.snapshot())
    |> join_readings(running?(StocksMarketFeed) && StocksMarketFeed.snapshot())
    |> join_robinhood(running?(RobinhoodMarketFeed) && RobinhoodMarketFeed.snapshot())
  end

  @doc "Whether Robinhood's readings are stale: its feed runs and could not read its chain."
  def robinhood_stale?,
    do: running?(RobinhoodMarketFeed) and RobinhoodMarketFeed.snapshot().stale?

  @doc "The reading for one auction address, or `nil`."
  def reading(%{auctions: auctions}, address) when is_binary(address),
    do: Map.get(auctions, String.downcase(address))

  def reading(_market, _address), do: nil

  defp join_base(market, false), do: market

  defp join_base(market, base),
    do: join_readings(%{market | head: base.head, degraded?: base.degraded?}, base)

  defp join_readings(market, false), do: market

  defp join_readings(market, feed),
    do: %{
      market
      | generation: market.generation + feed.generation,
        auctions: Map.merge(market.auctions, feed.auctions)
    }

  defp join_robinhood(market, false), do: market

  defp join_robinhood(market, feed),
    do: join_readings(%{market | robinhood_stale?: feed.stale?}, feed)

  defp running?(feed), do: is_pid(Process.whereis(feed))
end
