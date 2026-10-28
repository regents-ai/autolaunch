defmodule Autolaunch.CoveredCallsChain do
  @moduledoc """
  Covered calls switched on for one test, on a chain double that answers every
  read at the latest block by the contract asked: the covered-call contract's
  listing, holdings and terms, the stock's balance, allowance, multiplier and
  scheduled change, USDC's balance and allowance, and the reference feed. Every
  other request goes to `Autolaunch.BaseRpcStub`.

  `install/1` switches covered calls on with a one-market settings file and puts
  the chain; `put/1` changes it mid-test (`unreadable: true` fails every contract
  read). Both are undone when the test exits.
  """

  alias Autolaunch.{BaseRpcStub, Lab}
  alias RegentChain.Call

  @stock "0xb200000000000000000000d9192b6b456483c2e8"
  @contract "0x36d04f63c812dc945efd23eb7b6dcae1cdd08398"
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @feed "0x06a8e4b3abb3b7543d8396fb2b763d22820cb295"
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

    BaseRpcStub.install(:autolaunch_lab_http_client, fn _data, _state -> "0x" end)
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

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(previous, &restore/1)
      Application.delete_env(:autolaunch, :covered_calls_chain)
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
          listings: [listing(%{})]
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

  def post(url, options) do
    case options[:json] do
      %{method: "eth_call"} = call ->
        call(Application.fetch_env!(:autolaunch, :covered_calls_chain), call)

      _other ->
        BaseRpcStub.post(url, options)
    end
  end

  # `unreadable: true` makes every contract read fail, as a chain that can't be reached just now.
  defp call(%{unreadable: true}, _call), do: {:ok, %{status: 503, body: ""}}

  defp call(_state, %{params: [%{to: to, data: data}, _block]}),
    do: {:ok, %{status: 200, body: %{"result" => answer(String.downcase(to), data)}}}

  @reads Map.new(
           ~w|listingCount() listings(uint256) unit() usdc() multiplier() effectiveAt()
              held(uint256,address) claimable(uint256,address) latestRoundData()
              balanceOf(address) allowance(address,address)|,
           &{Call.selector(&1), &1}
         )

  defp answer(to, data) do
    state = Application.fetch_env!(:autolaunch, :covered_calls_chain)
    words = words(Map.fetch!(@reads, String.slice(data, 0, 10)), to, state, data)
    "0x" <> Enum.map_join(words, &BaseRpcStub.hex_word/1)
  end

  defp words("listingCount()", _to, state, _data), do: [length(state.listings)]
  defp words("listings(uint256)", _to, state, data), do: listing_words(state, data)
  defp words("unit()", _to, _state, _data), do: [@unit]
  defp words("usdc()", _to, _state, _data), do: [word(@usdc)]
  defp words("multiplier()", _to, state, _data), do: [state.multiplier]
  defp words("effectiveAt()", _to, state, _data), do: [state.effective_at]
  defp words("held(uint256,address)", _to, state, _data), do: [state.held]
  defp words("claimable(uint256,address)", _to, state, _data), do: [state.claimable]
  defp words("latestRoundData()", _to, state, _data), do: [1, state.price, @now, @now, 1]
  defp words("balanceOf(address)", @usdc, state, _data), do: [state.usdc_balance]
  defp words("balanceOf(address)", _stock, state, _data), do: [state.balance]
  defp words("allowance(address,address)", @usdc, state, _data), do: [state.usdc_allowance]
  defp words("allowance(address,address)", _stock, state, _data), do: [state.allowance]

  # Listing ids count from 1; an id past the last one is the contract's empty listing.
  defp listing_words(state, data) do
    id = data |> String.slice(10, 64) |> String.to_integer(16)

    case id >= 1 && Enum.at(state.listings, id - 1) do
      falsy when falsy in [nil, false] ->
        List.duplicate(0, 10)

      l ->
        [word(l.seller), l.expiry, l.returned, l.amount, l.filled, l.exercised] ++
          [l.strike, l.premium, l.paid, l.collected]
    end
  end

  defp restore({key, nil}), do: Application.delete_env(:autolaunch, key)
  defp restore({key, value}), do: Application.put_env(:autolaunch, key, value)

  defp word(address), do: address |> String.trim_leading("0x") |> String.to_integer(16)
end
