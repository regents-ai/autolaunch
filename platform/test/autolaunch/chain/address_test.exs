defmodule Autolaunch.Chain.AddressTest do
  @moduledoc """
  What the one semantic EVM address boundary decides.

  The checksum vectors are the published EIP-55 ones, so the Keccak-256 behind
  them is proven against the standard rather than against itself.
  """

  use ExUnit.Case, async: true

  alias Autolaunch.Chain.{Abi, Address}

  # The published EIP-55 test vectors.
  @checksummed [
    "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
    "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
    "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
    "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb",
    "0x52908400098527886E0F7030069857D2E4169EE7",
    "0x8617E340B3D01FA5F11F306F4090FD50E238070D",
    "0xde709f2102306220921060314715629080e2fb77",
    "0x27b1fdb04752bbc536007a920d24acb045561c26"
  ]

  test "SEMANTIC_EVM_ADDRESS: every published EIP-55 vector round-trips through decode and format" do
    for address <- @checksummed do
      assert {:ok, decoded} = Address.decode(address)
      assert byte_size(decoded) == 20
      assert Address.format(decoded) == address
      assert Address.canonical(decoded) == String.downcase(address)
    end
  end

  test "SEMANTIC_EVM_ADDRESS: an invalid mixed-case checksum is refused while single-case hex is not" do
    lowercase = "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed"
    uppercase = "0x" <> String.upcase("5aaeb6053f3e94c9b9a09f33669435e7ef1beaed")

    # Neither single-case form asserts a checksum, so neither can fail one.
    assert {:ok, decoded} = Address.decode(lowercase)
    assert Address.decode(uppercase) == {:ok, decoded}

    # One transposed case bit is a broken checksum and is refused.
    assert Address.decode("0x5AAeb6053F3E94C9b9A09f33669435E7Ef1BeAed") == :error
    assert Address.decode("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeD") == :error
  end

  test "SEMANTIC_EVM_ADDRESS: zero, wrong length and malformed hex are refused" do
    assert Address.decode("0x0000000000000000000000000000000000000000") == :error
    assert Address.decode("0x5aaeb6053f3e94c9b9a09f33669435e7ef1beae") == :error
    assert Address.decode("0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaedd") == :error
    assert Address.decode("5aaeb6053f3e94c9b9a09f33669435e7ef1beaed") == :error
    assert Address.decode("0x5aaeb6053f3e94c9b9a09f33669435e7ef1beazz") == :error
    assert Address.decode(" 0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed") == :error
    assert Address.decode(nil) == :error
    assert Address.decode(:not_an_address) == :error
  end

  test "SEMANTIC_EVM_ADDRESS: comparison is on decoded bytes rather than display strings" do
    checksummed = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
    lowercase = String.downcase(checksummed)

    assert Address.equal?(checksummed, lowercase)
    assert Address.equal?(lowercase, "0x" <> String.upcase(String.trim_leading(lowercase, "0x")))
    refute Address.equal?(checksummed, "0x27b1fdb04752bbc536007a920d24acb045561c26")

    # Anything that is not one address compares equal to nothing, including itself.
    refute Address.equal?("0xnope", "0xnope")
    refute Address.equal?(nil, nil)
  end

  test "SEMANTIC_EVM_ADDRESS: envelope and RPC values are the lowercase canonical form" do
    assert Address.normalize("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed") ==
             {:ok, "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed"}

    assert Address.normalize("0x5AAeb6053F3E94C9b9A09f33669435E7Ef1BeAed") == :error
  end

  test "SEMANTIC_EVM_ADDRESS: Abi delegates its address handling to the one boundary" do
    assert Abi.normalize_address!("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed") ==
             "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed"

    assert_raise ArgumentError, fn ->
      Abi.normalize_address!("0x5AAeb6053F3E94C9b9A09f33669435E7Ef1BeAed")
    end

    assert_raise ArgumentError, fn ->
      Abi.normalize_address!("0x0000000000000000000000000000000000000000")
    end

    # The manifest addresses this build signs against are all valid input.
    for address <- [Abi.regent_address(), Abi.usdc_address()] do
      assert {:ok, _decoded} = Address.decode(address)
    end
  end
end
