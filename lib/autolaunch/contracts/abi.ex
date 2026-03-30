defmodule Autolaunch.Contracts.Abi do
  @moduledoc false

  import Bitwise

  @selectors %{
    owner: "0x8da5cb5b",
    auction_address: "0x5476ea9e",
    migrated: "0x2c678c64",
    migrated_pool_id: "0x5bf380d3",
    migrated_position_id: "0x91f6dcdb",
    migrated_liquidity: "0xc6112980",
    migrated_currency_for_lp: "0x3e9f30ec",
    migrated_token_for_lp: "0xd400f42f",
    migration_block: "0x42162044",
    sweep_block: "0xd3decc68",
    reserve_token_amount: "0x5d466045",
    max_currency_amount_for_lp: "0x531d3595",
    total_strategy_supply: "0xe2fb4d6e",
    token: "0xfc0c546a",
    usdc: "0x3e413bee",
    balance_of: "0x70a08231",
    beneficiary: "0x38af3eed",
    start_timestamp: "0xe6fd48bc",
    duration_seconds: "0x9acba2af",
    released_launch_token: "0x72b18070",
    releasable_launch_token: "0x5fa5e827",
    get_pool_config: "0x037aadbe",
    treasury_accrued: "0x4e3df84b",
    regent_accrued: "0x738b0afd",
    hook: "0x7f5a7c7b",
    get_subject: "0xc67716c7",
    can_manage_subject: "0x41c2ab07",
    identity_link_count: "0xbdbaea96",
    identity_link_at: "0xc22085b7",
    label: "0xcb4774c4",
    paused: "0x5c975abb",
    treasury_recipient: "0xeb4eebc7",
    protocol_recipient: "0x941f5d25",
    protocol_skim_bps: "0xaf385b72",
    authorized_creators: "0xc695502a",
    default_ingress_of_subject: "0xb396721d",
    ingress_account_count: "0xca23dd76",
    ingress_account_at: "0xb87d9995",
    set_paused: "0x16c38b3c",
    set_label: "0xbf530969",
    set_treasury_recipient: "0xb277c6a7",
    set_protocol_recipient: "0x07ba8a54",
    set_protocol_skim_bps: "0x43c1cc0a",
    withdraw_treasury_residual_usdc: "0x7631d755",
    withdraw_protocol_reserve_usdc: "0xa7f90b31",
    reassign_undistributed_dust_to_treasury: "0xbe2a401c",
    set_authorized_creator: "0xe1434f4e",
    create_ingress_account: "0x8a3dc13f",
    set_default_ingress: "0xdf4a422e",
    rescue_token: "0xf8a67a62",
    set_subject_manager: "0x459ae32e",
    link_identity: "0xd0a58cd9",
    set_hook: "0x3dfd3873",
    withdraw_treasury: "0x06183605",
    withdraw_regent_share: "0xf1127043",
    set_hook_enabled: "0x2b6b2213",
    migrate: "0x8fd3ab80",
    sweep_token: "0x532cce18",
    sweep_currency: "0x7c121574",
    release_launch_token: "0xa99b3481"
  }

  @type encode_arg ::
          {:address, binary()}
          | {:uint256, non_neg_integer()}
          | {:uint16, non_neg_integer()}
          | {:bool, boolean()}
          | {:bytes32, binary()}
          | {:string, binary()}

  def selector(name), do: Map.fetch!(@selectors, name)

  def encode_call(name, args \\ []) when is_list(args) do
    selector(name) <> encode_args(args)
  end

  def decode_bool(<<"0x", hex::binary>>) when byte_size(hex) == 64 do
    String.to_integer(hex, 16) != 0
  end

  def decode_uint256(<<"0x", hex::binary>>) when byte_size(hex) == 64 do
    String.to_integer(hex, 16)
  end

  def decode_address(<<"0x", hex::binary>>) when byte_size(hex) == 64 do
    "0x" <> String.slice(String.downcase(hex), -40, 40)
  end

  def decode_bytes32(<<"0x", hex::binary>>) when byte_size(hex) == 64 do
    "0x" <> String.downcase(hex)
  end

  def decode_string(<<"0x", hex::binary>>) when rem(byte_size(hex), 64) == 0 do
    with {:ok, offset} <- word_at(hex, 0) do
      decode_dynamic_string(hex, offset)
    end
  end

  def decode_pool_config(<<"0x", hex::binary>>) when rem(byte_size(hex), 64) == 0 do
    with {:ok, words} <- first_words(hex, 11) do
      [
        launch_token,
        quote_token,
        treasury,
        regent_recipient,
        currency0,
        currency1,
        pool_fee,
        tick_spacing,
        pool_manager,
        hook,
        hook_enabled
      ] = words

      {:ok,
       %{
         launch_token: decode_address_word(launch_token),
         quote_token: decode_address_word(quote_token),
         treasury: decode_address_word(treasury),
         regent_recipient: decode_address_word(regent_recipient),
         currency0: decode_address_word(currency0),
         currency1: decode_address_word(currency1),
         pool_fee: decode_uint_word(pool_fee),
         tick_spacing: decode_signed_word(tick_spacing),
         pool_manager: decode_address_word(pool_manager),
         hook: decode_address_word(hook),
         hook_enabled: decode_bool_word(hook_enabled)
       }}
    end
  end

  def decode_subject_config(<<"0x", hex::binary>>) when rem(byte_size(hex), 64) == 0 do
    with {:ok, words} <- first_words(hex, 5),
         [stake_token, splitter, treasury_safe, active, label_offset] = words,
         {:ok, label} <- decode_dynamic_string(hex, decode_uint_word(label_offset)) do
      {:ok,
       %{
         stake_token: decode_address_word(stake_token),
         splitter: decode_address_word(splitter),
         treasury_safe: decode_address_word(treasury_safe),
         active: decode_bool_word(active),
         label: label
       }}
    end
  end

  def decode_identity_link(<<"0x", hex::binary>>) when rem(byte_size(hex), 64) == 0 do
    with {:ok, words} <- first_words(hex, 3) do
      [chain_id, registry, agent_id] = words

      {:ok,
       %{
         chain_id: decode_uint_word(chain_id),
         registry: decode_address_word(registry),
         agent_id: decode_uint_word(agent_id)
       }}
    end
  end

  defp encode_args(args) do
    head_size = length(args) * 32

    {heads, tails, _offset} =
      Enum.reduce(args, {[], [], head_size}, fn arg, {head_acc, tail_acc, offset} ->
        case arg do
          {:string, value} ->
            encoded_tail = encode_string_tail(value)

            {
              [encode_uint_word(offset) | head_acc],
              [encoded_tail | tail_acc],
              offset + div(byte_size(encoded_tail), 2)
            }

          _ ->
            {[encode_static(arg) | head_acc], tail_acc, offset}
        end
      end)

    Enum.join(Enum.reverse(heads) ++ Enum.reverse(tails))
  end

  defp encode_static({:address, value}), do: encode_address_word(value)
  defp encode_static({:uint256, value}), do: encode_uint_word(value)
  defp encode_static({:uint16, value}), do: encode_uint_word(value)
  defp encode_static({:bool, value}), do: encode_uint_word(if(value, do: 1, else: 0))
  defp encode_static({:bytes32, value}), do: encode_bytes32_word(value)

  defp encode_string_tail(value) do
    hex = Base.encode16(value, case: :lower)
    length_word = encode_uint_word(byte_size(value))
    padded_hex = String.pad_trailing(hex, padded_hex_size(byte_size(value)), "0")
    length_word <> padded_hex
  end

  defp padded_hex_size(byte_size) do
    padded_bytes =
      case rem(byte_size, 32) do
        0 -> byte_size
        remainder -> byte_size + (32 - remainder)
      end

    padded_bytes * 2
  end

  defp encode_uint_word(value) when is_integer(value) and value >= 0 do
    value
    |> Integer.to_string(16)
    |> String.pad_leading(64, "0")
  end

  defp encode_address_word("0x" <> value) when byte_size(value) == 40 do
    value
    |> String.downcase()
    |> String.pad_leading(64, "0")
  end

  defp encode_bytes32_word("0x" <> value) when byte_size(value) == 64 do
    String.downcase(value)
  end

  defp first_words(hex, count) when is_binary(hex) and count >= 0 do
    if byte_size(hex) < count * 64 do
      {:error, :invalid_return_data}
    else
      {:ok, split_words(hex, count, [])}
    end
  end

  defp split_words(_hex, 0, acc), do: Enum.reverse(acc)

  defp split_words(hex, count, acc) do
    <<word::binary-size(64), rest::binary>> = hex
    split_words(rest, count - 1, [word | acc])
  end

  defp word_at(hex, offset_bytes) when is_integer(offset_bytes) and offset_bytes >= 0 do
    offset = offset_bytes * 2

    if byte_size(hex) >= offset + 64 do
      <<_::binary-size(offset), word::binary-size(64), _::binary>> = hex
      {:ok, decode_uint_word(word)}
    else
      {:error, :invalid_return_data}
    end
  end

  defp decode_dynamic_string(hex, offset_bytes)
       when is_integer(offset_bytes) and offset_bytes >= 0 do
    with {:ok, length} <- word_at(hex, offset_bytes) do
      data_offset = (offset_bytes + 32) * 2
      data_size = length * 2

      if byte_size(hex) >= data_offset + data_size do
        <<_::binary-size(data_offset), raw::binary-size(data_size), _::binary>> = hex
        {:ok, Base.decode16!(String.upcase(raw))}
      else
        {:error, :invalid_return_data}
      end
    end
  end

  defp decode_uint_word(word) when byte_size(word) == 64 do
    String.to_integer(word, 16)
  end

  defp decode_bool_word(word) when byte_size(word) == 64 do
    decode_uint_word(word) != 0
  end

  defp decode_address_word(word) when byte_size(word) == 64 do
    "0x" <> String.slice(String.downcase(word), -40, 40)
  end

  defp decode_signed_word(word) when byte_size(word) == 64 do
    value = String.to_integer(word, 16)
    max_signed = bsl(1, 255) - 1

    if value > max_signed do
      value - bsl(1, 256)
    else
      value
    end
  end
end
