defmodule Autolaunch.BidPriceTest do
  use ExUnit.Case, async: true

  alias Autolaunch.{BidActions, BidPrice}
  @q96 Integer.pow(2, 96)
  @maximum Integer.pow(2, 256) - 1

  test "effective prices are exact rationals and round-trip independently of Decimal context" do
    Decimal.Context.with(%Decimal.Context{precision: 3}, fn ->
      for price <- [
            1,
            @q96,
            div(@q96, 2),
            316_912_650_057_057_350_374_175_600,
            158_456_325_028_528_675_187_087_800,
            @maximum
          ] do
        text = BidPrice.decimal(price)
        [whole | fraction] = String.split(text, ".")
        fraction = List.first(fraction) || ""

        assert String.to_integer(whole <> fraction) * @q96 ==
                 price * Integer.pow(10, byte_size(fraction))

        assert {:ok, ^price} = BidActions.price_q96(text)
        assert byte_size(text) <= 146
      end

      assert BidPrice.decimal(0) == "0"
      assert BidPrice.decimal(@q96) == "1"
      assert BidPrice.decimal(div(@q96, 2)) == "0.5"
      assert byte_size(BidPrice.decimal(@maximum)) == 146
      assert Decimal.Context.get().precision == 3
    end)
  end

  test "renderer refuses values outside its bounded unsigned integer domain" do
    for invalid <- [-1, @maximum + 1, 1.0, "1", nil] do
      assert_raise FunctionClauseError, fn -> BidPrice.decimal(invalid) end
    end
  end
end
