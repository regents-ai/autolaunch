defmodule Autolaunch.Exposure.Listing do
  @moduledoc """
  The tokens of every series the site offers, as their contracts hold them at
  the latest block, read once for every open page and held in
  `Autolaunch.SharedReading` under `key/0`: the home page's Isolated list and
  the After-hours tokens at the top of its token list. A key marked degraded
  says the last read failed; the tokens read before it stay.

  This is a supervised reader of an outside clock, the shape `Autolaunch.ChainHead`
  has and the `elixir-stack` skill allows: it holds no queue and no copy of
  database rows, never writes the database, and stores only through
  `SharedReading`. It reads as it starts, then five minutes after each read
  finishes, and within ten seconds of a person's on-chain press landing on Base
  (`refresh/1`, from `Autolaunch.ChainRefresh`). A read that fails is not tried
  again: the next one replaces it. One runs on each machine that serves pages
  while Exposure is on. The series page and the routes read the chain
  themselves; only this list is shared.
  """

  use GenServer

  @behaviour Autolaunch.ChainRefresh

  alias Autolaunch.{ChainRefresh, Exposure, SharedReading}
  alias Autolaunch.Exposure.Deployment

  @every_ms 300_000
  @topic "exposure_listing"

  @doc "Where the tokens are held."
  def key, do: {:exposure_tokens, "base"}

  @doc """
  The tokens, newest series first, and whether the last read failed; nil
  while they have never been read.
  """
  @spec fetch() :: %{tokens: [map()] | nil, degraded?: boolean()} | nil
  def fetch do
    case SharedReading.fetch(key()) do
      {:ok, %{reading: tokens, degraded?: degraded?}} -> %{tokens: tokens, degraded?: degraded?}
      :error -> nil
    end
  end

  @doc """
  The two tokens of each series in `series`, newest series first: the
  After-hours token, then the Market-hours token, with how many are in
  circulation and what one sells for in USDC (micro-units) where its pool
  quotes one.
  """
  @spec tokens([map()]) :: [map()]
  def tokens(series) do
    for one <- series,
        {leg, title} <- [overnight: "After-hours", session: "Market-hours"] do
      token = Map.fetch!(one, leg)
      pool = one.pools[leg]

      %{
        id: token.address,
        name: token.name,
        symbol: token.symbol,
        leg: title,
        stock: one.stock.symbol,
        series: one.address,
        status: one.status,
        starts_at: List.first(one.boundaries),
        ends_at: List.last(one.boundaries),
        supply: one.supply[leg],
        decimals: token.decimals,
        usdc_per_token: pool && pool.usdc_per_token
      }
    end
  end

  @doc "The reader, on a machine that serves pages while Exposure is on."
  def children do
    if Deployment.enabled?() and Phoenix.Endpoint.server?(:autolaunch, AutolaunchWeb.Endpoint),
      do: [__MODULE__],
      else: []
  end

  @doc "Reads the series again soon, on every machine, when a press landed on their chain."
  @impl ChainRefresh
  def refresh(chain_id) do
    case Deployment.current() do
      {:ok, %{chain_id: ^chain_id}} ->
        Phoenix.PubSub.broadcast(Autolaunch.PubSub, @topic, :chain_refresh)

      _other_chain_or_off ->
        :ok
    end
  end

  def start_link(_options), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(nil) do
    :ok = Phoenix.PubSub.subscribe(Autolaunch.PubSub, @topic)
    {:ok, read(%{read_at: nil, timer: nil})}
  end

  @impl true
  def handle_info(:read, listing), do: {:noreply, read(listing)}

  # A press landed: read again once ten seconds have passed since the last
  # read began, unless the next read is due sooner.
  def handle_info(:chain_refresh, listing) do
    wait = max(listing.read_at + ChainRefresh.gap_s() * 1_000 - now(), 0)

    case Process.read_timer(listing.timer) do
      left when is_integer(left) and left > wait ->
        Process.cancel_timer(listing.timer)
        {:noreply, %{listing | timer: Process.send_after(self(), :read, wait)}}

      _sooner ->
        {:noreply, listing}
    end
  end

  defp read(listing) do
    read_at = now()

    case Exposure.exposure_series_list() do
      {:ok, series} -> SharedReading.put(key(), tokens(series))
      {:error, _reason} -> SharedReading.degraded(key())
    end

    %{listing | read_at: read_at, timer: Process.send_after(self(), :read, @every_ms)}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
