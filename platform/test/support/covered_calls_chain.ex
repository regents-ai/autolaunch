defmodule Autolaunch.CoveredCallsChain do
  @moduledoc """
  Covered calls switched on for one test, on a chain double that answers every
  read at the latest block by the contract asked: the covered-call contract's
  listings, bids, holdings and terms, the stock's balance, allowance, multiplier and
  scheduled change, USDC's balance and allowance, and the reference feed and its
  past rounds, each asked on its own or many at once through Multicall3's
  `aggregate3`. Every other request goes to `Autolaunch.BaseRpcStub`.

  `install/1` switches covered calls on with a one-market settings file and puts
  the chain; `put/1` changes it mid-test (`unreadable: true` fails every contract
  read; `silent: true` makes the covered-call contract answer nothing, as an
  address with no contract does; `hold: pid` stops each read until `pid` lets
  it go). Both are undone when the test exits.

  `requests/0` is how many `eth_call` requests the chain has answered since
  `install/1`, so a test can tell reads sent together from reads sent one by one.
  """

  alias Autolaunch.{BaseRpcStub, Lab}
  alias RegentChain.Call

  @stock "0xb200000000000000000000d9192b6b456483c2e8"
  @contract "0x36d04f63c812dc945efd23eb7b6dcae1cdd08398"
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @feed "0x06a8e4b3abb3b7543d8396fb2b763d22820cb295"
  @multicall Autolaunch.Chain.Multicall.address()
  @unit 100_000_000
  # The latest block's time, a Wednesday.
  @now 0x6A000000

  def stock, do: @stock
  def contract, do: @contract
  def usdc, do: @usdc
  def unit, do: @unit
  def now, do: @now

  @doc "Switches covered calls on for this test, on a chain answering `overrides` over the defaults."
  def install(overrides \\ %{}) do
    path =
      Path.join(System.tmp_dir!(), "covered-calls-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      Jason.encode!(%{
        chain_id: Lab.chain_id(),
        markets: [%{symbol: "AMZNc", stock: @stock, contract: @contract, feed: @feed}]
      })
    )

    previous =
      for key <- [:covered_calls, :autolaunch_base_covered_calls_deployment],
          do: {key, Application.get_env(:autolaunch, key)}

    Application.put_env(:autolaunch, :covered_calls, :on)
    Application.put_env(:autolaunch, :autolaunch_base_covered_calls_deployment, path)

    BaseRpcStub.install(:autolaunch_lab_http_client, fn _call, _state -> "0x" end)
    Application.put_env(:autolaunch, :autolaunch_lab_http_client, __MODULE__)

    BaseRpcStub.put(%{
      blocks: %{
        "latest" => %{
          "number" => "0x20",
          "hash" => BaseRpcStub.safe_hash(),
          "timestamp" => "0x" <> Integer.to_string(@now, 16)
        }
      }
    })

    put(overrides)
    Application.put_env(:autolaunch, :covered_calls_chain_requests, :counters.new(1, []))

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(previous, &restore/1)
      Application.delete_env(:autolaunch, :covered_calls_chain)
      Application.delete_env(:autolaunch, :covered_calls_chain_requests)
      File.rm(path)
    end)

    :ok
  end

  @doc "The chain from now on: `overrides` over the defaults."
  def put(overrides) do
    state =
      Map.merge(
        %{
          balance: 10 * @unit,
          allowance: 0,
          usdc_balance: 1_000_000_000,
          usdc_allowance: 0,
          effective_at: 0,
          multiplier: 1_000_000_000_000_000_000,
          held: 0,
          claimable: 0,
          price: 25_400_000_000,
          price_at: @now,
          # The feed's rounds before its latest, oldest first: {updated_at, answer}.
          history: [],
          listings: [listing(%{})],
          bids: []
        },
        overrides
      )

    Application.put_env(:autolaunch, :covered_calls_chain, state)
  end

  @doc "One listing as the contract holds it, `overrides` over a 10-token listing with 4 sold."
  def listing(overrides) do
    Map.merge(
      %{
        seller: "0x2222222222222222222222222222222222222222",
        expiry: hd(Autolaunch.CoveredCalls.Terms.expiries(@now)),
        returned: 0,
        amount: 10 * @unit,
        filled: 4 * @unit,
        exercised: 0,
        strike: 260_000_000,
        premium: 3_000_000,
        paid: 0,
        collected: 0
      },
      overrides
    )
  end

  @doc """
  One bid as the contract holds it, `overrides` over a 10-token bid with 4 sold
  into it; `refundable` is what the contract's `refundable` view answers for it.
  """
  def bid(overrides) do
    Map.merge(
      %{
        bidder: "0x3333333333333333333333333333333333333333",
        expiry: hd(Autolaunch.CoveredCalls.Terms.expiries(@now)),
        amount: 10 * @unit,
        filled: 4 * @unit,
        strike: 260_000_000,
        premium: 3_000_000,
        min_sale: @unit,
        refund_due: 0,
        refundable: 0
      },
      overrides
    )
  end

  @doc "How many `eth_call` requests the chain has answered since `install/1`."
  def requests,
    do: :counters.get(Application.fetch_env!(:autolaunch, :covered_calls_chain_requests), 1)

  def post(url, options) do
    case options[:json] do
      %{method: "eth_call"} = call ->
        :counters.add(Application.fetch_env!(:autolaunch, :covered_calls_chain_requests), 1, 1)
        state = Application.fetch_env!(:autolaunch, :covered_calls_chain)
        hold(state[:hold])
        call(state, call)

      _other ->
        BaseRpcStub.post(url, options)
    end
  end

  # `hold: pid` stops a read until `pid` lets it go: `pid` is sent
  # `{:held, reader}` and answers `reader` with `:go`.
  defp hold(nil), do: :ok

  defp hold(pid) do
    send(pid, {:held, self()})

    receive do
      :go -> :ok
    after
      5_000 -> :ok
    end
  end

  # `unreadable: true` makes every contract read fail, as a chain that can't be reached just now.
  defp call(%{unreadable: true}, _call), do: {:ok, %{status: 503, body: ""}}

  # Multicall3's `aggregate3`: every read in the request answered as it would
  # be on its own.
  defp call(_state, %{params: [%{to: @multicall, data: data}, _block]}),
    do: {:ok, %{status: 200, body: %{"result" => BaseRpcStub.aggregate(data, &answer/2)}}}

  defp call(_state, %{params: [%{to: to, data: data}, _block]}) do
    case answer(String.downcase(to), data) do
      :reverted ->
        {:ok,
         %{
           status: 200,
           body: %{"error" => %{"code" => 3, "message" => "execution reverted"}}
         }}

      result ->
        {:ok, %{status: 200, body: %{"result" => result}}}
    end
  end

  @reads Map.new(
           ~w|listingCount() listings(uint256) bidCount() bids(uint256) refundable(uint256)
              unit() usdc() multiplier() effectiveAt()
              held(uint256,address) claimable(uint256,address) latestRoundData()
              getRoundData(uint80) balanceOf(address) allowance(address,address) decimals()|,
           &{Call.selector(&1), &1}
         )

  defp answer(to, data) do
    state = Application.fetch_env!(:autolaunch, :covered_calls_chain)

    if to == @contract and state[:silent], do: "0x", else: answered(state, to, data)
  end

  defp answered(state, to, data) do
    case words(Map.fetch!(@reads, String.slice(data, 0, 10)), to, state, data) do
      :reverted -> :reverted
      words -> "0x" <> Enum.map_join(words, &BaseRpcStub.hex_word/1)
    end
  end

  defp words("listingCount()", _to, state, _data), do: [length(state.listings)]
  defp words("listings(uint256)", _to, state, data), do: listing_words(state, data)
  defp words("bidCount()", _to, state, _data), do: [length(state.bids)]

  defp words("bids(uint256)", _to, state, data) do
    with %{} = b <- numbered(state.bids, data) do
      [word(b.bidder), b.expiry, b.amount, b.filled, b.strike, b.premium, b.min_sale] ++
        [b.refund_due]
    end
  end

  defp words("refundable(uint256)", _to, state, data) do
    with %{} = b <- numbered(state.bids, data), do: [b.refundable]
  end

  defp words("unit()", _to, _state, _data), do: [@unit]
  defp words("usdc()", _to, _state, _data), do: [word(@usdc)]
  defp words("multiplier()", _to, state, _data), do: [state.multiplier]
  defp words("effectiveAt()", _to, state, _data), do: [state.effective_at]
  defp words("held(uint256,address)", _to, state, _data), do: [state.held]
  defp words("claimable(uint256,address)", _to, state, _data), do: [state.claimable]
  # The feed's latest round comes after its history; rounds count from 1.
  defp words("latestRoundData()", _to, state, _data) do
    round = length(state.history) + 1
    [round, state.price, state.price_at, state.price_at, round]
  end

  defp words("getRoundData(uint80)", _to, state, data) do
    round = data |> String.slice(10, 64) |> String.to_integer(16)

    case round >= 1 && Enum.at(state.history, round - 1) do
      {at, answer} -> [round, answer, at, at, round]
      _missing -> [0, 0, 0, 0, 0]
    end
  end

  defp words("decimals()", @feed, _state, _data), do: [8]
  defp words("balanceOf(address)", @usdc, state, _data), do: [state.usdc_balance]
  defp words("balanceOf(address)", _stock, state, _data), do: [state.balance]
  defp words("allowance(address,address)", @usdc, state, _data), do: [state.usdc_allowance]
  defp words("allowance(address,address)", _stock, state, _data), do: [state.allowance]

  defp listing_words(state, data) do
    with %{} = l <- numbered(state.listings, data) do
      [word(l.seller), l.expiry, l.returned, l.amount, l.filled, l.exercised] ++
        [l.strike, l.premium, l.paid, l.collected]
    end
  end

  # Listing and bid ids count from 1; the contract refuses any other
  # (`UnknownListing`, `UnknownBid`).
  defp numbered(records, data) do
    id = data |> String.slice(10, 64) |> String.to_integer(16)

    case id >= 1 && Enum.at(records, id - 1) do
      falsy when falsy in [nil, false] -> :reverted
      record -> record
    end
  end

  defp restore({key, nil}), do: Application.delete_env(:autolaunch, key)
  defp restore({key, value}), do: Application.put_env(:autolaunch, key, value)

  defp word(address), do: address |> String.trim_leading("0x") |> String.to_integer(16)
end
