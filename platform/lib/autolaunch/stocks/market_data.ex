defmodule Autolaunch.Stocks.MarketData do
  @moduledoc """
  What the create page shows about a stock before a launch is drafted: its
  price and where it can be bought.

  Prices come from the chain's Chainlink feeds (see `PriceFeeds`); venues come
  from DexScreener's pair listings. On Base the venues are the stock token's
  deepest Aerodrome pool and its deepest Uniswap pool, each linked to that
  venue's swap page; on Robinhood it is the single pair with the most volume
  in the last day, linked to its DexScreener page. Every answer is kept for ten
  minutes, and the reads happen in whichever process asks, so a page that asks
  from a background task never waits on them.
  """

  use GenServer

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.Stocks.{Assets, PriceFeeds}

  @ttl_ms 600_000
  @latest_round_data "0xfeaf968c"
  @usdc_base "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  @dexscreener "https://api.dexscreener.com"
  @base_venues [{"aerodrome", "Aerodrome"}, {"uniswap", "Uniswap"}]

  def start_link(options \\ []),
    do: GenServer.start_link(__MODULE__, %{}, name: Keyword.get(options, :name, __MODULE__))

  @doc "The chain's stock prices and the venues that trade the chosen stock."
  def overview(chain, stock), do: %{prices: prices(chain), venues: venues(chain, stock)}

  @doc "USD prices by ticker for every listed stock on the chain whose feed answered."
  def prices(chain), do: cached({:prices, chain}, fn -> read_prices(chain) end, %{})

  @doc "The venues that trade the stock, deepest or busiest first; none for no stock."
  def venues(_chain, nil), do: []

  def venues(chain, stock),
    do: cached({:venues, chain, stock.address}, fn -> read_venues(chain, stock) end, [])

  @doc "Forgets every kept answer, so the next ask reads again."
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:lookup, key}, _from, state) do
    case Map.fetch(state, key) do
      {:ok, {value, read_at}} ->
        if read_at + @ttl_ms > now(),
          do: {:reply, {:ok, value}, state},
          else: {:reply, :stale, state}

      :error ->
        {:reply, :stale, state}
    end
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{}}

  @impl true
  def handle_cast({:store, key, value}, state),
    do: {:noreply, Map.put(state, key, {value, now()})}

  defp cached(key, read, empty) do
    case GenServer.call(__MODULE__, {:lookup, key}) do
      {:ok, value} ->
        value

      :stale ->
        case read.() do
          {:ok, value} ->
            GenServer.cast(__MODULE__, {:store, key, value})
            value

          :error ->
            empty
        end
    end
  end

  # One `latestRoundData()` per listed stock, read concurrently; a feed that
  # does not answer leaves its ticker out, and no answer at all is not kept.
  defp read_prices(chain) do
    prices =
      chain
      |> Assets.all()
      |> Enum.flat_map(fn stock ->
        case PriceFeeds.feed(chain, stock.symbol) do
          {:ok, feed} -> [{PriceFeeds.ticker(stock.symbol), feed}]
          :error -> []
        end
      end)
      |> Task.async_stream(fn {ticker, feed} -> {ticker, read_price(chain, feed)} end,
        max_concurrency: 4,
        timeout: 10_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {ticker, {:ok, price}}} -> [{ticker, price}]
        _unanswered -> []
      end)
      |> Map.new()

    if prices == %{}, do: :error, else: {:ok, prices}
  end

  defp read_price(chain, feed) do
    case Rpc.request("eth_call", [%{to: feed, data: @latest_round_data}, "latest"],
           rpc_url: rpc_url(chain),
           client_key: :autolaunch_market_http_client,
           log_scope: "stocks market"
         ) do
      # roundId, answer, startedAt, updatedAt, answeredInRound
      {:ok, "0x" <> hex} when byte_size(hex) == 320 ->
        answer = hex |> binary_part(64, 64) |> String.to_integer(16)
        {:ok, Decimal.div(Decimal.new(answer), Integer.pow(10, PriceFeeds.decimals()))}

      _unavailable ->
        :error
    end
  end

  defp rpc_url(:base), do: Application.fetch_env!(:autolaunch, :base_read_rpc_url)
  defp rpc_url(:robinhood), do: Application.fetch_env!(:autolaunch, :robinhood_read_rpc_url)

  defp read_venues(:base, stock) do
    case get("/tokens/v1/base/#{stock.address}") do
      {:ok, pairs} when is_list(pairs) ->
        {:ok, Enum.flat_map(@base_venues, &deepest_pool(pairs, &1, stock.address))}

      _unavailable ->
        :error
    end
  end

  defp read_venues(:robinhood, stock) do
    ticker = PriceFeeds.ticker(stock.symbol)

    case get("/latest/dex/search?q=#{URI.encode_www_form(ticker)}") do
      {:ok, %{"pairs" => pairs}} when is_list(pairs) ->
        pairs
        |> Enum.filter(&(&1["chainId"] == "robinhood" and &1["baseToken"]["symbol"] == ticker))
        |> Enum.max_by(&volume/1, fn -> nil end)
        |> List.wrap()
        |> Enum.map(&venue(&1, venue_name(&1["dexId"]), &1["url"]))
        |> then(&{:ok, &1})

      _unavailable ->
        :error
    end
  end

  # The venue's deepest pool for the stock, as a single-item list; empty when
  # the venue has none.
  defp deepest_pool(pairs, {dex, name}, stock) do
    pairs
    |> Enum.filter(&(&1["dexId"] == dex))
    |> Enum.max_by(&liquidity/1, fn -> nil end)
    |> List.wrap()
    |> Enum.map(&venue(&1, name, swap_url(dex, stock)))
  end

  defp venue(pair, name, url),
    do: %{name: name, url: url, liquidity_usd: liquidity(pair), volume_usd: volume(pair)}

  defp liquidity(pair), do: number(pair["liquidity"]["usd"])
  defp volume(pair), do: number(pair["volume"]["h24"])

  defp number(value) when is_number(value), do: value / 1
  defp number(_missing), do: 0.0

  defp swap_url("aerodrome", stock),
    do: "https://aerodrome.finance/swap?from=#{@usdc_base}&to=#{stock}"

  defp swap_url("uniswap", stock),
    do:
      "https://app.uniswap.org/swap?chain=base&inputCurrency=#{@usdc_base}&outputCurrency=#{stock}"

  defp venue_name("uniswap"), do: "Uniswap"
  defp venue_name(dex) when is_binary(dex), do: String.capitalize(dex)
  defp venue_name(_unknown), do: "a venue"

  defp get(path) do
    client = Application.get_env(:autolaunch, :autolaunch_market_http_client, Req)

    case client.get(@dexscreener <> path,
           connect_options: [timeout: 3_000],
           receive_timeout: 5_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      _unavailable -> :error
    end
  rescue
    _error -> :error
  end

  defp now, do: System.monotonic_time(:millisecond)
end
