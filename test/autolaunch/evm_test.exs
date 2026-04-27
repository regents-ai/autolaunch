defmodule Autolaunch.EvmTest do
  use ExUnit.Case, async: true

  alias Autolaunch.Evm

  describe "normalize_address/1" do
    test "normalizes valid addresses" do
      assert Evm.normalize_address("  0xABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD  ") ==
               "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
    end

    test "rejects non-address values" do
      assert Evm.normalize_address("0x123") == nil
      assert Evm.normalize_address(nil) == nil
    end
  end

  describe "normalize_required_address/1" do
    test "returns tagged tuples" do
      assert Evm.normalize_required_address("0x1111111111111111111111111111111111111111") ==
               {:ok, "0x1111111111111111111111111111111111111111"}

      assert Evm.normalize_required_address("bad") == {:error, :invalid_address}
    end
  end

  describe "normalize_address_list/1" do
    test "normalizes and deduplicates addresses" do
      assert Evm.normalize_address_list([
               "0x1111111111111111111111111111111111111111",
               "0x2222222222222222222222222222222222222222",
               "0x1111111111111111111111111111111111111111"
             ]) ==
               {:ok,
                [
                  "0x1111111111111111111111111111111111111111",
                  "0x2222222222222222222222222222222222222222"
                ]}
    end

    test "rejects invalid list members" do
      assert Evm.normalize_address_list(["0x1111111111111111111111111111111111111111", "bad"]) ==
               {:error, :invalid_address}
    end
  end
end
