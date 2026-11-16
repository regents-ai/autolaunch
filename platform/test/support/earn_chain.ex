defmodule Autolaunch.EarnChain do
  @moduledoc """
  Earn switched on for one test, on a chain double of Aave V3 on Base that
  answers every read at the latest block by the contract asked: the pool's
  `getReserveData`, `getReserveNormalizedIncome` and
  `getVirtualUnderlyingBalance` for USDC, the market token's totals and a
  wallet's balance in it, and USDC's balance and allowance for a wallet, each
  asked on its own or many at once through Multicall3's `aggregate3`. Every
  other request goes to `Autolaunch.BaseRpcStub`.

  `install/1` switches Earn on and puts the chain; `put/1` changes it
  mid-test (`unreadable: true` fails every contract read; `hold: pid` makes
  each reading of the reserve tell `pid` `{:earn_chain_held, reader}` and
  wait for `send(reader, :go)`). Both are undone when the test exits. Amounts
  are USDC's smallest units (6 decimals); `cap` is in whole tokens, 0 for
  none; `rate` and `index` are ray (10^27); `available` is the pool's virtual
  balance.
  """

  alias Autolaunch.BaseRpcStub
  alias RegentChain.Call

  @pool "0xa238dd80c259a72e81d7e4664a9801593f98d1c5"
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @a_token "0x4e65fe4dba92790696d040ac24aa414708f5c0ab"
  @ray 10 ** 27
  @unit 1_000_000
  # The latest block's time.
  @now 0x6A000000

  def pool, do: @pool
  def usdc, do: @usdc
  def a_token, do: @a_token
  def unit, do: @unit
  def now, do: @now
  def ray, do: @ray

  @doc "Switches Earn on for this test, on a chain answering `overrides` over the defaults."
  def install(overrides \\ %{}) do
    previous = Application.get_env(:autolaunch, :earn)
    Application.put_env(:autolaunch, :earn, :on)

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

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:autolaunch, :earn, previous),
        else: Application.delete_env(:autolaunch, :earn)

      Application.delete_env(:autolaunch, :earn_chain)
    end)

    :ok
  end

  @doc "The chain from now on: `overrides` over the defaults."
  def put(overrides) do
    state =
      Map.merge(
        %{
          active: true,
          frozen: false,
          paused: false,
          decimals: 6,
          cap: 0,
          # 4.68% a year.
          rate: 468 * div(@ray, 10_000),
          index: @ray,
          accrued: 0,
          supplied: 300_000_000 * @unit,
          scaled: 300_000_000 * @unit,
          available: 50_000_000 * @unit,
          hold: nil,
          balance: 0,
          usdc: 1_000 * @unit,
          allowance: 0
        },
        overrides
      )

    Application.put_env(:autolaunch, :earn_chain, state)
  end

  @doc """
  The reserve's configuration word as the pool keeps it: the given flags,
  decimals and supply cap, beside a loan-to-value and borrowing flag Earn
  does not read.
  """
  def config(state) do
    7_500 + Bitwise.bsl(state.decimals, 48) + Bitwise.bsl(bit(state.active), 56) +
      Bitwise.bsl(bit(state.frozen), 57) + Bitwise.bsl(1, 58) + Bitwise.bsl(bit(state.paused), 60) +
      Bitwise.bsl(state.cap, 116)
  end

  defp bit(true), do: 1
  defp bit(false), do: 0

  def post(url, options) do
    case options[:json] do
      %{method: "eth_call"} = call -> call(Application.fetch_env!(:autolaunch, :earn_chain), call)
      _other -> BaseRpcStub.post(url, options)
    end
  end

  # `unreadable: true` makes every contract read fail, as a chain that can't be reached just now.
  defp call(%{unreadable: true}, _call), do: {:ok, %{status: 503, body: ""}}

  defp call(_state, %{params: [%{to: to, data: data}, _block]}) do
    if String.downcase(to) == Autolaunch.Chain.Multicall.address(),
      do: {:ok, %{status: 200, body: %{"result" => BaseRpcStub.aggregate(data, &answer/2)}}},
      else: {:ok, %{status: 200, body: %{"result" => answer(to, data)}}}
  end

  @reads Map.new(
           ~w|getReserveData(address) getReserveNormalizedIncome(address)
              getVirtualUnderlyingBalance(address) totalSupply() scaledTotalSupply()
              balanceOf(address) allowance(address,address)|,
           &{Call.selector(&1), &1}
         )

  defp answer(to, data) do
    state = Application.fetch_env!(:autolaunch, :earn_chain)
    words = words(Map.fetch!(@reads, String.slice(data, 0, 10)), String.downcase(to), state)
    "0x" <> Enum.map_join(words, &BaseRpcStub.hex_word/1)
  end

  defp words("getReserveData(address)", @pool, state) do
    held(state.hold)

    [config(state), state.index, state.rate, @ray, 0, 0, @now, 4, word(@a_token)] ++
      [word("0x59dca05b6c26dbd64b5381374aaac5cd05644c28"), 0, 0, state.accrued, 0, 0]
  end

  defp words("getReserveNormalizedIncome(address)", @pool, state), do: [state.index]

  defp words("getVirtualUnderlyingBalance(address)", @pool, state),
    do: [state.available]

  defp words("totalSupply()", @a_token, state), do: [state.supplied]
  defp words("scaledTotalSupply()", @a_token, state), do: [state.scaled]
  defp words("balanceOf(address)", @a_token, state), do: [state.balance]

  defp words("balanceOf(address)", @usdc, state), do: [state.usdc]
  defp words("allowance(address,address)", @usdc, state), do: [state.allowance]

  defp held(nil), do: :ok

  defp held(test) do
    send(test, {:earn_chain_held, self()})

    receive do
      :go -> :ok
    end
  end

  defp word(address), do: address |> String.trim_leading("0x") |> String.to_integer(16)
end
