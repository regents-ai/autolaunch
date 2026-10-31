defmodule Autolaunch.LaunchDiscovery.Count do
  @moduledoc """
  How many launches each Base launchpad has made at the latest block, against
  the highest launch id the site has recorded (`Autolaunch.LaunchDiscovery`),
  read once for every open page and held in `Autolaunch.SharedReading` under
  `key/1`. The pages that list launches say they are catching up while a
  launchpad has made a launch the site has not recorded, or while its count
  has not been read for more than 420 seconds (`catching_up?/0`): the
  `chain-events` skill's notice, for discovery by count.

  This is a supervised reader of an outside clock, the shape
  `Autolaunch.Exposure.Listing` has and the `elixir-stack` skill allows: it
  holds no queue, never writes the database, and stores only through
  `SharedReading`. It reads once it has started, then five minutes after each
  read, and within ten seconds of a discovery pass recording a new launch
  (`read_again/0`). A read that fails is tried again a minute later, and marks
  the count as not read only once the last good one is more than 420 seconds
  old: one five-minute turn and two retries a minute apart. One runs on each
  machine that serves pages while launches are open.
  """

  use GenServer

  alias Autolaunch.{ChainRefresh, SharedReading}
  alias Autolaunch.LaunchDiscovery.Discover

  @every_ms 300_000
  @retry_ms 60_000
  @late_s 420
  @topic "launch_count"

  @doc "Where the count of `launchpad` is held."
  def key(launchpad) when launchpad in [:base_revstake, :base_memestock],
    do: {:launch_count, Atom.to_string(launchpad)}

  @doc "The keys of every launchpad this site discovers launches on."
  def keys, do: Enum.map(Discover.launchpads(), &key(&1.launchpad))

  @doc """
  Whether a launchpad has made a launch the site has not recorded, or its count
  has not been read for more than 420 seconds. False before the first read.
  """
  @spec catching_up?() :: boolean()
  def catching_up?, do: Enum.any?(keys(), &behind?/1)

  defp behind?(key) do
    case SharedReading.fetch(key) do
      {:ok, %{degraded?: true}} -> true
      {:ok, %{reading: %{made: made, recorded: recorded}}} -> made > recorded
      :error -> false
    end
  end

  @doc "The reader, on a machine that serves pages while launches are open."
  def children do
    if !Autolaunch.Prelaunch.read_only?() and Discover.launchpads() != [] and
         Phoenix.Endpoint.server?(:autolaunch, AutolaunchWeb.Endpoint),
       do: [__MODULE__],
       else: []
  end

  @doc "Reads every count again soon, on every machine: a pass recorded a new launch."
  @spec read_again() :: :ok
  def read_again, do: Phoenix.PubSub.broadcast(Autolaunch.PubSub, @topic, :read_again)

  def start_link(_options), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(nil) do
    :ok = Phoenix.PubSub.subscribe(Autolaunch.PubSub, @topic)
    {:ok, %{read_at: nil, timer: nil}, {:continue, :read}}
  end

  @impl true
  def handle_continue(:read, count), do: {:noreply, read(count)}

  @impl true
  def handle_info(:read, count), do: {:noreply, read(count)}

  # A pass recorded a launch: read again once ten seconds have passed since the
  # last read began, unless the next read is due sooner.
  def handle_info(:read_again, count) do
    wait = max(count.read_at + ChainRefresh.gap_s() * 1_000 - now(), 0)

    case Process.read_timer(count.timer) do
      left when is_integer(left) and left > wait ->
        Process.cancel_timer(count.timer)
        {:noreply, %{count | timer: Process.send_after(self(), :read, wait)}}

      _sooner ->
        {:noreply, count}
    end
  end

  defp read(count) do
    read_at = now()
    read? = Enum.map(Discover.launchpads(), &read_one/1) |> Enum.all?()
    next = if read?, do: @every_ms, else: @retry_ms
    %{count | read_at: read_at, timer: Process.send_after(self(), :read, next)}
  end

  defp read_one(pad) do
    key = key(pad.launchpad)

    # Without the block, which moves on every read, so pages wake only when a
    # count changes.
    with {:ok, standing} <- Discover.standing(pad),
         :ok <- SharedReading.put(key, Map.take(standing, [:made, :recorded])) do
      true
    else
      {:error, _reason} ->
        if late?(key), do: SharedReading.degraded(key)
        false
    end
  end

  defp late?(key) do
    case SharedReading.fetch(key) do
      {:ok, %{at: %DateTime{} = at}} -> DateTime.diff(DateTime.utc_now(), at) > @late_s
      _never_read -> true
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
