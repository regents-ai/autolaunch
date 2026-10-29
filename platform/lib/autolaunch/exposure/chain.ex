defmodule Autolaunch.Exposure.Chain do
  @moduledoc """
  What an `ExposureSeriesV1`, its oracle, its legs and their pools say at one
  block. Exposure keeps no records of its own: every figure a page or an agent
  sees is read here, so it matches the chain after any reload.

  A series reading has the series' fixed terms (stock, legs, oracle, schedule,
  cap, terms hash), its state (status, how many prints are applied, the last
  price and both ledgers, the stock it accounts for and holds), every applied
  print with the feed round it came from, the next print to apply, and each
  leg's pool price in USDC when its pool exists.
  """

  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.Exposure.Ledger
  alias Autolaunch.Lab
  alias RegentChain.Call

  @statuses %{0 => :pending, 1 => :active, 2 => :ended}
  @end_reasons %{
    0 => nil,
    1 => :maturity,
    2 => :overnight_depleted,
    3 => :session_depleted,
    4 => :missing_print
  }
  @record_delay 3_600
  @concurrency 8
  @read_timeout 20_000

  @doc "The read options and latest block of the Base deployment Exposure runs on."
  def latest(lab) do
    opts = Lab.rpc_opts(lab, "autolaunch exposure")
    with {:ok, block} <- Rpc.latest_block(opts), do: {:ok, block, opts}
  end

  @doc "One series as it stands at `block`, with its legs' pool prices from `config`."
  def series(address, config, block, opts) do
    with {:ok, terms} <- terms(address, block, opts),
         {:ok, state} <- state(address, terms, block, opts),
         {:ok, prints} <- prints(terms, state, block, opts),
         {:ok, pools} <- pools(terms, config, block, opts) do
      {:ok,
       terms
       |> Map.merge(state)
       |> Map.merge(%{
         address: address,
         block: block.number,
         now: block.timestamp,
         prints: prints,
         next: next(terms, state, prints, block),
         pools: pools
       })}
    end
  end

  # What never changes once the series exists.
  defp terms(address, block, opts) do
    reads = [
      asset: {:address, "asset()"},
      overnight: {:address, "overnight()"},
      session: {:address, "session()"},
      oracle: {:address, "oracle()"},
      feed_id: {:word, "feedId()"},
      terms_hash: {:word, "termsHash()"},
      max_report_delay: {:uint, "maxReportDelay()"},
      deposit_cap: {:uint, "depositCap()"},
      boundary_count: {:uint, "boundaryCount()"}
    ]

    with {:ok, terms} <- read_all(address, reads, block, opts),
         {:ok, boundaries} <- boundaries(address, terms.boundary_count, block, opts),
         {:ok, feed} <- Rpc.call_address(terms.oracle, Call.encode("feed()", []), block, opts),
         {:ok, phase} <- Rpc.call_uint(terms.oracle, Call.encode("phase()", []), block, opts),
         {:ok, legs} <- legs([terms.overnight, terms.session], block, opts),
         {:ok, stock} <- token(terms.asset, block, opts) do
      [overnight, session] = legs

      {:ok,
       terms
       |> Map.drop([:boundary_count, :overnight, :session])
       |> Map.merge(%{
         boundaries: boundaries,
         feed: String.downcase(feed),
         phase: phase,
         stock: Map.put(stock, :address, terms.asset),
         overnight: Map.put(overnight, :address, terms.overnight),
         session: Map.put(session, :address, terms.session)
       })}
    end
  end

  # What the prints, mints and redemptions change.
  defp state(address, terms, block, opts) do
    reads = [
      status: {:uint, "status()"},
      end_reason: {:uint, "endReason()"},
      settled: {:uint, "settled()"},
      price: {:uint, "lastPriceWad()"},
      night: {:uint, "overnightLedgerWad()"},
      accounted: {:uint, "accountedAssets()"}
    ]

    with {:ok, state} <- read_all(address, reads, block, opts),
         {:ok, held} <- balance(terms.asset, address, block, opts),
         {:ok, overnight_supply} <- supply(terms.overnight.address, block, opts),
         {:ok, session_supply} <- supply(terms.session.address, block, opts) do
      {:ok,
       %{
         status: Map.fetch!(@statuses, state.status),
         end_reason: Map.fetch!(@end_reasons, state.end_reason),
         settled: state.settled,
         price: state.price,
         night: state.night,
         day: state.price - state.night,
         accounted: state.accounted,
         held: held,
         supply: %{overnight: overnight_supply, session: session_supply}
       }}
    end
  end

  # Each applied print with the feed round it came from, and the ledgers it
  # left, worked out from the prices exactly as the contract does.
  defp prints(terms, state, block, opts) do
    terms.boundaries
    |> Enum.take(state.settled)
    |> Enum.with_index()
    |> read_concurrently(fn {at, index} -> recorded(terms, at, index, block, opts) end)
    |> case do
      {:ok, recorded} ->
        steps = recorded |> Enum.map(& &1.price) |> Ledger.path()
        {:ok, Enum.zip_with(recorded, steps, &Map.merge(&1, Map.take(&2, [:night, :day])))}

      error ->
        error
    end
  end

  @doc """
  The print the oracle recorded for boundary `index` at `at`, with its feed
  round, or `price: 0` while none is recorded.
  """
  def recorded(terms, at, index, block, opts) do
    open? = rem(index, 2) == 1

    with {:ok, [price, observed_at, finalized_at]} <-
           Rpc.call_words(
             terms.oracle,
             Call.encode("getPrint(bytes32,uint64,bool)", [terms.feed_id, at, open?]),
             block,
             3,
             opts
           ),
         {:ok, [round_id, updated_at]} <-
           Rpc.call_words(
             terms.oracle,
             Call.encode("sourceOf(uint64,bool)", [at, open?]),
             block,
             2,
             opts
           ) do
      {:ok,
       %{
         index: index,
         at: at,
         open?: open?,
         price: price,
         observed_at: observed_at,
         finalized_at: finalized_at,
         round_id: round_id,
         updated_at: updated_at
       }}
    end
  end

  # The print to apply next and when it can be recorded, or nil once ended.
  defp next(_terms, %{status: :ended}, _prints, _block), do: nil

  defp next(terms, state, _prints, block) do
    at = Enum.at(terms.boundaries, state.settled)

    %{
      index: state.settled,
      at: at,
      open?: rem(state.settled, 2) == 1,
      recordable_at: at + @record_delay,
      deadline: at + terms.max_report_delay,
      due?: block.timestamp >= at + @record_delay
    }
  end

  @doc """
  Each leg's pool against USDC on the Aerodrome factory, and what one whole leg
  token sells for there now (USDC micro-units), or nil where there is no pool
  or it holds nothing to quote.
  """
  def pools(terms, config, block, opts) do
    [overnight: terms.overnight, session: terms.session]
    |> read_concurrently(fn {leg, token} ->
      with {:ok, pool} <- pool(token.address, config, block, opts) do
        {:ok, {leg, pool && quote(pool, token, block, opts)}}
      end
    end)
    |> case do
      {:ok, pools} -> {:ok, Map.new(pools)}
      error -> error
    end
  end

  defp pool(token, config, block, opts) do
    data = Call.encode("getPool(address,address,bool)", [token, config.usdc, false])

    # The factory answers the zero address for a pair with no pool.
    case Rpc.call_uint(config.pool_factory, data, block, opts) do
      {:ok, 0} ->
        {:ok, nil}

      {:ok, word} ->
        {:ok,
         "0x" <>
           (word |> Integer.to_string(16) |> String.pad_leading(40, "0") |> String.downcase())}

      error ->
        error
    end
  end

  # A pool with nothing in it refuses to quote: that leg shows no price, and the
  # rest of the page stands.
  defp quote(pool, token, block, opts) do
    data =
      Call.encode("getAmountOut(uint256,address)", [
        Integer.pow(10, token.decimals),
        token.address
      ])

    case Rpc.call_uint(pool, data, block, opts) do
      {:ok, usdc} -> %{address: pool, usdc_per_token: usdc}
      {:error, _no_quote} -> %{address: pool, usdc_per_token: nil}
    end
  end

  @doc """
  What `wallet` holds of the series' stock and legs, what it lets the series
  take of its stock, and the raw stock its legs would redeem for now: whole
  pairs before the end, every leg after it.
  """
  def holdings(series, wallet, block, opts) do
    with {:ok, overnight} <- balance(series.overnight.address, wallet, block, opts),
         {:ok, session} <- balance(series.session.address, wallet, block, opts),
         {:ok, stock} <- balance(series.stock.address, wallet, block, opts),
         {:ok, allowance} <-
           Rpc.call_uint(
             series.stock.address,
             Abi.encode_erc20("allowance", [wallet, series.address]),
             block,
             opts
           ) do
      {:ok,
       %{
         wallet: wallet,
         overnight: overnight,
         session: session,
         stock: stock,
         allowance: allowance,
         redeemable: redeemable(series, overnight, session)
       }}
    end
  end

  @doc """
  The amounts `redeem` takes from a holding of `overnight` and `session` now,
  and the raw stock it would pay: before the end, the whole pairs held; after
  it, every leg.
  """
  def redeemable(%{status: :ended} = series, overnight, session),
    do: %{
      overnight: overnight,
      session: session,
      paid: paid(series, overnight, session)
    }

  def redeemable(series, overnight, session) do
    pairs = min(overnight, session)
    %{overnight: pairs, session: pairs, paid: paid(series, pairs, pairs)}
  end

  @doc "The raw stock `redeem(overnight, session)` pays now, as the contract works it out."
  def paid(series, overnight, session),
    do: series |> owed(overnight, session) |> Ledger.paid(series.held, series.accounted)

  @doc """
  The raw stock the legs are owed before any cut for a seizure: whole pairs
  before the end, the frozen ledgers' share after it.
  """
  def owed(_series, 0, 0), do: 0

  def owed(%{status: :ended} = series, overnight, session),
    do: Ledger.owed(overnight, session, series.price, series.night)

  def owed(_series, pairs, pairs), do: pairs

  @doc """
  The round of the oracle's pinned feed phase in force at `at`: the last one
  updated at or before it, with when it was updated, or `:no_round`. Rounds of
  a phase count up from 1 and a missing round reads as zeros, so the search
  doubles until it finds a missing round, then halves.
  """
  def round_in_force(series, at, block, opts) do
    with {:ok, high} <- upper(series, 1, block, opts),
         {:ok, round} <- search(series, at, 0, high, block, opts),
         true <- round > 0 || {:error, :no_round},
         {:ok, updated_at} <- updated_at(series, round, block, opts),
         do: {:ok, %{round: round, updated_at: updated_at}}
  end

  defp upper(series, high, block, opts) do
    case updated_at(series, high, block, opts) do
      {:ok, 0} -> {:ok, high}
      {:ok, _updated} -> upper(series, high * 2, block, opts)
      error -> error
    end
  end

  # Rounds low+1 .. high-1 may exist; `low` is the last known in force at `at`.
  defp search(_series, _at, low, high, _block, _opts) when high - low <= 1, do: {:ok, low}

  defp search(series, at, low, high, block, opts) do
    mid = low + div(high - low, 2)

    case updated_at(series, mid, block, opts) do
      {:ok, updated} when updated != 0 and updated <= at ->
        search(series, at, mid, high, block, opts)

      {:ok, _later_or_missing} ->
        search(series, at, low, mid, block, opts)

      error ->
        error
    end
  end

  defp updated_at(series, round, block, opts) do
    round_id = Bitwise.bsl(series.phase, 64) + round

    with {:ok, [_round, _answer, _started, updated_at, _answered]} <-
           Rpc.call_words(
             series.feed,
             Call.encode("getRoundData(uint80)", [round_id]),
             block,
             5,
             opts
           ),
         do: {:ok, updated_at}
  end

  defp boundaries(address, count, block, opts) do
    0..(count - 1)//1
    |> read_concurrently(fn index ->
      Rpc.call_uint(address, Call.encode("boundaries(uint256)", [index]), block, opts)
    end)
  end

  defp legs(addresses, block, opts), do: read_concurrently(addresses, &token(&1, block, opts))

  defp token(address, block, opts) do
    with {:ok, symbol} <- Rpc.call_string(address, Call.encode("symbol()", []), block, opts),
         {:ok, name} <- Rpc.call_string(address, Call.encode("name()", []), block, opts),
         {:ok, decimals} <- Rpc.call_uint(address, Call.encode("decimals()", []), block, opts),
         do: {:ok, %{symbol: symbol, name: name, decimals: decimals}}
  end

  defp balance(token, holder, block, opts),
    do: Rpc.call_uint(token, Abi.encode_erc20("balance_of", [holder]), block, opts)

  defp supply(token, block, opts),
    do: Rpc.call_uint(token, Call.encode("totalSupply()", []), block, opts)

  defp read_all(address, reads, block, opts) do
    reads
    |> read_concurrently(fn {key, {kind, signature}} ->
      with {:ok, value} <- read(kind, address, signature, block, opts), do: {:ok, {key, value}}
    end)
    |> case do
      {:ok, values} -> {:ok, Map.new(values)}
      error -> error
    end
  end

  defp read(:uint, to, signature, block, opts),
    do: Rpc.call_uint(to, Call.encode(signature, []), block, opts)

  defp read(:address, to, signature, block, opts) do
    with {:ok, address} <- Rpc.call_address(to, Call.encode(signature, []), block, opts),
         do: {:ok, String.downcase(address)}
  end

  defp read(:word, to, signature, block, opts) do
    with {:ok, word} <- Rpc.call_uint(to, Call.encode(signature, []), block, opts),
         do:
           {:ok,
            "0x" <>
              (word |> Integer.to_string(16) |> String.pad_leading(64, "0") |> String.downcase())}
  end

  # Independent reads at one block, side by side; the first failure is the answer.
  defp read_concurrently(items, read) do
    items
    |> Task.async_stream(read, max_concurrency: @concurrency, timeout: @read_timeout)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, value}}, {:ok, kept} -> {:cont, {:ok, [value | kept]}}
      {:ok, {:error, _reason} = error}, _kept -> {:halt, error}
      {:exit, _reason}, _kept -> {:halt, {:error, :chain_unavailable}}
    end)
    |> case do
      {:ok, kept} -> {:ok, Enum.reverse(kept)}
      error -> error
    end
  end
end
