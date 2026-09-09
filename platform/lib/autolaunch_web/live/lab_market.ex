defmodule AutolaunchWeb.LabMarket do
  @moduledoc false

  alias Autolaunch.Lab
  alias Autolaunch.LabMarketFeed
  alias Autolaunch.Stocks.LabMarketFeed, as: StocksMarketFeed

  @empty %{generation: 0, head: nil, degraded?: false, auctions: %{}}

  @doc "Subscribes the connected page to the lab market topic when a lab feed runs."
  def subscribe(socket) do
    if Phoenix.LiveView.connected?(socket) and Lab.enabled?() and Process.whereis(LabMarketFeed) do
      Phoenix.PubSub.subscribe(Autolaunch.PubSub, LabMarketFeed.topic())
      snapshot()
    else
      @empty
    end
  end

  @doc """
  Both feeds' per-auction readings by lowercase auction address, with one
  generation counter that moves whenever either does.
  """
  def snapshot do
    if Process.whereis(LabMarketFeed) do
      agent = LabMarketFeed.snapshot()

      case Process.whereis(StocksMarketFeed) do
        nil ->
          agent

        _pid ->
          stocks = StocksMarketFeed.snapshot()

          %{
            agent
            | generation: agent.generation + stocks.generation,
              auctions: Map.merge(agent.auctions, stocks.auctions)
          }
      end
    else
      @empty
    end
  end

  @doc "The reading for one auction address, or `nil`."
  def reading(%{auctions: auctions}, address) when is_binary(address),
    do: Map.get(auctions, String.downcase(address))

  def reading(_market, _address), do: nil
end
