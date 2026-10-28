defmodule Autolaunch.CoveredCalls.Book do
  @moduledoc """
  Each covered-call market's listings, as its contract holds them at the latest
  block, shared by every visitor (`Autolaunch.CoveredCalls.Chain.book/3`).

  One reading per market is kept for five minutes (`:covered_calls_book_kept_ms`;
  0 keeps nothing, as the tests run); a landed press on the chain
  (`Autolaunch.ChainRefresh`) shortens that to ten seconds from when it was
  taken, so the next visit after a person acts reads again. It is taken inside
  this process, so visitors who ask while it is being taken wait for that one
  reading instead of each starting their own, as `Autolaunch.RegentFacts` does.
  A reading never disables a button: a press is checked against the chain when
  its step is built (`Autolaunch.CoveredCalls.Steps`).
  """

  use GenServer

  @behaviour Autolaunch.ChainRefresh

  alias Autolaunch.CoveredCalls.{Chain, Deployment}

  @read_timeout 30_000

  def start_link(options \\ []),
    do: GenServer.start_link(__MODULE__, nil, name: Keyword.get(options, :name, __MODULE__))

  @doc "The shared reading of `symbol`'s market, at most five minutes old, and when it was taken."
  @spec read(String.t()) :: {:ok, map()} | {:error, atom()}
  def read(symbol), do: GenServer.call(__MODULE__, {:read, symbol}, @read_timeout)

  @impl Autolaunch.ChainRefresh
  def refresh(chain_id) do
    case Deployment.current() do
      {:ok, %{chain_id: ^chain_id}} -> GenServer.cast(__MODULE__, :refresh)
      _other_chain_or_off -> :ok
    end
  end

  @impl GenServer
  def init(nil), do: {:ok, %{}}

  @impl GenServer
  def handle_cast(:refresh, kept) do
    soon = Autolaunch.ChainRefresh.gap_s() * 1_000 - kept_ms()

    {:noreply,
     Map.new(kept, fn {symbol, {reading, read_at}} ->
       {symbol, {reading, min(read_at, read_at + soon)}}
     end)}
  end

  @impl GenServer
  def handle_call({:read, symbol}, _from, kept) do
    case kept do
      %{^symbol => {reading, read_at}} ->
        if read_at + kept_ms() > now(),
          do: {:reply, {:ok, reading}, kept},
          else: reread(symbol, kept)

      _none ->
        reread(symbol, kept)
    end
  end

  defp reread(symbol, kept) do
    with {:ok, config} <- Deployment.current(),
         {:ok, market} <- Deployment.market(symbol),
         {:ok, block, opts} <- Chain.latest(config.lab),
         {:ok, book} <- Chain.book(market, block, opts) do
      reading = Map.merge(book, %{market: market, read_at: DateTime.utc_now()})
      {:reply, {:ok, reading}, Map.put(kept, symbol, {reading, now()})}
    else
      {:error, reason} -> {:reply, {:error, reason}, kept}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp kept_ms, do: Application.get_env(:autolaunch, :covered_calls_book_kept_ms, 300_000)
end
