defmodule Autolaunch.ExposureChain do
  @moduledoc """
  Exposure switched on for one test, on a chain double that answers every read
  at the latest block by the contract asked: the series' terms and state, its
  two legs and stock, the oracle's recorded prints and the feed's rounds, the
  Aerodrome factory's pools and their quotes. Every other request goes to
  `Autolaunch.BaseRpcStub`.

  The default is the first AMZNc series on Monday 2 November 2026 at 11:00 New
  York time: the Friday close (250) and Monday's open (256) applied, minting
  open, 0.1 AMZNc deposited of a 0.4 cap, and pools for both legs.

  `install/1` switches Exposure on with a one-series description and puts the
  chain; `put/1` changes it mid-test (`unreadable: true` fails every contract
  read). Both are undone when the test exits.
  """

  alias Autolaunch.{BaseRpcStub, Lab}
  alias RegentChain.Call

  @series "0x77b82face369db560677a903b13e747891096cb7"
  @stock "0xb200000000000000000000d9192b6b456483c2e8"
  @overnight "0x0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a"
  @session "0x0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"
  @oracle "0x64b8404e979ec2791e68f55d959d011ea4eea88a"
  @feed "0x06a8e4b3abb3b7543d8396fb2b763d22820cb295"
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @factory "0x420dd381b31aef6683db6b902084cb0ffece40da"
  @router "0xcf77a3ba9a5ca399b7c97c74d54e5b1beb874e43"
  @overnight_pool "0x3333333333333333333333333333333333333333"
  @session_pool "0x4444444444444444444444444444444444444444"
  @feed_id "0xa4e7373e87b082c0fbf44cb5781e59e77a4636c518486646da1f6c1b3a1aab3c"
  @terms_hash "0x5f67343b39277939aea7613c578fa3931b8b89da7a65eb36dd7217c81a5a2e8f"
  @phase 2
  @wad 1_000_000_000_000_000_000
  @unit 100_000_000
  # Fri 30 Oct 16:00 New York, then each 9:30 open and 16:00 close to Fri 6 Nov.
  @boundaries [1_793_390_400] ++
                for(day <- 0..4, at <- [1_793_629_800, 1_793_653_200], do: at + day * 86_400)
  # Monday 2 November, 11:00 New York.
  @now 1_793_635_200

  def series, do: @series
  def stock, do: @stock
  def overnight, do: @overnight
  def session, do: @session
  def oracle, do: @oracle
  def feed, do: @feed
  def boundaries, do: @boundaries
  def terms_hash, do: @terms_hash
  def unit, do: @unit
  def wad, do: @wad
  def now, do: @now
  def phase, do: @phase

  @doc "Switches Exposure on for this test, on a chain answering `overrides` over the defaults."
  def install(overrides \\ %{}) do
    path = Path.join(System.tmp_dir!(), "exposure-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      Jason.encode!(%{
        chain_id: Lab.chain_id(),
        usdc: @usdc,
        pool_factory: @factory,
        router: @router,
        series: [@series]
      })
    )

    previous =
      for key <- [:exposure, :autolaunch_base_exposure_deployment],
          do: {key, Application.get_env(:autolaunch, key)}

    Application.put_env(:autolaunch, :exposure, :on)
    Application.put_env(:autolaunch, :autolaunch_base_exposure_deployment, path)

    BaseRpcStub.install(:autolaunch_lab_http_client, fn _data, _state -> "0x" end)
    Application.put_env(:autolaunch, :autolaunch_lab_http_client, __MODULE__)

    put(overrides)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(previous, &restore/1)
      Application.delete_env(:autolaunch, :exposure_chain)
      File.rm(path)
    end)

    :ok
  end

  @doc "The chain from now on: `overrides` over the defaults."
  def put(overrides) do
    state =
      Map.merge(
        %{
          now: @now,
          status: 1,
          end_reason: 0,
          # Close 250, open 256: After-hours 125 → 131, Market-hours 125.
          prices: [250 * @wad, 256 * @wad],
          deposit_cap: 40_000_000,
          accounted: 10_000_000,
          held: 10_000_000,
          supply: 10_000_000,
          max_report_delay: 7 * 86_400,
          wallet: %{
            stock: 50_000_000,
            allowance: 0,
            overnight: 0,
            session: 0,
            usdc: 0,
            usdc_allowance: 0,
            leg_allowance: 0
          },
          # Feed rounds of the pinned phase, oldest first: {updated_at, answer}.
          rounds: [
            {@now - 3 * 86_400, 25_000_000_000},
            {@now - 7_200, 25_600_000_000},
            {@now - 60, 25_700_000_000}
          ],
          recorded: %{},
          pools: %{
            @overnight => {@overnight_pool, 2_640_000},
            @session => {@session_pool, 2_510_000}
          }
        },
        Map.delete(overrides, :wallet)
      )

    # A wallet override names only the balances it changes.
    state = %{state | wallet: Map.merge(state.wallet, Map.get(overrides, :wallet, %{}))}

    Application.put_env(:autolaunch, :exposure_chain, state)
  end

  def post(url, options) do
    case options[:json] do
      %{method: "eth_call"} = call ->
        call(Application.fetch_env!(:autolaunch, :exposure_chain), call)

      %{method: "eth_getBlockByNumber"} ->
        state = Application.fetch_env!(:autolaunch, :exposure_chain)

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
    case answer(state, String.downcase(to), data) do
      :revert -> {:ok, %{status: 200, body: %{"error" => %{"message" => "execution reverted"}}}}
      hex -> {:ok, %{status: 200, body: %{"result" => hex}}}
    end
  end

  @reads ~w|asset() overnight() session() oracle() feedId() termsHash() maxReportDelay()
            depositCap() boundaryCount() boundaries(uint256) status() endReason() settled()
            lastPriceWad() overnightLedgerWad() accountedAssets() feed() phase()
            getPrint(bytes32,uint64,bool) sourceOf(uint64,bool) getRoundData(uint80)
            symbol() name() decimals() totalSupply() balanceOf(address)
            allowance(address,address) getPool(address,address,bool)
            getAmountOut(uint256,address) getReserves() latestRoundData()|
         |> Map.new(&{Call.selector(&1), &1})

  defp answer(state, to, data) do
    case words(Map.fetch!(@reads, String.slice(data, 0, 10)), to, state, args(data)) do
      :revert -> :revert
      {:string, text} -> "0x" <> string_words(text)
      words -> "0x" <> Enum.map_join(words, &BaseRpcStub.hex_word/1)
    end
  end

  defp words("asset()", @series, _state, _args), do: [word(@stock)]
  defp words("overnight()", @series, _state, _args), do: [word(@overnight)]
  defp words("session()", @series, _state, _args), do: [word(@session)]
  defp words("oracle()", @series, _state, _args), do: [word(@oracle)]
  defp words("feedId()", @series, _state, _args), do: [word(@feed_id)]
  defp words("termsHash()", @series, _state, _args), do: [word(@terms_hash)]
  defp words("maxReportDelay()", @series, state, _args), do: [state.max_report_delay]
  defp words("depositCap()", @series, state, _args), do: [state.deposit_cap]
  defp words("boundaryCount()", @series, _state, _args), do: [length(@boundaries)]
  defp words("boundaries(uint256)", @series, _state, [index]), do: [Enum.at(@boundaries, index)]
  defp words("status()", @series, state, _args), do: [state.status]
  defp words("endReason()", @series, state, _args), do: [state.end_reason]
  defp words("settled()", @series, state, _args), do: [length(state.prices)]
  defp words("lastPriceWad()", @series, state, _args), do: [last(state).price]
  defp words("overnightLedgerWad()", @series, state, _args), do: [last(state).night]
  defp words("accountedAssets()", @series, state, _args), do: [state.accounted]

  defp words("feed()", @oracle, _state, _args), do: [word(@feed)]
  defp words("phase()", @oracle, _state, _args), do: [@phase]

  # A print is recorded for every applied price, and for any price in `recorded`.
  defp words("getPrint(bytes32,uint64,bool)", @oracle, state, [_feed_id, at, _open]) do
    case print(state, at) do
      nil -> [0, 0, 0]
      price -> [price, at, at + 3_600]
    end
  end

  defp words("sourceOf(uint64,bool)", @oracle, state, [at, _open]) do
    if print(state, at), do: [Bitwise.bsl(@phase, 64) + 1, at - 60], else: [0, 0]
  end

  defp words("latestRoundData()", @feed, state, _args) do
    round_id = Bitwise.bsl(@phase, 64) + length(state.rounds)
    {updated_at, answer} = List.last(state.rounds)
    [round_id, answer, updated_at, updated_at, round_id]
  end

  defp words("getRoundData(uint80)", @feed, state, [round_id]) do
    round = round_id - Bitwise.bsl(@phase, 64)

    case round >= 1 && Enum.at(state.rounds, round - 1) do
      {updated_at, answer} -> [round_id, answer, updated_at, updated_at, round_id]
      _missing -> [0, 0, 0, 0, 0]
    end
  end

  defp words("symbol()", to, _state, _args), do: {:string, token(to).symbol}
  defp words("name()", to, _state, _args), do: {:string, token(to).name}
  defp words("decimals()", _to, _state, _args), do: [8]
  defp words("totalSupply()", _leg, state, _args), do: [state.supply]

  defp words("balanceOf(address)", @stock, state, [holder]) do
    if holder == word(@series), do: [state.held], else: [state.wallet.stock]
  end

  defp words("balanceOf(address)", @overnight, state, _args), do: [state.wallet.overnight]
  defp words("balanceOf(address)", @session, state, _args), do: [state.wallet.session]
  defp words("allowance(address,address)", @stock, state, _args), do: [state.wallet.allowance]
  defp words("balanceOf(address)", @usdc, state, _args), do: [state.wallet.usdc]

  defp words("allowance(address,address)", @usdc, state, _args),
    do: [state.wallet.usdc_allowance]

  defp words("allowance(address,address)", leg, state, _args) when leg in [@overnight, @session],
    do: [state.wallet.leg_allowance]

  # A pool with a quote holds one whole leg token and that much USDC, in
  # Aerodrome's address order; one without holds nothing.
  defp words("getReserves()", pool, state, _args) do
    case Enum.find(state.pools, fn {_leg, {address, _quote}} -> address == pool end) do
      {_leg, {_pool, nil}} -> [0, 0, 0]
      {leg, {_pool, quote}} when leg < @usdc -> [@unit, quote, 0]
      {_leg, {_pool, quote}} -> [quote, @unit, 0]
    end
  end

  defp words("getPool(address,address,bool)", @factory, state, [token, _usdc, _stable]) do
    case Enum.find(state.pools, fn {leg, _pool} -> word(leg) == token end) do
      {_leg, {pool, _quote}} -> [word(pool)]
      nil -> [0]
    end
  end

  defp words("getAmountOut(uint256,address)", pool, state, _args) do
    case Enum.find(state.pools, fn {_leg, {address, _quote}} -> address == pool end) do
      # An empty Aerodrome pool quotes zero rather than reverting.
      {_leg, {_pool, nil}} -> [0]
      {_leg, {_pool, quote}} -> [quote]
    end
  end

  defp last(%{prices: []}), do: %{price: 0, night: 0}
  defp last(%{prices: prices}), do: prices |> Autolaunch.Exposure.Ledger.path() |> List.last()

  defp print(state, at) do
    index = Enum.find_index(@boundaries, &(&1 == at))
    Enum.at(state.prices, index) || Map.get(state.recorded, at)
  end

  defp token(@stock), do: %{symbol: "AMZNc", name: "Amazon"}
  defp token(@overnight), do: %{symbol: "AMZNc-AH-1106", name: "AMZNc After-hours to 6 Nov 2026"}
  defp token(@session), do: %{symbol: "AMZNc-MH-1106", name: "AMZNc Market-hours to 6 Nov 2026"}

  defp args(data) do
    for <<word::binary-size(64) <- String.slice(data, 10..-1//1)>>,
      do: String.to_integer(word, 16)
  end

  defp string_words(text) do
    padded = text <> :binary.copy(<<0>>, rem(32 - rem(byte_size(text), 32), 32))

    BaseRpcStub.hex_word(32) <>
      BaseRpcStub.hex_word(byte_size(text)) <> Base.encode16(padded, case: :lower)
  end

  defp restore({key, nil}), do: Application.delete_env(:autolaunch, key)
  defp restore({key, value}), do: Application.put_env(:autolaunch, key, value)

  defp word("0x" <> hex), do: String.to_integer(hex, 16)
end
