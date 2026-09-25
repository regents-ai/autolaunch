defmodule Autolaunch.MarketTicker do
  @moduledoc """
  The recent bids and trades the ticker at the foot of every page shows, read
  once and shared by every page that has it open.

  A saved bid or trade rereads them a second later, so a burst of them costs
  one read, and each new list goes out to every page as
  `{:market_ticker, entries}`. They are also reread each minute, because
  entries leave the list an hour after they happened. The list holds at most
  the twenty newest bids and the twenty newest trades of that hour.
  """

  use GenServer

  alias Autolaunch.{BidActivity, TokenTrade}

  @topic "market_ticker"
  @coalesce_ms 1_000
  @reread_ms 60_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The current list, newest first; each later one arrives as `{:market_ticker, entries}`."
  def subscribe do
    Phoenix.PubSub.subscribe(Autolaunch.PubSub, @topic)
    [{:entries, entries}] = :ets.lookup(__MODULE__, :entries)
    entries
  end

  @impl true
  def init(nil) do
    :ets.new(__MODULE__, [:named_table, :protected, read_concurrency: true])
    :ets.insert(__MODULE__, {:entries, []})
    Autolaunch.Listings.subscribe()
    Autolaunch.TokenTrades.subscribe()
    send(self(), :load)
    :timer.send_interval(@reread_ms, :load)
    {:ok, %{due: false}}
  end

  @impl true
  def handle_info({event, _id}, %{due: false} = state)
      when event in [:autolaunch_listings_changed, :autolaunch_trade] do
    Process.send_after(self(), :load, @coalesce_ms)
    {:noreply, %{state | due: true}}
  end

  def handle_info({event, _id}, state)
      when event in [:autolaunch_listings_changed, :autolaunch_trade],
      do: {:noreply, state}

  def handle_info(:load, state) do
    with {:ok, bids} <- Ash.read(BidActivity, action: :recent, actor: nil),
         {:ok, trades} <- Ash.read(TokenTrade, action: :recent, actor: nil) do
      entries = entries(bids, trades)
      :ets.insert(__MODULE__, {:entries, entries})
      Phoenix.PubSub.broadcast(Autolaunch.PubSub, @topic, {:market_ticker, entries})
    end

    {:noreply, %{state | due: false}}
  end

  # Bids and trades together, newest first.
  defp entries(bids, trades) do
    bids = for %{auction: %{}} = bid <- bids, do: {:bid, bid}
    trades = for %{token: %{auction: %{}}} = trade <- trades, do: {:trade, trade}

    Enum.sort_by(bids ++ trades, fn {_, entry} -> entry.occurred_at end, {:desc, DateTime})
  end
end
