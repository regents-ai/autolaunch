defmodule Autolaunch.Exposure.Listing do
  @moduledoc """
  Every series the site offers, as their contracts hold them at the latest
  block (`Autolaunch.Exposure.exposure_series_list/0`), shared by every
  visitor of the home page's token list.

  One reading is kept for five minutes (`:exposure_listing_kept_ms`; 0 keeps
  nothing, as the tests run); a landed press on the chain
  (`Autolaunch.ChainRefresh`) shortens that to ten seconds from when it was
  taken, so the next visit after a person acts reads again. It is taken inside
  this process, so visitors who ask while it is being taken wait for that one
  reading instead of each starting their own, as
  `Autolaunch.CoveredCalls.Book` does. The series page and the routes read the
  chain themselves; only the home page's list is shared.
  """

  use GenServer

  @behaviour Autolaunch.ChainRefresh

  alias Autolaunch.Exposure
  alias Autolaunch.Exposure.Deployment

  @read_timeout 30_000

  def start_link(options \\ []),
    do: GenServer.start_link(__MODULE__, nil, name: Keyword.get(options, :name, __MODULE__))

  @doc "The shared reading of every series, newest first, at most five minutes old."
  @spec read() :: {:ok, [map()]} | {:error, atom()}
  def read, do: GenServer.call(__MODULE__, :read, @read_timeout)

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
        address: token.address,
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

  @impl Autolaunch.ChainRefresh
  def refresh(chain_id) do
    case Deployment.current() do
      {:ok, %{chain_id: ^chain_id}} -> GenServer.cast(__MODULE__, :refresh)
      _other_chain_or_off -> :ok
    end
  end

  @impl GenServer
  def init(nil), do: {:ok, nil}

  @impl GenServer
  # However many refreshes arrive, a reading stays good for ten seconds from
  # when it was taken, so a crowd asking at once costs one read.
  def handle_cast(:refresh, nil), do: {:noreply, nil}

  def handle_cast(:refresh, {reading, taken_at, good_until}) do
    gap = Autolaunch.ChainRefresh.gap_s() * 1_000
    {:noreply, {reading, taken_at, min(good_until, taken_at + gap)}}
  end

  @impl GenServer
  def handle_call(:read, _from, {reading, _taken_at, good_until} = kept) do
    if good_until > now(), do: {:reply, {:ok, reading}, kept}, else: reread(kept)
  end

  def handle_call(:read, _from, nil), do: reread(nil)

  defp reread(kept) do
    case Exposure.exposure_series_list() do
      {:ok, series} ->
        taken_at = now()
        {:reply, {:ok, series}, {series, taken_at, taken_at + kept_ms()}}

      {:error, error} ->
        {:reply, {:error, Exposure.reason(error)}, kept}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp kept_ms, do: Application.get_env(:autolaunch, :exposure_listing_kept_ms, 300_000)
end
