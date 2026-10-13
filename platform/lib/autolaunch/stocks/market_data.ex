defmodule Autolaunch.Stocks.MarketData do
  @moduledoc """
  The market prices the site shows: a stock's price and where it can be bought,
  for the create page, and the dollar value of an auction's currency, REGENT or
  a stock, for the auction pages.

  Stock prices come from the chain's Chainlink feeds (see `PriceFeeds`), and
  REGENT's price is its Base Uniswap pool's, from DexScreener. On Base the
  venues are the stock token's deepest USDC pool on Aerodrome and its deepest
  on Uniswap, deepest first, each linked to that venue's swap page. They come
  from GeckoTerminal's list of the token's twenty busiest pools: DexScreener's
  listing leaves out Aerodrome's concentrated pools, where most of a stock's
  trading is. On Robinhood it is the single DexScreener pair with the most
  volume in the last day, linked to its DexScreener page. A full answer is kept for
  ten minutes. A read that failed, or left a stock's price out, is tried again
  after one second, then two, four and so on, up to ten minutes. The reads
  happen in whichever process asks, so a page that asks from a background task
  never waits on them.
  """

  use GenServer

  alias Autolaunch.Chain.{Abi, Rpc}

  alias Autolaunch.Stocks.{Assets, PriceFeeds}
  alias RegentChain.Address

  @ttl_ms 600_000
  @first_retry_ms 1_000
  @latest_round_data "0xfeaf968c"
  @usdc_base "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  @dexscreener "https://api.dexscreener.com"
  @geckoterminal "https://api.geckoterminal.com/api/v2"
  @regent_pool "0x4ed3b69ac263ad86482f609b2c2105f64bcfd3a7e02e8e078ec9fec1f0324bed"
  @base_venues [{"aerodrome", "Aerodrome"}, {"uniswap", "Uniswap"}]

  def start_link(options \\ []),
    do: GenServer.start_link(__MODULE__, %{}, name: Keyword.get(options, :name, __MODULE__))

  @doc "The chain's stock prices and the venues that trade the chosen stock."
  def overview(chain, stock), do: %{prices: prices(chain), venues: venues(chain, stock)}

  @doc "USD prices by ticker for every listed stock on the chain whose feed answered."
  def prices(chain), do: cached({:prices, chain}, fn -> read_prices(chain) end, %{})

  @doc "One stock token's USD price on the chain; nil while its feed has not answered."
  def stock_price(chain, symbol), do: prices(chain)[PriceFeeds.ticker(symbol)]

  @doc "REGENT's USD price in its Base Uniswap pool; nil while DexScreener has not answered."
  def regent_price, do: cached(:regent_price, &read_regent_price/0, nil)

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
      {:ok, {value, expires_at, misses}} ->
        if expires_at > now(),
          do: {:reply, {:ok, value}, state},
          else: {:reply, {:stale, misses}, state}

      :error ->
        {:reply, {:stale, 0}, state}
    end
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{}}

  @impl true
  def handle_cast({:store, key, entry}, state),
    do: {:noreply, Map.put(state, key, entry)}

  # A full answer is kept for the whole ten minutes; a partial answer or none
  # is kept only until the next try, each wait twice the last.
  defp cached(key, read, empty) do
    case GenServer.call(__MODULE__, {:lookup, key}) do
      {:ok, value} ->
        value

      {:stale, misses} ->
        {value, entry} =
          case read.() do
            {:ok, value} -> {value, {value, now() + @ttl_ms, 0}}
            {:partial, value} -> {value, {value, now() + retry_ms(misses), misses + 1}}
            :error -> {empty, {empty, now() + retry_ms(misses), misses + 1}}
          end

        GenServer.cast(__MODULE__, {:store, key, entry})
        value
    end
  end

  defp retry_ms(misses), do: min(@first_retry_ms * Integer.pow(2, misses), @ttl_ms)

  # One `latestRoundData()` per listed stock, read concurrently; a feed that
  # does not answer leaves its ticker out and makes the answer partial.
  defp read_prices(chain) do
    feeds = chain |> Assets.all() |> Map.new(&{PriceFeeds.ticker(&1.symbol), &1.feed})

    prices =
      feeds
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

    cond do
      prices == %{} -> :error
      map_size(prices) < map_size(feeds) -> {:partial, prices}
      true -> {:ok, prices}
    end
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

  # The pool must be the REGENT pool this site names; any other token's price
  # in its place is no answer.
  defp read_regent_price do
    case get("#{@dexscreener}/latest/dex/pairs/base/#{@regent_pool}") do
      {:ok, %{"pairs" => [%{"baseToken" => %{"address" => token}, "priceUsd" => price} | _]}}
      when is_binary(price) ->
        if Address.equal?(token, Abi.regent_address()), do: positive(price), else: :error

      _unavailable ->
        :error
    end
  end

  defp positive(price) do
    with true <- byte_size(price) <= 100 and String.match?(price, ~r/^\d+(?:\.\d+)?$/),
         {decimal, ""} <- Decimal.parse(price, max_digits: :infinity),
         true <- Decimal.gt?(decimal, 0) do
      {:ok, decimal}
    else
      _unparsed -> :error
    end
  end

  defp rpc_url(:base), do: Application.fetch_env!(:autolaunch, :base_read_rpc_url)
  defp rpc_url(:robinhood), do: Application.fetch_env!(:autolaunch, :robinhood_read_rpc_url)

  defp read_venues(:base, stock) do
    token = String.downcase(stock.address)

    case get("#{@geckoterminal}/networks/base/tokens/#{token}/pools?page=1") do
      {:ok, %{"data" => pools}} when is_list(pools) ->
        dollar_pools = Enum.filter(pools, &dollar_pool?(&1, token))

        @base_venues
        |> Enum.flat_map(&deepest_pool(dollar_pools, &1, stock.address))
        |> Enum.sort_by(& &1.liquidity_usd, :desc)
        |> then(&{:ok, &1})

      _unavailable ->
        :error
    end
  end

  defp read_venues(:robinhood, stock) do
    ticker = PriceFeeds.ticker(stock.symbol)

    case get("#{@dexscreener}/latest/dex/search?q=#{URI.encode_www_form(ticker)}") do
      {:ok, %{"pairs" => pairs}} when is_list(pairs) ->
        pairs
        |> Enum.filter(&(&1["chainId"] == "robinhood" and &1["baseToken"]["symbol"] == ticker))
        |> Enum.max_by(&volume/1, fn -> nil end)
        |> List.wrap()
        |> Enum.map(
          &%{
            name: venue_name(&1["dexId"]),
            url: &1["url"],
            liquidity_usd: number(&1["liquidity"]["usd"]),
            volume_usd: volume(&1)
          }
        )
        |> then(&{:ok, &1})

      _unavailable ->
        :error
    end
  end

  # A pool of the stock against USDC, either way round: a pool against another
  # token is that token's market, and the swap page it would link starts from
  # USDC.
  defp dollar_pool?(%{"relationships" => relationships}, token) do
    sides =
      Enum.map(~w(base_token quote_token), fn side ->
        relationships |> get_in([side, "data", "id"]) |> to_string() |> String.downcase()
      end)

    Enum.sort(sides) == Enum.sort(["base_#{token}", "base_#{String.downcase(@usdc_base)}"])
  end

  defp dollar_pool?(_pool, _token), do: false

  # The venue's deepest pool, as a single-item list; empty when the venue has
  # none. GeckoTerminal names each of a venue's pool kinds apart, such as
  # `aerodrome-slipstream-3` and `uniswap-v4-base`, all starting with the
  # venue's name.
  defp deepest_pool(pools, {dex, name}, stock) do
    pools
    |> Enum.filter(
      &String.starts_with?(to_string(get_in(&1, ["relationships", "dex", "data", "id"])), dex)
    )
    |> Enum.max_by(&reserve/1, fn -> nil end)
    |> List.wrap()
    |> Enum.map(
      &%{
        name: name,
        url: swap_url(dex, stock),
        liquidity_usd: reserve(&1),
        volume_usd: dollars(get_in(&1, ["attributes", "volume_usd", "h24"]))
      }
    )
  end

  defp reserve(pool), do: dollars(get_in(pool, ["attributes", "reserve_in_usd"]))

  # GeckoTerminal writes dollar amounts as decimal text.
  defp dollars(text) when is_binary(text) do
    case Float.parse(text) do
      {amount, ""} -> amount
      _unparsed -> 0.0
    end
  end

  defp dollars(_missing), do: 0.0

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

  defp get(url) do
    client = Application.get_env(:autolaunch, :autolaunch_market_http_client, Req)

    case client.get(url,
           headers: [accept: "application/json"],
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
