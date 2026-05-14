defmodule Autolaunch.Launch.AuctionSyncPoller do
  @moduledoc false

  use GenServer

  alias Autolaunch.Launch.AuctionSync
  alias AutolaunchWeb.LiveUpdates

  require Logger

  @default_interval_ms 30_000

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def wake do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :wake)
    :ok
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      batch_size: Keyword.get(opts, :batch_size, 20),
      recent_hours: Keyword.get(opts, :recent_hours, 168)
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_cast(:wake, state) do
    send(self(), :poll)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    sync(state)
    Process.send_after(self(), :poll, state.interval_ms)
    {:noreply, state}
  end

  defp sync(state) do
    case AuctionSync.sync_once(limit: state.batch_size, recent_hours: state.recent_hours) do
      {:ok, %{changed: changed, graduated: graduated, failed: failed}}
      when changed + graduated + failed > 0 ->
        LiveUpdates.broadcast([:market, :tokens, :system])

      {:ok, _summary} ->
        :ok
    end
  rescue
    exception in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("Auction sync waiting for database: #{Exception.message(exception)}")
      :ok
  end
end
