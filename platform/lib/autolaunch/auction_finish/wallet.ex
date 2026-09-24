defmodule Autolaunch.AuctionFinish.Wallet do
  @moduledoc """
  The finishing wallet's key and the address it sends from.

  It signs one shape of transaction: an EIP-1559 (type 2) call that sends no
  ETH and carries no access list. Inspecting a wallet shows its address and
  never its key.
  """

  @derive {Inspect, only: [:address]}
  @enforce_keys [:address, :private_key]
  defstruct [:address, :private_key]

  # The order of the secp256k1 group: a private key is a number from 1 below it.
  @curve_order 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

  @doc "The wallet the running site finishes auctions from."
  def configured! do
    {:ok, wallet} = new(Application.fetch_env!(:autolaunch, :auction_finisher_key))
    wallet
  end

  @doc """
  The wallet for a private key given as `0x` and 64 hex digits, or
  `{:error, :malformed_key}` for anything else.
  """
  def new(key) do
    with {:ok, private_key} <- private_key(key),
         {:ok, <<4, public_key::binary-size(64)>>} <-
           ExSecp256k1.create_public_key(private_key) do
      {:ok, %__MODULE__{address: address(public_key), private_key: private_key}}
    else
      _malformed -> {:error, :malformed_key}
    end
  end

  @doc """
  The 32 bytes of a private key given as `new/1` takes it, or `:error`,
  including for zero and numbers not below the curve order.
  """
  def private_key("0x" <> hex) when byte_size(hex) == 64 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<number::256>> = private_key} when number > 0 and number < @curve_order ->
        {:ok, private_key}

      _malformed ->
        :error
    end
  end

  def private_key(_value), do: :error

  @doc """
  Signs a call and returns `{raw, hash}`, both `0x` hex: the raw transaction
  for `eth_sendRawTransaction` and its hash.
  """
  def sign(%__MODULE__{private_key: private_key}, %{
        chain_id: chain_id,
        nonce: nonce,
        max_priority_fee: max_priority_fee,
        max_fee: max_fee,
        gas_limit: gas_limit,
        to: to,
        data: data
      }) do
    fields = [
      chain_id,
      nonce,
      max_priority_fee,
      max_fee,
      gas_limit,
      bytes(to),
      0,
      bytes(data),
      []
    ]

    digest = keccak(<<2>> <> rlp(fields))
    {:ok, {<<r::256, s::256>>, y_parity}} = ExSecp256k1.sign_compact(digest, private_key)
    raw = <<2>> <> rlp(fields ++ [y_parity, r, s])
    {hex(raw), hex(keccak(raw))}
  end

  defp address(public_key) do
    <<_::binary-size(12), address::binary-size(20)>> = keccak(public_key)
    hex(address)
  end

  defp bytes("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
  defp keccak(bytes), do: :jose_jwa_sha3.keccak(1088, 512, bytes, 1, 32)

  # Recursive-length-prefix encoding: a binary, a non-negative integer
  # (big-endian with no leading zeros, so 0 is the empty string) or a list.
  defp rlp(item) when is_binary(item), do: rlp_bytes(item)
  defp rlp(0), do: rlp_bytes(<<>>)
  defp rlp(item) when is_integer(item) and item > 0, do: rlp_bytes(:binary.encode_unsigned(item))

  defp rlp(items) when is_list(items) do
    payload = IO.iodata_to_binary(Enum.map(items, &rlp/1))
    rlp_prefix(0xC0, payload) <> payload
  end

  defp rlp_bytes(<<byte>>) when byte < 0x80, do: <<byte>>
  defp rlp_bytes(bytes), do: rlp_prefix(0x80, bytes) <> bytes

  defp rlp_prefix(offset, payload) when byte_size(payload) < 56,
    do: <<offset + byte_size(payload)>>

  defp rlp_prefix(offset, payload) do
    length = :binary.encode_unsigned(byte_size(payload))
    <<offset + 55 + byte_size(length)>> <> length
  end
end
