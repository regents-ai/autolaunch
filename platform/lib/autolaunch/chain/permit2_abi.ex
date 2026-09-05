defmodule Autolaunch.Chain.Permit2Abi do
  @moduledoc """
  The canonical Permit2 allowance interface the auction's own currency path needs.

  The address is not transcribed from a directory: Solady
  `2af06408b6a204824c2ecb245779ed400b535fb5` `src/utils/SafeTransferLib.sol:64`
  declares `PERMIT2`, and lines 458-484 of that file are the `permit2TransferFrom`
  the auction calls at `src/ContinuousClearingAuction.sol:479`. `approve` and
  `allowance` come from Uniswap/permit2 `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219`
  `src/interfaces/IAllowanceTransfer.sol:111-123`.

  A zero expiration means the current block only (`src/libraries/Allowance.sol:38-39`),
  so every prepared allowance carries a real, short-lived one.
  """

  alias Autolaunch.Chain.Abi

  @abi_path Path.expand("../../../contracts/abi/permit2.json", __DIR__)
  @external_resource @abi_path
  @abi @abi_path |> File.read!() |> Jason.decode!()

  @address "0x000000000022d473030f116ddee9f6b43ac78ba3"
  @approve "approve(address,address,uint160,uint48)"
  @approve_selector "0x87517c45"
  @allowance "allowance(address,address,address)"
  @allowance_selector "0x927da105"

  @uint48_max Integer.pow(2, 48) - 1
  @uint160_max Integer.pow(2, 160) - 1

  @after_compile __MODULE__

  @doc false
  def __after_compile__(_env, _bytecode) do
    Abi.declared!(@abi, "function", @approve)
    Abi.declared!(@abi, "function", @allowance)
  end

  @spec address() :: String.t()
  def address, do: @address

  @doc "Exact calldata granting `spender` `amount` of `token` until `expiration`."
  @spec encode_approve(String.t(), String.t(), pos_integer(), pos_integer()) :: String.t()
  def encode_approve(token, spender, amount, expiration)
      when amount in 1..@uint160_max and expiration in 1..@uint48_max do
    @approve_selector <>
      address_word(token) <> address_word(spender) <> word(amount) <> word(expiration)
  end

  @spec encode_allowance(String.t(), String.t(), String.t()) :: String.t()
  def encode_allowance(owner, token, spender),
    do: @allowance_selector <> address_word(owner) <> address_word(token) <> address_word(spender)

  @doc """
  The allowed amount and its expiry from a three-word `allowance` answer.

  The words are a provider's, so they are held to the widths the interface
  declares: anything wider is a malformed answer rather than a huge allowance.
  """
  @spec decode_allowance([non_neg_integer()]) ::
          {:ok, %{amount: non_neg_integer(), expiration: non_neg_integer()}} | :error
  def decode_allowance([amount, expiration, _nonce])
      when amount in 0..@uint160_max and expiration in 0..@uint48_max,
      do: {:ok, %{amount: amount, expiration: expiration}}

  def decode_allowance(_words), do: :error

  defp address_word(address),
    do:
      address
      |> Abi.normalize_address!()
      |> String.trim_leading("0x")
      |> String.pad_leading(64, "0")

  defp word(value),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")
end
