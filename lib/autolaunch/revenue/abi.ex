defmodule Autolaunch.Revenue.Abi do
  @moduledoc false

  @selectors %{
    ingress_account_count: "0xca23dd76",
    ingress_account_at: "0xb87d9995",
    default_ingress_of_subject: "0xb396721d",
    stake_token: "0x51ed6a30",
    usdc: "0x3e413bee",
    treasury_recipient: "0xeb4eebc7",
    protocol_recipient: "0x941f5d25",
    total_staked: "0x817b1cd2",
    staked_balance: "0x60217267",
    preview_claimable_usdc: "0xb026ee79",
    treasury_residual_usdc: "0x966ed108",
    protocol_reserve_usdc: "0x76459dd5",
    undistributed_dust_usdc: "0x5f78d5f4",
    stake: "0x7acb7757",
    unstake: "0x8381e182",
    claim_usdc: "0x42852610",
    sweep_usdc: "0xbe25fb30",
    balance_of: "0x70a08231",
    can_manage_subject: "0x41c2ab07"
  }

  def selector(name), do: Map.fetch!(@selectors, name)

  def encode_call(name, args \\ []) when is_list(args) do
    selector(name) <> Enum.map_join(args, "", &encode_arg/1)
  end

  def encode_no_args(name), do: selector(name)

  def encode_uint256_call(name, value) when is_integer(value) and value >= 0 do
    selector(name) <> encode_uint256(value)
  end

  def encode_address_call(name, address) when is_binary(address) do
    selector(name) <> encode_address_word(address)
  end

  def encode_bytes32_call(name, bytes32) when is_binary(bytes32) do
    selector(name) <> encode_bytes32_word(bytes32)
  end

  def encode_two_arg_call(name, {:uint256, left}, {:address, right}) do
    selector(name) <> encode_uint256(left) <> encode_address_word(right)
  end

  def encode_two_arg_call(name, {:bytes32, left}, {:uint256, right}) do
    selector(name) <> encode_bytes32_word(left) <> encode_uint256(right)
  end

  def encode_two_arg_call(name, {:bytes32, left}, {:address, right}) do
    selector(name) <> encode_bytes32_word(left) <> encode_address_word(right)
  end

  def encode_stake(amount, receiver) do
    encode_two_arg_call(:stake, {:uint256, amount}, {:address, receiver})
  end

  def encode_unstake(amount, recipient) do
    encode_two_arg_call(:unstake, {:uint256, amount}, {:address, recipient})
  end

  def encode_claim_usdc(recipient) do
    encode_address_call(:claim_usdc, recipient)
  end

  def encode_sweep_usdc(source_ref) do
    encode_bytes32_call(:sweep_usdc, source_ref)
  end

  def decode_call_data("0x" <> data) when is_binary(data) and byte_size(data) >= 8 do
    <<selector::binary-size(8), args::binary>> = data

    case selector do
      "7acb7757" -> decode_stake_call(args)
      "8381e182" -> decode_unstake_call(args)
      "42852610" -> decode_claim_usdc_call(args)
      "be25fb30" -> decode_sweep_usdc_call(args)
      _ -> {:error, :unsupported_call_selector}
    end
  end

  def decode_call_data(_), do: {:error, :invalid_call_data}

  def decode_uint256(<<"0x", hex::binary>>) when hex != "" do
    String.to_integer(hex, 16)
  end

  def decode_address(<<"0x", hex::binary>>) when byte_size(hex) == 64 do
    hex
    |> String.slice(-40, 40)
    |> then(&("0x" <> &1))
    |> String.downcase()
  end

  def decode_uint256_word(<<"0x", hex::binary>>) when byte_size(hex) == 64 do
    {:ok, String.to_integer(hex, 16)}
  end

  def decode_address_word(<<"0x", hex::binary>>) when byte_size(hex) == 64 do
    {:ok,
     hex
     |> String.slice(-40, 40)
     |> then(&("0x" <> &1))
     |> String.downcase()}
  end

  def decode_bytes32_word(<<"0x", hex::binary>>) when byte_size(hex) == 64 do
    {:ok, "0x" <> String.downcase(hex)}
  end

  def encode_uint256(value) when is_integer(value) and value >= 0 do
    value
    |> Integer.to_string(16)
    |> String.pad_leading(64, "0")
  end

  def encode_arg({:uint256, value}) when is_integer(value) and value >= 0 do
    encode_uint256(value)
  end

  def encode_arg({:address, value}) when is_binary(value) do
    encode_address_word(value)
  end

  def encode_arg({:bytes32, value}) when is_binary(value) do
    encode_bytes32_word(value)
  end

  def encode_address_word("0x" <> address) when byte_size(address) == 40 do
    address
    |> String.downcase()
    |> String.pad_leading(64, "0")
  end

  def encode_bytes32_word("0x" <> value) when byte_size(value) == 64 do
    String.downcase(value)
  end

  defp decode_stake_call(args) do
    with {:ok, [amount_word, receiver_word]} <- decode_words(args, 2),
         {:ok, amount} <- decode_uint256_word(amount_word),
         {:ok, receiver} <- decode_address_word(receiver_word) do
      {:ok, %{action: :stake, amount_wei: amount, receiver: receiver}}
    end
  end

  defp decode_unstake_call(args) do
    with {:ok, [amount_word, recipient_word]} <- decode_words(args, 2),
         {:ok, amount} <- decode_uint256_word(amount_word),
         {:ok, recipient} <- decode_address_word(recipient_word) do
      {:ok, %{action: :unstake, amount_wei: amount, recipient: recipient}}
    end
  end

  defp decode_claim_usdc_call(args) do
    with {:ok, [recipient_word]} <- decode_words(args, 1),
         {:ok, recipient} <- decode_address_word(recipient_word) do
      {:ok, %{action: :claim_usdc, recipient: recipient}}
    end
  end

  defp decode_sweep_usdc_call(args) do
    with {:ok, [source_ref_word]} <- decode_words(args, 1),
         {:ok, source_ref} <- decode_bytes32_word(source_ref_word) do
      {:ok, %{action: :sweep_ingress, source_ref: source_ref}}
    end
  end

  defp decode_words(args, expected_count) do
    if is_binary(args) and byte_size(args) == expected_count * 64 do
      {:ok, split_words(String.downcase(args), expected_count, [])}
    else
      {:error, :invalid_call_data}
    end
  end

  defp split_words(_data, 0, acc), do: Enum.reverse(acc)

  defp split_words(data, count, acc) when count > 0 and byte_size(data) >= 64 do
    <<word::binary-size(64), rest::binary>> = data
    split_words(rest, count - 1, ["0x" <> word | acc])
  end
end
