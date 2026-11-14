defmodule Autolaunch.Exposure.Chain do
  @moduledoc """
  What the version 2 factory (`ExposureFactoryV2`), its weekly series
  (`ExposureSeriesV2`), their two tokens and their Aerodrome pools say at one
  block, read through Multicall3 a batch at a time. Exposure keeps no records
  of its own: every figure a page or an agent sees is read here, so it matches
  the chain after any reload.

  A week is the factory's. The current week takes deposits; until its first
  deposit opens it, it is shown at the address `predictSeries` names, with the
  terms `seriesConfig` says it would open with. A week the factory's
  `seriesOf` names a series for is open; the site trusts no other source for
  which series are real.

  An open week's figures are what `previewState` says `settle` would leave now
  (status, end reason, prices applied, the last price and both ledgers),
  beside what the series has written on the chain (`settled`, and whether it
  has ended there), so a page can show the prices waiting to be applied.
  """

  import Bitwise

  alias Autolaunch.Chain.{Multicall, Rpc}
  alias Autolaunch.Exposure.Ledger
  alias Autolaunch.Lab
  alias RegentChain.{Abi, Call}

  @zero "0x0000000000000000000000000000000000000000"
  @statuses %{0 => :pending, 1 => :active, 2 => :ended}
  @end_reasons %{
    0 => nil,
    1 => :maturity,
    2 => :overnight_depleted,
    3 => :session_depleted,
    4 => :stale_feed,
    5 => :bad_price,
    6 => :feed_unreadable
  }
  # A boundary's price applies this long after it (ExposureSeriesV2.SETTLE_DELAY).
  @settle_delay 3_600
  # An initial close and five trading days (ExposureSeriesV2.MAX_BOUNDARIES).
  @max_boundaries 11
  @past 8
  @rounds 200
  @uint {:uint, 256}
  @config [
    :address,
    :address,
    {:uint, 16},
    {:uint, 8},
    @uint,
    :bytes32,
    {:array, {:uint, 64}},
    :bytes,
    :bytes,
    :bytes,
    :bytes
  ]

  @doc "How long after its moment a boundary's price applies, in seconds."
  def settle_delay, do: @settle_delay

  @doc "The read options and latest block of the Base deployment Exposure runs on."
  def latest(lab) do
    opts = Lab.rpc_opts(lab, "autolaunch exposure")
    with {:ok, block} <- Rpc.latest_block(opts), do: {:ok, block, opts}
  end

  @doc """
  The factory at `block`: its current week, whether opening a new week is
  paused, and each week from the description's first week to the current one
  that has a series, oldest first, as `{week, series}`.
  """
  def factory(config, block, opts) do
    # `currentWeek` is never past the week two after today's, its own first guess.
    last = div(div(block.timestamp, 86_400) + 3, 7) + 2
    weeks = Enum.to_list(config.first_week..last//1)

    reads =
      [
        {:current, config.factory, "currentWeek()", [], @uint},
        {:paused, config.factory, "paused()", [], :bool}
      ] ++
        for week <- weeks,
            do: {{:series, week}, config.factory, "seriesOf(uint256)", [week], :address}

    with {:ok, read} <- read(reads, block, opts) do
      opened =
        for {week, series} <- Enum.map(weeks, &{&1, read[{:series, &1}]}),
            week <= read.current and series != @zero,
            do: {week, series}

      {:ok,
       %{address: config.factory, current: read.current, paused: read.paused, opened: opened}}
    end
  end

  @doc """
  Week `week` (nil for the current one) at the latest block, with the block
  and the read options, or `:unknown_week` when it is neither current nor open.
  """
  def read_week(config, week) do
    with {:ok, block, opts} <- latest(config.lab),
         {:ok, factory} <- factory(config, block, opts),
         {:ok, reading} <- week(config, factory, week, block, opts),
         do: {:ok, reading, block, opts}
  end

  @doc "The current week, then the last eight open weeks before it, newest first."
  def listed(config, factory, block, opts) do
    past =
      factory.opened
      |> Enum.filter(fn {week, _series} -> week < factory.current end)
      |> Enum.reverse()
      |> Enum.take(@past)

    weeks([current(factory) | past], config, factory, block, opts)
  end

  @doc "Week `week` (nil for the current one), or `:unknown_week` when it is neither current nor open."
  def week(config, factory, week, block, opts) do
    with {:ok, entry} <- entry(factory, week),
         {:ok, [reading]} <- weeks([entry], config, factory, block, opts),
         do: {:ok, reading}
  end

  defp entry(factory, nil), do: {:ok, current(factory)}
  defp entry(%{current: week} = factory, week), do: {:ok, current(factory)}

  defp entry(factory, week) do
    case List.keyfind(factory.opened, week, 0) do
      nil -> {:error, :unknown_week}
      entry -> {:ok, entry}
    end
  end

  defp current(factory),
    do: List.keyfind(factory.opened, factory.current, 0) || {factory.current, nil}

  # Three requests whatever the number of weeks: each series' own state, then
  # its tokens, balances and pools, then the pools' reserves.
  defp weeks(entries, config, factory, block, opts) do
    with {:ok, own} <- read(Enum.flat_map(entries, &own_reads(&1, factory)), block, opts),
         {:ok, readings} <- each(entries, &reading(&1, own, factory, block)),
         {:ok, around} <- read(around_reads(readings, config), block, opts),
         readings = Enum.map(readings, &with_around(&1, around)),
         {:ok, reserves} <- read(reserve_reads(readings), block, opts) do
      {:ok, Enum.map(readings, &with_prices(&1, reserves, config.usdc))}
    end
  end

  defp own_reads({week, nil}, factory) do
    [
      {{week, :address}, factory.address, "predictSeries(uint256)", [week], :address},
      {{week, :config}, factory.address, "seriesConfig(uint256)", [week], {:tuple, @config}}
    ]
  end

  defp own_reads({week, series}, _factory) do
    [
      {{week, :asset}, series, "asset()", [], :address},
      {{week, :overnight}, series, "overnight()", [], :address},
      {{week, :session}, series, "session()", [], :address},
      {{week, :feed}, series, "feed()", [], :address},
      {{week, :phase}, series, "phase()", [], {:uint, 16}},
      {{week, :deposit_cap}, series, "depositCap()", [], @uint},
      {{week, :terms_hash}, series, "termsHash()", [], :bytes32},
      {{week, :boundary_count}, series, "boundaryCount()", [], @uint},
      {{week, :preview}, series, "previewState()", [],
       [{:uint, 8}, {:uint, 8}, @uint, @uint, @uint]},
      {{week, :status}, series, "status()", [], {:uint, 8}},
      {{week, :settled}, series, "settled()", [], {:uint, 8}},
      {{week, :last_price}, series, "lastPriceWad()", [], @uint},
      {{week, :last_round}, series, "lastRound()", [], {:uint, 64}},
      {{week, :unreadable_since}, series, "unreadableSince()", [], {:uint, 64}},
      {{week, :accounted}, series, "accountedAssets()", [], @uint}
    ] ++
      for index <- 0..(@max_boundaries - 1),
          do:
            {{week, {:boundary, index}}, series, "boundaries(uint256)", [index],
             {:maybe, {:uint, 64}}}
  end

  # A week not open yet: the terms the factory would open it with now.
  defp reading({week, nil}, read, factory, block) do
    [asset, feed, phase, _decimals, cap, terms, boundaries | names] = read[{week, :config}]
    [overnight_name, overnight_symbol, session_name, session_symbol] = names

    {:ok,
     base(week, read[{week, :address}], factory, block)
     |> Map.merge(%{
       opened?: false,
       stock: %{address: asset},
       overnight: %{address: nil, name: overnight_name, symbol: overnight_symbol},
       session: %{address: nil, name: session_name, symbol: session_symbol},
       feed: feed,
       phase: phase,
       deposit_cap: cap,
       terms_hash: terms,
       boundaries: boundaries,
       status: :unopened,
       end_reason: nil,
       applied: 0,
       price: 0,
       night: 0,
       settled: 0,
       ended_on_chain?: false,
       last_price: 0,
       last_round: 0,
       unreadable_since: nil,
       accounted: 0
     })}
  end

  defp reading({week, series}, read, factory, block) do
    value = &read[{week, &1}]
    count = value.(:boundary_count)
    boundaries = for index <- 0..(count - 1)//1, do: value.({:boundary, index})
    [status, reason, applied, price, night] = value.(:preview)

    if count in 1..@max_boundaries and Enum.all?(boundaries, &is_integer/1) do
      {:ok,
       base(week, series, factory, block)
       |> Map.merge(%{
         opened?: true,
         stock: %{address: value.(:asset)},
         overnight: %{address: value.(:overnight)},
         session: %{address: value.(:session)},
         feed: value.(:feed),
         phase: value.(:phase),
         deposit_cap: value.(:deposit_cap),
         terms_hash: value.(:terms_hash),
         boundaries: boundaries,
         status: Map.fetch!(@statuses, status),
         end_reason: Map.fetch!(@end_reasons, reason),
         applied: applied,
         price: price,
         night: night,
         settled: value.(:settled),
         ended_on_chain?: value.(:status) == 2,
         last_price: value.(:last_price),
         last_round: value.(:last_round),
         unreadable_since: if(value.(:unreadable_since) > 0, do: value.(:unreadable_since)),
         accounted: value.(:accounted)
       })}
    else
      {:error, :invalid_chain_response}
    end
  end

  defp base(week, address, factory, block),
    do: %{
      week: week,
      address: address,
      current?: week == factory.current,
      factory: factory.address,
      paused: factory.paused,
      block: block.number,
      now: block.timestamp
    }

  # Every token's name, symbol and decimals, once each; each open series' held
  # stock and token supplies; each token's pool against USDC.
  defp around_reads(readings, config) do
    tokens =
      readings
      |> Enum.flat_map(&[&1.stock.address, &1.overnight.address, &1.session.address])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    for(
      token <- tokens,
      {key, signature, type} <- [
        {:symbol, "symbol()", :bytes},
        {:name, "name()", :bytes},
        {:decimals, "decimals()", {:uint, 8}}
      ],
      do: {{token, key}, token, signature, [], type}
    ) ++
      for %{opened?: true} = reading <- readings,
          read <- [
            {{reading.week, :held}, reading.stock.address, "balanceOf(address)",
             [reading.address], @uint},
            {{reading.week, :overnight_supply}, reading.overnight.address, "totalSupply()", [],
             @uint},
            {{reading.week, :session_supply}, reading.session.address, "totalSupply()", [],
             @uint},
            {{reading.week, :overnight_pool}, config.pool_factory,
             "getPool(address,address,bool)", [reading.overnight.address, config.usdc, false],
             :address},
            {{reading.week, :session_pool}, config.pool_factory, "getPool(address,address,bool)",
             [reading.session.address, config.usdc, false], :address}
          ],
          do: read
  end

  defp with_around(reading, around) do
    token = fn token -> Map.merge(token, info(around, token.address)) end
    stock = token.(reading.stock)

    legs =
      if reading.opened?,
        do: %{overnight: token.(reading.overnight), session: token.(reading.session)},
        else: %{
          overnight: Map.put(reading.overnight, :decimals, stock.decimals),
          session: Map.put(reading.session, :decimals, stock.decimals)
        }

    figures =
      if reading.opened?,
        do: %{
          held: around[{reading.week, :held}],
          supply: %{
            overnight: around[{reading.week, :overnight_supply}],
            session: around[{reading.week, :session_supply}]
          },
          pools: %{
            overnight: pool(around[{reading.week, :overnight_pool}]),
            session: pool(around[{reading.week, :session_pool}])
          }
        },
        else: %{
          held: 0,
          supply: %{overnight: 0, session: 0},
          pools: %{overnight: nil, session: nil}
        }

    reading
    |> Map.merge(legs)
    |> Map.merge(figures)
    |> Map.put(:stock, stock)
    |> schedule()
  end

  defp info(_around, nil), do: %{}

  defp info(around, address),
    do: %{
      symbol: around[{address, :symbol}],
      name: around[{address, :name}],
      decimals: around[{address, :decimals}]
    }

  # The factory answers the zero address for a pair with no pool.
  defp pool(@zero), do: nil
  defp pool(address), do: %{address: address, usdc_per_token: nil}

  defp reserve_reads(readings) do
    for reading <- readings,
        {leg, %{address: pool}} <- reading.pools,
        do: {{reading.week, leg}, pool, "getReserves()", [], [@uint, @uint, @uint]}
  end

  # Each pool's price for one whole token (USDC micro-units): the USDC it holds
  # for each token it holds, before any trade moves it. Nil while a side is empty.
  defp with_prices(reading, reserves, usdc) do
    pools =
      Map.new(reading.pools, fn
        {leg, nil} ->
          {leg, nil}

        {leg, pool} ->
          [reserve0, reserve1, _last] = reserves[{reading.week, leg}]
          token = Map.fetch!(reading, leg)

          # Aerodrome orders a pool's two tokens by address.
          {held, dollars} =
            if token.address < usdc, do: {reserve0, reserve1}, else: {reserve1, reserve0}

          {leg, %{pool | usdc_per_token: per_token(held, dollars, token.decimals)}}
      end)

    Map.put(reading, :pools, pools)
  end

  defp per_token(held, dollars, decimals) when held > 0 and dollars > 0,
    do: div(dollars * Integer.pow(10, decimals), held)

  defp per_token(_held, _dollars, _decimals), do: nil

  # Where the week stands against its boundaries: the next one the series has
  # not written on the chain, how many prices `settle` would write now, and
  # whether a due price could not be read from the feed.
  defp schedule(%{opened?: false} = reading),
    do:
      Map.merge(reading, %{
        day: 0,
        next: nil,
        waiting: 0,
        end_waiting?: false,
        unreadable?: false
      })

  defp schedule(reading) do
    %{boundaries: boundaries, settled: settled, applied: applied, now: now} = reading

    next =
      if not reading.ended_on_chain? and settled < length(boundaries) do
        at = Enum.at(boundaries, settled)
        %{index: settled, at: at, open?: rem(settled, 2) == 1, due_at: at + @settle_delay}
      end

    unread = Enum.at(boundaries, applied)

    Map.merge(reading, %{
      day: reading.price - reading.night,
      next: next,
      waiting: if(reading.ended_on_chain?, do: 0, else: applied - settled),
      end_waiting?: reading.status == :ended and not reading.ended_on_chain?,
      unreadable?:
        reading.status != :ended and is_integer(unread) and now >= unread + @settle_delay
    })
  end

  @doc """
  The prices `reading`'s series has written on the chain, each with the feed
  round it came from and the ledgers it left: the round of the series' pinned
  phase in force at each boundary, the last one updated at or before it.
  Rounds are read newest first from the last one the series applied, 200 at a
  time, until one in force at the first boundary is in hand. `prints` is nil
  when the feed refuses the reads.
  """
  def prints(%{settled: 0} = reading, _block, _opts), do: {:ok, Map.put(reading, :prints, [])}

  def prints(reading, block, opts) do
    with {:ok, rounds} <- rounds(reading, reading.last_round, [], block, opts),
         do: {:ok, Map.put(reading, :prints, rounds && applied(reading, rounds))}
  end

  defp rounds(_reading, top, kept, _block, _opts) when top < 1, do: {:ok, kept}

  defp rounds(reading, top, kept, block, opts) do
    low = max(top - @rounds + 1, 1)
    first = hd(reading.boundaries)

    reads =
      for round <- low..top,
          do:
            {round, reading.feed, "getRoundData(uint80)", [bsl(reading.phase, 64) + round],
             {:maybe, [@uint, @uint, @uint, @uint, @uint]}}

    with {:ok, read} <- read(reads, block, opts) do
      found = for round <- low..top, do: {round, read[round]}

      cond do
        Enum.any?(found, &match?({_round, nil}, &1)) ->
          {:ok, nil}

        low == 1 or Enum.any?(found, fn {_round, [_, _, _, at, _]} -> at != 0 and at <= first end) ->
          {:ok, found ++ kept}

        true ->
          rounds(reading, low - 1, found ++ kept, block, opts)
      end
    end
  end

  defp applied(reading, rounds) do
    in_force =
      for at <- Enum.take(reading.boundaries, reading.settled) do
        rounds
        |> Enum.filter(fn {_round, [_, _, _, updated, _]} -> updated != 0 and updated <= at end)
        |> List.last()
      end

    {_round, [_, last_answer, _, _, _]} = List.keyfind(rounds, reading.last_round, 0)

    if Enum.any?(in_force, &is_nil/1) or last_answer == 0 do
      nil
    else
      # The series keeps prices in WAD; its feed answers in the feed's own decimals.
      scale = div(reading.last_price, last_answer)
      prices = Enum.map(in_force, fn {_round, [_, answer, _, _, _]} -> answer * scale end)

      [in_force, Ledger.path(prices), reading.boundaries]
      |> Enum.zip()
      |> Enum.with_index()
      |> Enum.map(fn {{{round, [_, _, _, updated, _]}, step, at}, index} ->
        %{
          index: index,
          at: at,
          open?: rem(index, 2) == 1,
          price: step.price,
          night: step.night,
          day: step.day,
          round_id: bsl(reading.phase, 64) + round,
          updated_at: updated
        }
      end)
    end
  end

  @doc """
  What `wallet` holds of each open week's tokens in `readings`, and what they
  return now, leaving out the weeks it holds nothing of.
  """
  def holdings(readings, wallet, block, opts) do
    opened = Enum.filter(readings, & &1.opened?)

    reads =
      for reading <- opened,
          leg <- [:overnight, :session],
          do:
            {{reading.week, leg}, Map.fetch!(reading, leg).address, "balanceOf(address)",
             [wallet], @uint}

    with {:ok, read} <- read(reads, block, opts) do
      held =
        for reading <- opened,
            overnight = read[{reading.week, :overnight}],
            session = read[{reading.week, :session}],
            overnight + session > 0,
            do: %{
              week: reading,
              overnight: overnight,
              session: session,
              redeemable: redeemable(reading, overnight, session)
            }

      {:ok, held}
    end
  end

  @doc """
  What `wallet` holds for one week: its two tokens (none before the week
  opens), the stock and what it lets the factory take of it for a deposit,
  its USDC, and the raw stock its tokens return now.
  """
  def holding(reading, config, wallet, block, opts) do
    legs =
      if reading.opened?,
        do: [overnight: reading.overnight.address, session: reading.session.address],
        else: []

    reads =
      [
        {:stock, reading.stock.address, "balanceOf(address)", [wallet], @uint},
        {:allowance, reading.stock.address, "allowance(address,address)",
         [wallet, config.factory], @uint},
        {:usdc, config.usdc, "balanceOf(address)", [wallet], @uint}
      ] ++ for {leg, token} <- legs, do: {leg, token, "balanceOf(address)", [wallet], @uint}

    with {:ok, read} <- read(reads, block, opts) do
      overnight = Map.get(read, :overnight, 0)
      session = Map.get(read, :session, 0)

      {:ok,
       %{
         wallet: wallet,
         overnight: overnight,
         session: session,
         stock: read.stock,
         allowance: read.allowance,
         usdc: read.usdc,
         redeemable: redeemable(reading, overnight, session)
       }}
    end
  end

  @doc """
  What trading one token against USDC through the Aerodrome router takes from
  `wallet` now: its USDC and token balances and what each lets the router
  take, and the token's pool, or nil where it has none.
  """
  def trade_position(reading, config, leg, wallet, block, opts) do
    token = Map.fetch!(reading, leg).address

    reads = [
      {:usdc, config.usdc, "balanceOf(address)", [wallet], @uint},
      {:usdc_allowance, config.usdc, "allowance(address,address)", [wallet, config.router],
       @uint},
      {:leg, token, "balanceOf(address)", [wallet], @uint},
      {:leg_allowance, token, "allowance(address,address)", [wallet, config.router], @uint}
    ]

    with {:ok, read} <- read(reads, block, opts) do
      pool = reading.pools[leg]
      {:ok, Map.put(read, :pool, pool && pool.address)}
    end
  end

  @doc """
  What `pool` pays out now for `amount` of `token_in`, as Aerodrome's own pool
  works it out, or nil while either side of the pool is empty.
  """
  def amount_out(pool, amount, token_in, block, opts) do
    with {:ok, [reserve0, reserve1, _last]} <-
           Rpc.call_words(pool, Call.encode("getReserves()", []), block, 3, opts) do
      if reserve0 == 0 or reserve1 == 0,
        do: {:ok, nil},
        else:
          Rpc.call_uint(
            pool,
            Call.encode("getAmountOut(uint256,address)", [amount, token_in]),
            block,
            opts
          )
    end
  end

  @doc "The raw stock a week still takes before its deposit cap."
  def room(reading), do: max(reading.deposit_cap - reading.accounted, 0)

  @doc """
  The amounts `redeem` takes from a holding of `overnight` and `session` now,
  and the raw stock it would pay: before the end, the whole pairs held; after
  it, every token.
  """
  def redeemable(%{status: :ended} = reading, overnight, session),
    do: %{overnight: overnight, session: session, paid: paid(reading, overnight, session)}

  def redeemable(reading, overnight, session) do
    pairs = min(overnight, session)
    %{overnight: pairs, session: pairs, paid: paid(reading, pairs, pairs)}
  end

  @doc "The raw stock `redeem(overnight, session)` pays now, as the contract works it out."
  def paid(reading, overnight, session),
    do: reading |> owed(overnight, session) |> Ledger.paid(reading.held, reading.accounted)

  @doc """
  The raw stock the tokens are owed before any cut for a seizure: whole pairs
  before the end, the final ledgers' share after it.
  """
  def owed(_reading, 0, 0), do: 0
  def owed(_reading, pairs, pairs), do: pairs

  def owed(%{status: :ended} = reading, overnight, session),
    do: Ledger.owed(overnight, session, reading.price, reading.night)

  # Named reads in as few requests as Multicall3 allows: each is `{key,
  # contract, signature, args, type}`, and the answer maps each key to its
  # value. A type list gives the values in order; `{:tuple, types}` a dynamic
  # tuple's; `{:maybe, type}` nil for a read the contract refuses.
  defp read(reads, block, opts) do
    calls =
      Enum.map(reads, fn {_key, to, signature, args, _type} ->
        {to, Call.encode(signature, args)}
      end)

    with {:ok, answers} <- Multicall.read(calls, block, opts),
         {:ok, values} <- reads |> Enum.zip(answers) |> each(&named/1),
         do: {:ok, Map.new(values)}
  end

  defp named({{key, _to, _signature, _args, type}, answer}) do
    with {:ok, value} <- decode(answer, type), do: {:ok, {key, value}}
  end

  defp decode(:reverted, {:maybe, _type}), do: {:ok, nil}
  defp decode(answer, {:maybe, type}), do: decode(answer, type)
  defp decode(:reverted, _type), do: {:error, :invalid_chain_response}

  defp decode(<<32::256, body::binary>>, {:tuple, types}), do: decoded(Abi.decode(body, types))
  defp decode(_answer, {:tuple, _types}), do: {:error, :invalid_chain_response}
  defp decode(answer, types) when is_list(types), do: decoded(Abi.decode(answer, types))

  defp decode(answer, type) do
    with {:ok, [value]} <- decoded(Abi.decode(answer, [type])), do: {:ok, value}
  end

  defp decoded({:ok, values}), do: {:ok, values}
  defp decoded(:error), do: {:error, :invalid_chain_response}

  defp each(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, kept} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | kept]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, kept} -> {:ok, Enum.reverse(kept)}
      error -> error
    end
  end
end
