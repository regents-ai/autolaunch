defmodule Autolaunch.ExposureChain do
  @moduledoc """
  Exposure switched on for one test, on a chain double that answers every read
  at the latest block by the contract asked, alone or through Multicall3: the
  version 2 factory and its weekly series, their two tokens and the stock, the
  feed's rounds, the Aerodrome factory's pools and their quotes. Every other
  request goes to `Autolaunch.BaseRpcStub`.

  The default is week 2968 (Monday 16 to Friday 20 November 2026) on Monday at
  11:00 New York time: open, with Friday's close (250) and Monday's open (256)
  applied, 0.1 AMZNc deposited of a 0.4 cap, and pools for both tokens.

  Each week the chain knows is open, its figures over `week_defaults/0`; a
  week with `opened: false` is not, and is answered by the factory's
  `predictSeries` and `seriesConfig` alone. `prices` are the prices the
  series has written, `due` the ones `previewState` would apply on top, and
  `status` and `end_reason` what `previewState` says; `chain_status` is
  `status()` on the chain when it differs. The feed's rounds are made from
  every week's prices, one a minute before each moment, then `latest`.

  `install/1` switches Exposure on and puts the chain; `put/1` changes it
  mid-test (`week:` changes the current week alone, `unreadable: true` fails
  every contract read). Both are undone when the test exits.
  """

  alias Autolaunch.{BaseRpcStub, Lab}
  alias Autolaunch.Chain.Multicall
  alias Autolaunch.Exposure.Ledger
  alias RegentChain.Call

  @week 2968
  @factory "0xfac7000000000000000000000000000000000002"
  @stock "0xb200000000000000000000d9192b6b456483c2e8"
  @feed "0x06a8e4b3abb3b7543d8396fb2b763d22820cb295"
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @pool_factory "0x420dd381b31aef6683db6b902084cb0ffece40da"
  @router "0xcf77a3ba9a5ca399b7c97c74d54e5b1beb874e43"
  @terms_hash "0x5f67343b39277939aea7613c578fa3931b8b89da7a65eb36dd7217c81a5a2e8f"
  @phase 2
  @wad 1_000_000_000_000_000_000
  @unit 100_000_000
  # The feed answers in 8 decimals; the series keeps WAD.
  @feed_scale 10_000_000_000
  # Week 2968's first moment, Friday 13 November 16:00 New York.
  @start 1_794_603_600
  # Monday 16 November, 11:00 New York.
  @now 1_794_844_800
  # Each kind of address, then the week number.
  @prefixes %{
    "5e" => :series,
    "0a" => :overnight,
    "0b" => :session,
    "33" => :overnight_pool,
    "44" => :session_pool
  }

  def week, do: @week
  def factory, do: @factory
  def stock, do: @stock
  def feed, do: @feed
  def usdc, do: @usdc
  def router, do: @router
  def terms_hash, do: @terms_hash
  def unit, do: @unit
  def wad, do: @wad
  def now, do: @now
  def phase, do: @phase

  @doc "Week `week`'s series address, the same before and after it opens."
  def series(week \\ @week), do: address("5e", week)
  def overnight(week \\ @week), do: address("0a", week)
  def session(week \\ @week), do: address("0b", week)
  def pool(leg, week \\ @week), do: address(if(leg == :overnight, do: "33", else: "44"), week)

  @doc "Week `week`'s moments: the close before it, then each 9:30 open and 16:00 close."
  def boundaries(week \\ @week) do
    start = @start + (week - @week) * 7 * 86_400
    [start] ++ for day <- 0..4, at <- [235_800, 259_200], do: start + day * 86_400 + at
  end

  @doc "An open week's figures before a test's own."
  def week_defaults do
    %{
      opened: true,
      status: 1,
      end_reason: 0,
      chain_status: nil,
      # Close 250, open 256: After-hours 125 → 131, Market-hours 125.
      prices: [250 * @wad, 256 * @wad],
      due: [],
      deposit_cap: 40_000_000,
      accounted: 10_000_000,
      held: 10_000_000,
      supply: 10_000_000,
      unreadable_since: 0,
      # Each token's pool quote for one whole token, or nil for an empty pool.
      pools: %{overnight: 2_640_000, session: 2_510_000},
      # The wallet's After-hours and Market-hours tokens.
      mine: {0, 0}
    }
  end

  @doc "Switches Exposure on for this test, on a chain answering `overrides` over the defaults."
  def install(overrides \\ %{}) do
    path = Path.join(System.tmp_dir!(), "exposure-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      Jason.encode!(%{
        chain_id: Lab.chain_id(),
        factory: @factory,
        first_week: Map.get(overrides, :first_week, @week - 10),
        usdc: @usdc,
        pool_factory: @pool_factory,
        router: @router
      })
    )

    previous =
      for key <- [:exposure, :autolaunch_base_exposure_deployment],
          do: {key, Application.get_env(:autolaunch, key)}

    Application.put_env(:autolaunch, :exposure, :on)
    Application.put_env(:autolaunch, :autolaunch_base_exposure_deployment, path)

    BaseRpcStub.install(:autolaunch_lab_http_client, fn _call, _state -> "0x" end)
    Application.put_env(:autolaunch, :autolaunch_lab_http_client, __MODULE__)

    put(Map.delete(overrides, :first_week))

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(previous, &restore/1)
      Application.delete_env(:autolaunch, :exposure_chain)
      File.rm(path)
    end)

    :ok
  end

  @doc """
  The chain from now on: `overrides` over the defaults. The current week is
  always known to the factory; `weeks` adds others by number, and `week`
  changes the current week's figures alone.
  """
  def put(overrides) do
    current = Map.get(overrides, :current, @week)

    weeks =
      %{current => %{}}
      |> Map.merge(Map.get(overrides, :weeks, %{}))
      |> Map.update!(current, &Map.merge(&1, Map.get(overrides, :week, %{})))
      |> Map.new(fn {week, figures} -> {week, Map.merge(week_defaults(), figures)} end)

    wallet =
      Map.merge(
        %{stock: 50_000_000, allowance: 0, usdc: 0, usdc_allowance: 0, leg_allowance: 0},
        Map.get(overrides, :wallet, %{})
      )

    state =
      Map.merge(
        %{now: @now, current: @week, paused: false, latest: {@now - 60, 25_700_000_000}},
        Map.drop(overrides, [:weeks, :week, :wallet])
      )
      |> Map.merge(%{weeks: weeks, wallet: wallet})

    Application.put_env(:autolaunch, :exposure_chain, Map.put(state, :rounds, rounds(state)))
  end

  def post(url, options) do
    state = Application.fetch_env!(:autolaunch, :exposure_chain)

    case options[:json] do
      %{method: "eth_call"} = call ->
        call(state, call)

      %{method: "eth_getBlockByNumber"} ->
        {:ok,
         %{
           status: 200,
           body: %{
             "result" => %{
               "number" => "0x20",
               "hash" => BaseRpcStub.safe_hash(),
               "timestamp" => "0x" <> Integer.to_string(state.now, 16)
             }
           }
         }}

      _other ->
        BaseRpcStub.post(url, options)
    end
  end

  # `unreadable: true` makes every contract read fail, as a chain that can't be reached just now.
  defp call(%{unreadable: true}, _call), do: {:ok, %{status: 503, body: ""}}

  defp call(state, %{params: [%{to: to, data: data}, _block]}) do
    answer =
      if String.downcase(to) == Multicall.address(),
        do: BaseRpcStub.aggregate(data, &answer(state, String.downcase(&1), &2)),
        else: answer(state, String.downcase(to), data)

    case answer do
      :revert -> {:ok, %{status: 200, body: %{"error" => %{"message" => "execution reverted"}}}}
      hex -> {:ok, %{status: 200, body: %{"result" => hex}}}
    end
  end

  @reads ~w|currentWeek() paused() seriesOf(uint256) predictSeries(uint256) seriesConfig(uint256)
            asset() overnight() session() feed() phase() depositCap() termsHash() boundaryCount()
            boundaries(uint256) previewState() status() settled() lastPriceWad() lastRound()
            unreadableSince() accountedAssets() getRoundData(uint80) latestRoundData()
            symbol() name() decimals() totalSupply() balanceOf(address)
            allowance(address,address) getPool(address,address,bool)
            getAmountOut(uint256,address) getReserves()|
         |> Map.new(&{Call.selector(&1), &1})

  defp answer(state, to, data) do
    case words(Map.fetch!(@reads, String.slice(data, 0, 10)), kind(to, state), state, args(data)) do
      :revert -> :revert
      {:raw, bytes} -> "0x" <> Base.encode16(bytes, case: :lower)
      {:string, text} -> "0x" <> Base.encode16(<<32::256>> <> string(text), case: :lower)
      words -> "0x" <> Enum.map_join(words, &BaseRpcStub.hex_word/1)
    end
  end

  # What the address is: a known contract, or one of a week's.
  defp kind(@factory, _state), do: :factory
  defp kind(@stock, _state), do: :stock
  defp kind(@usdc, _state), do: :usdc
  defp kind(@feed, _state), do: :feed
  defp kind(@pool_factory, _state), do: :pool_factory

  defp kind("0x" <> <<prefix::binary-size(2), week::binary-size(38)>>, state) do
    week = String.to_integer(week, 16)

    case {Map.fetch(@prefixes, prefix), state.weeks[week]} do
      {{:ok, kind}, %{opened: true} = figures} -> {kind, week, figures}
      _other -> :nothing
    end
  end

  defp words("currentWeek()", :factory, state, _args), do: [state.current]
  defp words("paused()", :factory, state, _args), do: [if(state.paused, do: 1, else: 0)]

  defp words("seriesOf(uint256)", :factory, state, [week]) do
    case state.weeks[week] do
      %{opened: true} -> [word(series(week))]
      _unopened -> [0]
    end
  end

  defp words("predictSeries(uint256)", :factory, _state, [week]), do: [word(series(week))]

  defp words("seriesConfig(uint256)", :factory, state, [week]) do
    figures = Map.get(state.weeks, week, week_defaults())
    [overnight, session] = names(week)

    {:raw,
     <<32::256>> <>
       tuple(
         [word(@stock), word(@feed), @phase, 8, figures.deposit_cap, word(@terms_hash)],
         [
           array(boundaries(week))
           | Enum.map(Tuple.to_list(overnight) ++ Tuple.to_list(session), &string/1)
         ]
       )}
  end

  defp words("asset()", {:series, _week, _figures}, _state, _args), do: [word(@stock)]

  defp words("overnight()", {:series, week, _figures}, _state, _args),
    do: [word(overnight(week))]

  defp words("session()", {:series, week, _figures}, _state, _args), do: [word(session(week))]
  defp words("feed()", {:series, _week, _figures}, _state, _args), do: [word(@feed)]
  defp words("phase()", {:series, _week, _figures}, _state, _args), do: [@phase]

  defp words("depositCap()", {:series, _week, figures}, _state, _args),
    do: [figures.deposit_cap]

  defp words("termsHash()", {:series, _week, _figures}, _state, _args), do: [word(@terms_hash)]

  defp words("boundaryCount()", {:series, week, _figures}, _state, _args),
    do: [length(boundaries(week))]

  defp words("boundaries(uint256)", {:series, week, _figures}, _state, [index]) do
    case Enum.at(boundaries(week), index) do
      nil -> :revert
      at -> [at]
    end
  end

  defp words("previewState()", {:series, _week, figures}, _state, _args) do
    %{price: price, night: night} = last(figures.prices ++ figures.due)

    [figures.status, figures.end_reason, length(figures.prices ++ figures.due), price, night]
  end

  defp words("status()", {:series, _week, figures}, _state, _args),
    do: [figures.chain_status || figures.status]

  defp words("settled()", {:series, _week, figures}, _state, _args), do: [length(figures.prices)]

  defp words("lastPriceWad()", {:series, _week, figures}, _state, _args),
    do: [last(figures.prices).price]

  defp words("lastRound()", {:series, week, figures}, state, _args) do
    case figures.prices do
      [] -> [0]
      prices -> [round_at(state, Enum.at(boundaries(week), length(prices) - 1))]
    end
  end

  defp words("unreadableSince()", {:series, _week, figures}, _state, _args),
    do: [figures.unreadable_since]

  defp words("accountedAssets()", {:series, _week, figures}, _state, _args),
    do: [figures.accounted]

  defp words("getRoundData(uint80)", :feed, state, [round_id]) do
    round = round_id - Bitwise.bsl(@phase, 64)

    case round >= 1 && Enum.at(state.rounds, round - 1) do
      {updated_at, answer} -> [round_id, answer, updated_at, updated_at, round_id]
      _missing -> [0, 0, 0, 0, 0]
    end
  end

  defp words("latestRoundData()", :feed, state, _args) do
    round_id = Bitwise.bsl(@phase, 64) + length(state.rounds)
    {updated_at, answer} = List.last(state.rounds)
    [round_id, answer, updated_at, updated_at, round_id]
  end

  defp words("symbol()", :stock, _state, _args), do: {:string, "AMZNc"}
  defp words("name()", :stock, _state, _args), do: {:string, "Amazon"}

  defp words("symbol()", {leg, week, _figures}, _state, _args)
       when leg in [:overnight, :session],
       do: {:string, elem(name(leg, week), 1)}

  defp words("name()", {leg, week, _figures}, _state, _args)
       when leg in [:overnight, :session],
       do: {:string, elem(name(leg, week), 0)}

  defp words("decimals()", _token, _state, _args), do: [8]

  defp words("totalSupply()", {leg, _week, figures}, _state, _args)
       when leg in [:overnight, :session],
       do: [figures.supply]

  defp words("balanceOf(address)", :stock, state, [holder]) do
    held =
      Enum.find_value(state.weeks, fn {week, figures} ->
        if figures.opened and word(series(week)) == holder, do: figures.held
      end)

    [held || state.wallet.stock]
  end

  defp words("balanceOf(address)", {:overnight, _week, figures}, _state, _args),
    do: [elem(figures.mine, 0)]

  defp words("balanceOf(address)", {:session, _week, figures}, _state, _args),
    do: [elem(figures.mine, 1)]

  defp words("balanceOf(address)", :usdc, state, _args), do: [state.wallet.usdc]
  defp words("allowance(address,address)", :stock, state, _args), do: [state.wallet.allowance]
  defp words("allowance(address,address)", :usdc, state, _args), do: [state.wallet.usdc_allowance]

  defp words("allowance(address,address)", {leg, _week, _figures}, state, _args)
       when leg in [:overnight, :session],
       do: [state.wallet.leg_allowance]

  defp words("getPool(address,address,bool)", :pool_factory, state, [token, _usdc, _stable]) do
    case kind(address(token), state) do
      {leg, week, %{pools: pools}} when is_map_key(pools, leg) -> [word(pool(leg, week))]
      _other -> [0]
    end
  end

  # A pool with a quote holds one whole token and that much USDC, the token
  # first by address; one without holds nothing.
  defp words("getReserves()", {pool, _week, figures}, _state, _args)
       when pool in [:overnight_pool, :session_pool] do
    case figures.pools[leg(pool)] do
      nil -> [0, 0, 0]
      quote -> [@unit, quote, 0]
    end
  end

  # An empty Aerodrome pool quotes zero rather than reverting.
  defp words("getAmountOut(uint256,address)", {pool, _week, figures}, _state, _args)
       when pool in [:overnight_pool, :session_pool],
       do: [figures.pools[leg(pool)] || 0]

  defp words(_read, _contract, _state, _args), do: :revert

  defp leg(:overnight_pool), do: :overnight
  defp leg(:session_pool), do: :session

  defp name(:overnight, week), do: week |> names() |> hd()
  defp name(:session, week), do: week |> names() |> List.last()

  # The tokens' names and symbols, from the day the week ends.
  defp names(week) do
    date = week |> boundaries() |> List.last() |> DateTime.from_unix!() |> DateTime.to_date()
    day = Calendar.strftime(date, "%-d %b %Y")
    code = Calendar.strftime(date, "%m%d")

    [
      {"AMZNc After-hours to #{day}", "AMZNc-AH-#{code}"},
      {"AMZNc Market-hours to #{day}", "AMZNc-MH-#{code}"}
    ]
  end

  # One feed round a minute before every moment any week has a price for,
  # oldest first, then the latest.
  defp rounds(state) do
    priced =
      for {week, %{opened: true} = figures} <- state.weeks,
          {price, at} <- Enum.zip(figures.prices ++ figures.due, boundaries(week)),
          do: {at - 60, div(price, @feed_scale)}

    priced |> Enum.uniq_by(&elem(&1, 0)) |> Enum.sort() |> Kernel.++([state.latest])
  end

  defp round_at(state, at), do: Enum.find_index(state.rounds, &(elem(&1, 0) == at - 60)) + 1

  defp last([]), do: %{price: 0, night: 0}
  defp last(prices), do: prices |> Ledger.path() |> List.last()

  # A tuple's head of static words and offsets, then its dynamic parts.
  defp tuple(static, dynamic) do
    head = length(static) * 32 + length(dynamic) * 32

    {offsets, _end} =
      Enum.map_reduce(dynamic, head, fn part, at -> {<<at::256>>, at + byte_size(part)} end)

    IO.iodata_to_binary([Enum.map(static, &<<&1::256>>), offsets, dynamic])
  end

  defp array(values),
    do: IO.iodata_to_binary([<<length(values)::256>> | Enum.map(values, &<<&1::256>>)])

  defp string(text) do
    padding = rem(32 - rem(byte_size(text), 32), 32)
    <<byte_size(text)::256, text::binary, 0::size(padding)-unit(8)>>
  end

  defp address(prefix, week), do: "0x" <> prefix <> hex(week, 38)
  defp address(value), do: "0x" <> hex(value, 40)

  defp hex(value, digits),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(digits, "0")

  defp args(data) do
    for <<word::binary-size(64) <- String.slice(data, 10..-1//1)>>,
      do: String.to_integer(word, 16)
  end

  defp restore({key, nil}), do: Application.delete_env(:autolaunch, key)
  defp restore({key, value}), do: Application.put_env(:autolaunch, key, value)

  defp word("0x" <> hex), do: String.to_integer(hex, 16)
end
