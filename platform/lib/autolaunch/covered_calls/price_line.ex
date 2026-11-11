defmodule Autolaunch.CoveredCalls.PriceLine do
  @moduledoc """
  The last 30 days of each covered-call market's Chainlink reference price,
  read once for every open page and held in `Autolaunch.SharedReading` under
  `key/1`: the line the Sell and Buy tickets draw their strike across.

  One reader runs for each market on each machine that serves pages, in
  `Autolaunch.ChainHead`'s shape, a supervised reader of an outside clock (one
  of the two shapes the `elixir-stack` skill lets reread on their own). Its
  first read walks the feed back 30 days (`Autolaunch.PriceFeedHistory`). Each
  later read, five minutes after the last finished, asks only for the rounds
  since the newest one held, adds them, drops what has passed out of the 30
  days and thins the rest to at most 240 points, the newest kept exact. It
  keeps no copy of its own: what it holds is the reading in `SharedReading`,
  so a restart of the reader alone carries on from there.

  A failed read marks the key degraded and keeps the points held, and the next
  read starts from them. A person's press never moves a price feed, so nothing
  here hears `Autolaunch.ChainRefresh`.
  """

  use GenServer

  alias Autolaunch.CoveredCalls.{Chain, Deployment}
  alias Autolaunch.{PriceFeedHistory, SharedReading}

  @every_ms 300_000
  @month 30 * 86_400
  @most 240
  # The newest point in each stretch of this many seconds is kept: the 30 days
  # touch at most 239 of them, and the point in force when they start makes 240.
  @stretch div(@month, @most - 2) + 1

  @type reading :: %{decimals: non_neg_integer(), points: [PriceFeedHistory.point()]}

  @doc "One reader for each covered-call market, none while covered calls are off."
  def children do
    case Deployment.current() do
      {:ok, %{markets: markets}} ->
        for market <- markets,
            do: Supervisor.child_spec({__MODULE__, market}, id: {__MODULE__, market.symbol})

      {:error, _off} ->
        []
    end
  end

  @doc "Where the last 30 days of `symbol`'s reference price are held."
  def key(symbol) when is_binary(symbol), do: {:price_history, symbol}

  @doc """
  `symbol`'s line as `[unix seconds, dollars]` pairs, oldest first, starting at
  most 30 days before the newest; nil while it has never been read, while its
  last read failed, or while it is a single price.
  """
  @spec line(String.t()) :: [[number()]] | nil
  def line(symbol) do
    case SharedReading.fetch(key(symbol)) do
      {:ok, %{reading: %{decimals: decimals, points: [_, _ | _] = points}, degraded?: false}} ->
        {newest, _answer} = List.last(points)
        scale = Integer.pow(10, decimals)
        for {at, answer} <- points, do: [max(at, newest - @month), answer / scale]

      _none ->
        nil
    end
  end

  def start_link(market), do: GenServer.start_link(__MODULE__, market)

  # The first read waits until the site has started, so a long walk never holds it up.
  @impl true
  def init(market), do: {:ok, market, {:continue, :read}}

  @impl true
  def handle_continue(:read, market), do: {:noreply, read(market)}

  @impl true
  def handle_info(:read, market), do: {:noreply, read(market)}

  defp read(%{symbol: symbol, feed: feed} = market) do
    key = key(symbol)

    with {:ok, %{lab: lab}} <- Deployment.current(),
         {:ok, block, opts} <- Chain.latest(lab),
         {:ok, reading} <- next(held(key), feed, block, opts),
         :ok <- SharedReading.put(key, reading) do
      :ok
    else
      _failed -> SharedReading.degraded(key)
    end

    Process.send_after(self(), :read, @every_ms)
    market
  end

  defp held(key) do
    case SharedReading.fetch(key) do
      {:ok, %{reading: %{points: [_ | _]} = reading}} -> reading
      _never_read -> nil
    end
  end

  defp next(nil, feed, block, opts) do
    cutoff = block.timestamp - @month

    with {:ok, %{decimals: decimals, points: points}} <-
           PriceFeedHistory.since(feed, cutoff, block, opts),
         do: {:ok, %{decimals: decimals, points: thin(points, cutoff)}}
  end

  defp next(%{decimals: decimals, points: held}, feed, block, opts) do
    {newest, _answer} = List.last(held)

    with {:ok, %{points: fresh}} <- PriceFeedHistory.since(feed, newest, block, opts) do
      newer = Enum.filter(fresh, fn {at, _answer} -> at > newest end)
      {:ok, %{decimals: decimals, points: thin(held ++ newer, block.timestamp - @month)}}
    end
  end

  # The point in force at `cutoff`, then the newest point of each stretch after it.
  defp thin(points, cutoff) do
    {past, within} = Enum.split_while(points, fn {at, _answer} -> at <= cutoff end)

    in_force = if past == [], do: [], else: [List.last(past)]

    kept =
      within
      |> Enum.chunk_by(fn {at, _answer} -> div(at, @stretch) end)
      |> Enum.map(&List.last/1)

    in_force ++ kept
  end
end
