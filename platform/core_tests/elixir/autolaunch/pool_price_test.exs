defmodule Autolaunch.PoolPriceTest do
  use ExUnit.Case, async: true

  alias Autolaunch.PoolPrice

  @q96 Integer.pow(2, 96)

  # sqrtPriceX96 = 2 * 2^96 prices currency1 at 4 base units per currency0 base unit.
  test "REGENT/SUBJECT (18/18): both currency orders are exact" do
    assert {:ok, %{value: "4", exact?: true}} =
             PoolPrice.currency_per_token(2 * @q96, true, 18, 18)

    assert {:ok, %{value: "0.25", exact?: true}} =
             PoolPrice.currency_per_token(2 * @q96, false, 18, 18)
  end

  # NEW (18) as currency0 at 2^91: (1/32)^2 = 1/1024 STOCK base units per NEW base
  # unit, which is 10^10 / 1024 = 9,765,625 AAPLc (8) per whole NEW. With AAPLc
  # as currency0 the pool has to be at 32 * 2^96 to name the same price.
  test "AAPLc/NEW (8/18): both currency orders are exact" do
    assert {:ok, %{value: "9765625", exact?: true}} =
             PoolPrice.currency_per_token(div(@q96, 32), true, 18, 8)

    assert {:ok, %{value: "9765625", exact?: true}} =
             PoolPrice.currency_per_token(32 * @q96, false, 18, 8)
  end

  test "a price that is not a finite decimal is truncated and marked" do
    assert {:ok, %{value: value, exact?: false}} =
             PoolPrice.currency_per_token(3 * @q96, false, 18, 18)

    assert String.starts_with?(value, "0.111111111111")
    assert String.ends_with?(value, "…")
  end

  test "a zero or oversized sqrt price is refused" do
    assert {:error, :invalid_sqrt_price} = PoolPrice.currency_per_token(0, true, 18, 18)

    assert {:error, :invalid_sqrt_price} =
             PoolPrice.currency_per_token(Integer.pow(2, 160), true, 18, 18)
  end
end
