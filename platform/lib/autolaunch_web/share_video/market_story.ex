defmodule AutolaunchWeb.ShareVideo.MarketStory do
  @moduledoc """
  What the share picture and video of a stock market on Autolaunch tell, read
  once at the latest block: covered calls on a Base stock, or one series of
  Isolated Exposure to After-hours Stocks. Both draw the stock's Chainlink price as a line
  (`Autolaunch.PriceFeedHistory`), in dollars per token as the pages show it.

  Covered calls mark each open call's strike over the last two weeks of the
  line, and close on the price and the lowest premium a buyer can take now.
  Isolated Exposure to After-hours Stocks colours the line by window through its series, after
  hours (close to open) and market hours (open to close), with a dot at each
  price the series applied, and closes on what each token is worth.

  With `wallet`, the closing figures are that wallet's own: the premium its
  calls earned and the calls it holds, or the tokens of each window it holds.
  Only the signed-in person who links the wallet is ever shown it.

  Prices are floats: they only draw the line. The figures are written from the
  chain's own whole numbers, as every amount on the site is; a seller's
  premium is worked out from each listing's totals.
  """

  alias Autolaunch.CoveredCalls
  alias Autolaunch.Exposure
  alias Autolaunch.PriceFeedHistory
  alias Autolaunch.Stocks.PriceFeeds
  alias AutolaunchWeb.{ExposureFormat, PublicDocuments, UsdValue}

  @covered_calls_days 14
  @exposure_lead 2 * 86_400
  @exposure_days 7
  @strikes 3
  @usdc 1_000_000
  @wad 1_000_000_000_000_000_000

  @type t :: map()

  @doc "A covered-call market's (`:covered_calls`) or an Exposure series' (`:exposure`) story."
  @spec read(:covered_calls | :exposure, String.t(), String.t() | nil) ::
          {:ok, t()} | {:error, atom()}
  def read(:covered_calls, symbol, wallet), do: covered_calls(symbol, wallet)
  def read(:exposure, address, wallet), do: exposure(address, wallet)

  @doc "The line's price at `count` moments evenly through its time, oldest first."
  @spec samples(t(), pos_integer()) :: [float()]
  def samples(story, count) do
    for step <- 0..(count - 1) do
      at = story.from + (story.now - story.from) * step / (count - 1)
      price_at(story.line, at)
    end
  end

  @doc "The price the line holds at `at`: a feed's price holds from one round to the next."
  @spec price_at([{number(), float()}], number()) :: float()
  def price_at([{_at, first} | _rest] = line, at) do
    Enum.reduce_while(line, first, fn
      {point_at, price}, _held when point_at <= at -> {:cont, price}
      _later, held -> {:halt, held}
    end)
  end

  @doc "Covered calls on `symbol`'s market, with `wallet`'s own figures when one is given."
  @spec covered_calls(String.t(), String.t() | nil) :: {:ok, t()} | {:error, atom()}
  def covered_calls(symbol, wallet) do
    with {:ok, config} <- CoveredCalls.Deployment.current(),
         {:ok, market} <- CoveredCalls.Deployment.market(symbol),
         {:ok, block, opts} <- CoveredCalls.Chain.latest(config.lab),
         {:ok, book} <- CoveredCalls.Chain.book(market, block, opts),
         from = block.timestamp - @covered_calls_days * 86_400,
         {:ok, history} <- PriceFeedHistory.since(market.feed, from, block, opts),
         open = stage(book.listings, block.timestamp, [:open]),
         {:ok, figures} <- covered_call_figures(market, book, open, wallet, block, opts) do
      {:ok,
       %{
         kind: :covered_calls,
         title: title("/stock/covered-call"),
         badge: open_badge(length(open)),
         symbol: market.symbol,
         ticker: PriceFeeds.ticker(market.symbol),
         from: from,
         now: block.timestamp,
         line: line(history, from, block.timestamp),
         bands: [],
         dots: [],
         levels: strikes(open),
         figures: figures
       }}
    end
  end

  @doc "One Isolated Exposure to After-hours Stocks series, with `wallet`'s own holdings when one is given."
  @spec exposure(String.t(), String.t() | nil) :: {:ok, t()} | {:error, atom()}
  def exposure(address, wallet) do
    with {:ok, config} <- Exposure.Deployment.current(),
         {:ok, address} <- Exposure.Deployment.series(address),
         {:ok, block, opts} <- Exposure.Chain.latest(config.lab),
         {:ok, series} <- Exposure.Chain.series(address, config, block, opts),
         from = exposure_from(series, block.timestamp),
         {:ok, history} <- PriceFeedHistory.since(series.feed, from, block, opts),
         {:ok, figures} <- exposure_figures(series, history, wallet, block, opts) do
      {:ok,
       %{
         kind: :exposure,
         title: title("/stock/isolated-afters"),
         badge: status_badge(series.status),
         symbol: series.stock.symbol,
         ticker: PriceFeeds.ticker(series.stock.symbol),
         from: from,
         now: block.timestamp,
         line: line(history, from, block.timestamp),
         bands: bands(series, block.timestamp),
         dots: Enum.map(series.prints, &{&1.at, &1.price / @wad}),
         levels: [],
         figures: figures
       }}
    end
  end

  defp title(path), do: Keyword.fetch!(PublicDocuments.page(path), :page_title)

  # The feed's points as dollars, starting at `from` and held to `now`.
  defp line(%{decimals: decimals, points: points}, from, now) do
    scale = :math.pow(10, decimals)
    points = Enum.map(points, fn {at, answer} -> {max(at, from), answer / scale} end)
    {_at, last} = List.last(points)
    points ++ [{now, last}]
  end

  # --- covered calls ---------------------------------------------------------------

  # The lowest strikes of the open calls, each with the first day its calls
  # expire.
  defp strikes(open) do
    open
    |> Enum.group_by(& &1.strike_per_token)
    |> Enum.map(fn {strike, listings} ->
      %{
        price: strike / @usdc,
        label: "#{UsdValue.dollars(usdc(strike))} strike",
        expiry: listings |> Enum.map(& &1.expiry) |> Enum.min()
      }
    end)
    |> Enum.sort_by(& &1.price)
    |> Enum.take(@strikes)
  end

  defp open_badge(0), do: "No calls open"
  defp open_badge(1), do: "1 call open"
  defp open_badge(count), do: "#{count} calls open"

  defp stage(listings, now, stages),
    do: Enum.filter(listings, &(CoveredCalls.Terms.stage(&1, now) in stages))

  defp covered_call_figures(_market, book, open, nil, _block, _opts) do
    price =
      case CoveredCalls.Quote.spot(book) do
        {:ok, spot} -> UsdValue.dollars(usdc(spot))
        {:error, :price_unavailable} -> "—"
      end

    premium =
      case Enum.map(open, & &1.premium_per_token) do
        [] -> "None open"
        premiums -> UsdValue.dollars(usdc(Enum.min(premiums)))
      end

    {:ok, [{"Price", price}, {"Calls from", premium}]}
  end

  # A seller's premium is worked out from each listing's totals; the contract
  # rounds each fill up on its own, so what it paid can be a micro-USDC a fill
  # more. Calls held count only while they can still be used: a call left
  # after its exercise window has lapsed.
  defp covered_call_figures(market, book, _open, wallet, block, opts) do
    wallet = String.downcase(wallet)
    usable = stage(book.listings, block.timestamp, [:open, :sold, :exercise])

    with {:ok, holdings} <- CoveredCalls.Chain.holdings(market, usable, wallet, block, opts) do
      earned =
        book.listings
        |> Enum.filter(&(&1.seller == wallet))
        |> Enum.map(fn listing ->
          premium =
            CoveredCalls.Terms.usdc_for(listing.filled, listing.premium_per_token, book.unit)

          premium - CoveredCalls.Terms.fee(premium)
        end)
        |> Enum.sum()

      held = holdings |> Enum.map(& &1.held) |> Enum.sum()

      {:ok,
       [
         {"Earned", UsdValue.dollars(usdc(earned))},
         {"Calls held", "#{RegentFormat.token_amount(held, digits(book.unit))} #{market.symbol}"}
       ]}
    end
  end

  defp usdc(micro), do: Decimal.new(1, micro, -6)

  # A stock token's raw units in one whole token, as its decimals.
  defp digits(unit), do: unit |> Integer.digits() |> length() |> Kernel.-(1)

  # --- Isolated Exposure to After-hours Stocks ----------------------------------------------------------

  # From two days before the series' first close, or the last week while it is
  # far off.
  defp exposure_from(%{boundaries: [first | _]}, now),
    do: min(first - @exposure_lead, now - @exposure_days * 86_400)

  # The series' windows: from its first close, close to open is after hours and
  # open to close is market hours. A window still to come is left out, and so
  # is every window after a series ended early: it ends at its last price.
  defp bands(series, now) do
    until = if series.status == :ended, do: last_print_at(series), else: now

    series.boundaries
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index()
    |> Enum.filter(fn {[from, _to], _index} -> from < until end)
    |> Enum.map(fn {[from, to], index} ->
      %{from: from, to: to, window: if(rem(index, 2) == 0, do: :after, else: :market)}
    end)
  end

  defp last_print_at(%{settled: 0, boundaries: [first | _]}), do: first

  defp last_print_at(%{settled: settled, boundaries: boundaries}),
    do: Enum.at(boundaries, settled - 1)

  defp status_badge(:pending), do: "Opens soon"
  defp status_badge(:active), do: "Live"
  defp status_badge(:ended), do: "Ended"

  # Before its first price the series has no token values yet: the stock's
  # price now and when the series opens, or, for one that ended before any
  # price, that none was applied.
  defp exposure_figures(%{status: :pending} = series, history, nil, _block, _opts),
    do: {:ok, [feed_price(history), {"Opens", ExposureFormat.moment(series.next.at)}]}

  defp exposure_figures(%{settled: 0}, history, nil, _block, _opts),
    do: {:ok, [feed_price(history), {"Prices", "None applied"}]}

  defp exposure_figures(series, _history, nil, _block, _opts),
    do:
      {:ok,
       [
         {"After-hours", leg_value(series, series.night)},
         {"Market-hours", leg_value(series, series.day)}
       ]}

  defp exposure_figures(series, _history, wallet, block, opts) do
    with {:ok, held} <- Exposure.Chain.holdings(series, String.downcase(wallet), block, opts) do
      decimals = series.stock.decimals

      {:ok,
       [
         {"After-hours",
          "#{RegentFormat.token_amount(held.overnight, decimals)} #{series.overnight.symbol}"},
         {"Market-hours",
          "#{RegentFormat.token_amount(held.session, decimals)} #{series.session.symbol}"}
       ]}
    end
  end

  defp feed_price(history) do
    {_at, answer} = List.last(history.points)
    {"Price", UsdValue.dollars(Decimal.new(1, answer, -history.decimals))}
  end

  # What one token of a window is worth now: dollars while the series runs,
  # the stock it pays once it has ended.
  defp leg_value(%{status: :ended, stock: stock, price: price}, ledger),
    do:
      "#{RegentFormat.token_amount(div(ledger * Integer.pow(10, stock.decimals), price), stock.decimals)} #{stock.symbol}"

  defp leg_value(_series, ledger), do: UsdValue.dollars(wad(ledger))

  defp wad(value), do: Decimal.new(1, value, -18)
end
