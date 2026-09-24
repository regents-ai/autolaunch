defmodule Autolaunch.TokenTradesTest do
  use ExUnit.Case, async: true

  alias Autolaunch.TokenTrades

  # Captured from a Uniswap v4 PoolManager on a local chain. The swapper paid
  # exactly 1 currency0 in and took about 0.996 currency1 out, so the event's
  # amount0 is negative and amount1 positive.
  @swap %{
    "data" =>
      "0xfffffffffffffffffffffffffffffffffffffffffffffffff21f494c589c0000" <>
        "0000000000000000000000000000000000000000000000000dd287127ab151f0" <>
        "0000000000000000000000000000000000000000ffbeb9c6970024779a0a218f" <>
        "00000000000000000000000000000000000000000000003635c9adc5dea00000" <>
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffec" <>
        "0000000000000000000000000000000000000000000000000000000000000bb8"
  }

  test "the token coming out of the pool is a buy, going in is a sell" do
    assert {:ok,
            %{side: :buy, token: 996_006_981_039_903_216, currency: 1_000_000_000_000_000_000}} =
             TokenTrades.decode_swap(@swap, false)

    assert {:ok,
            %{side: :sell, token: 1_000_000_000_000_000_000, currency: 996_006_981_039_903_216}} =
             TokenTrades.decode_swap(@swap, true)
  end
end
