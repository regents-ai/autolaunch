defmodule Autolaunch.Chain.Address do
  @moduledoc """
  The one semantic EVM address boundary: twenty decoded bytes, not a display string.

  Mixed-case hex is an EIP-55 checksum and is verified as one, so a transposed or
  mistyped address fails here rather than reaching a wallet. All-lowercase and
  all-uppercase hex assert no checksum and stay valid unchecksummed input.

  Envelopes and RPC parameters carry `canonical/1`, comparisons use the decoded
  bytes through `equal?/2`, and `format/1` exists only for display.
  """

  @bytes 20
  @zero <<0::size(@bytes)-unit(8)>>

  @type t :: <<_::160>>

  @doc "The twenty bytes `value` names, or `:error` for anything that is not one address."
  @spec decode(term()) :: {:ok, t()} | :error
  def decode("0x" <> hex) when byte_size(hex) == 2 * @bytes do
    with {:ok, decoded} <- Base.decode16(hex, case: :mixed),
         false <- decoded == @zero,
         true <- checksummed?(hex) do
      {:ok, decoded}
    else
      _rejected -> :error
    end
  end

  def decode(_value), do: :error

  @doc "The lowercase canonical form every envelope and RPC parameter carries."
  @spec normalize(term()) :: {:ok, String.t()} | :error
  def normalize(value) do
    with {:ok, decoded} <- decode(value), do: {:ok, canonical(decoded)}
  end

  @doc "Whether two addresses name the same twenty bytes, whatever their casing."
  @spec equal?(term(), term()) :: boolean()
  def equal?(left, right), do: match?({{:ok, same}, {:ok, same}}, {decode(left), decode(right)})

  @spec canonical(t()) :: String.t()
  def canonical(decoded) when byte_size(decoded) == @bytes,
    do: "0x" <> Base.encode16(decoded, case: :lower)

  @doc "The EIP-55 checksummed rendering, for display only."
  @spec format(t()) :: String.t()
  def format(decoded) when byte_size(decoded) == @bytes,
    do: "0x" <> (decoded |> Base.encode16(case: :lower) |> checksum())

  # Only mixed case asserts a checksum, so a single-case address cannot fail one.
  defp checksummed?(hex),
    do: hex == String.downcase(hex) or hex == String.upcase(hex) or hex == checksum(hex)

  defp checksum(hex) do
    lowercase = String.downcase(hex)

    lowercase
    |> String.to_charlist()
    |> Enum.zip(nibbles(lowercase))
    |> Enum.map(fn
      {digit, nibble} when digit in ?a..?f and nibble >= 8 -> digit - 32
      {digit, _nibble} -> digit
    end)
    |> List.to_string()
  end

  # Ethereum Keccak-256, which is the original padding rather than OTP's NIST SHA3.
  defp nibbles(lowercase_hex),
    do: for(<<nibble::4 <- :jose_jwa_sha3.keccak(1088, 512, lowercase_hex, 1, 32)>>, do: nibble)
end
