defmodule Autolaunch.RegentFactsTest do
  use ExUnit.Case, async: false

  alias Autolaunch.BaseRpcStub, as: Stub
  alias Autolaunch.Chain.Abi
  alias Autolaunch.RegentFacts

  @name "0x06fdde03"
  @symbol "0x95d89b41"
  @decimals "0x313ce567"
  @total_supply "0x18160ddd"
  @stake_token "0x51ed6a30"
  @total_staked "0x817b1cd2"
  @wei_million 1_000_000 * Integer.pow(10, 18)
  @wei_quarter 250_000 * Integer.pow(10, 18)
  @other_token "0x1111111111111111111111111111111111111111"

  test "reads every fact at the same safe block" do
    Stub.install(:wallet_http_client, &happy_calls/2)

    assert {:ok, facts} = RegentFacts.read()

    assert facts.block_number == 0x20
    assert facts.block_hash == Stub.safe_hash()
    assert facts.name == "Regent"
    assert facts.symbol == "REGENT"
    assert facts.address == Abi.regent_address()
    assert facts.decimals == 18
    assert facts.total_supply == "1000000"
    assert facts.total_staked == "250000"

    blocks = Stub.call_blocks()
    assert length(blocks) == 6

    assert Enum.all?(blocks, fn block ->
             block == %{blockHash: Stub.safe_hash(), requireCanonical: true}
           end)
  end

  test "a stake token that is not REGENT is a mismatch" do
    Stub.install(:wallet_http_client, fn data, state ->
      if data == @stake_token do
        "0x" <> Stub.address_word(@other_token)
      else
        happy_calls(data, state)
      end
    end)

    assert {:error, :stake_token_mismatch} = RegentFacts.read()
  end

  test "a malformed string result is invalid" do
    Stub.install(:wallet_http_client, fn data, state ->
      if data == @name, do: "0x01", else: happy_calls(data, state)
    end)

    assert {:error, :invalid_chain_response} = RegentFacts.read()
  end

  test "an unavailable chain is an error" do
    previous = Application.get_env(:autolaunch, :wallet_http_client)
    Application.put_env(:autolaunch, :wallet_http_client, Stub.Timeout)
    on_exit(fn -> restore(:wallet_http_client, previous) end)

    assert {:error, :chain_unavailable} = RegentFacts.read()
  end

  defp happy_calls(data, _state) do
    case data do
      @name -> abi_string("Regent")
      @symbol -> abi_string("REGENT")
      @decimals -> Stub.uint(18)
      @total_supply -> Stub.uint(@wei_million)
      @stake_token -> "0x" <> Stub.address_word(Abi.regent_address())
      @total_staked -> Stub.uint(@wei_quarter)
    end
  end

  defp abi_string(text) do
    length = byte_size(text)
    pad = rem(32 - rem(length, 32), 32)
    padded = text <> :binary.copy(<<0>>, pad)

    "0x" <> Stub.hex_word(32) <> Stub.hex_word(length) <> Base.encode16(padded, case: :lower)
  end

  defp restore(key, nil), do: Application.delete_env(:autolaunch, key)
  defp restore(key, value), do: Application.put_env(:autolaunch, key, value)
end
