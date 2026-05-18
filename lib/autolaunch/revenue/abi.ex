defmodule Autolaunch.Revenue.Abi do
  @moduledoc false

  @accounting_tag_recorded_topic0 "0xae9e7bd0e01f8c044658ed6a1226227cc52a7cd7a92be97733bf4be855780c64"
  @usdc_revenue_deposited_topic0 "0xfc73d207b0a0d30ff602b1a48023083a572a95cbbf70c466e34c184382c69db4"
  @direct_deposit_source_kind_topic "0x0000000000000000000000000000000000000000000000000000000000000000"

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
    preview_claimable_stake_token: "0x05e1fd68",
    treasury_residual_usdc: "0x966ed108",
    treasury_reserved_usdc: "0xe76bcce9",
    protocol_reserve_usdc: "0x76459dd5",
    eligible_revenue_share_bps: "0x549b5d48",
    pending_eligible_revenue_share_bps: "0xb663660a",
    pending_eligible_revenue_share_eta: "0x8c37a52f",
    eligible_revenue_share_cooldown_end: "0x5cc76060",
    total_usdc_received: "0xcf51bfdd",
    direct_deposit_usdc: "0x6a142340",
    verified_ingress_usdc: "0x35816a75",
    regent_skim_usdc: "0x1aa91287",
    staker_eligible_inflow_usdc: "0x08c23673",
    treasury_reserved_inflow_usdc: "0xddffd82a",
    undistributed_dust_usdc: "0x5f78d5f4",
    unclaimed_stake_token_liability: "0x05f15537",
    available_stake_token_reward_inventory: "0xcfb3d0aa",
    preview_funded_claimable_stake_token: "0xc5c5ae3a",
    total_claimed_stake_token: "0x66ffb8de",
    revenue_share_supply_denominator: "0xe3961f2a",
    stake: "0x7acb7757",
    unstake: "0x8381e182",
    claim_usdc: "0x42852610",
    claim_stake_token: "0xa47b7e27",
    claim_and_restake_stake_token: "0x9de65fcc",
    sweep_usdc: "0xf4d1e0cb",
    ingress_deposit_usdc: "0xe96ba32e",
    accounting_tag_count: "0x13c5797a",
    accounting_tag_at: "0x33a00799",
    accounting_tags_since_block: "0x1e679e7b",
    balance_of: "0x70a08231",
    can_manage_subject: "0x41c2ab07"
  }

  def accounting_tag_recorded_topic0, do: @accounting_tag_recorded_topic0
  def usdc_revenue_deposited_topic0, do: @usdc_revenue_deposited_topic0
  def direct_deposit_source_kind_topic, do: @direct_deposit_source_kind_topic

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

  def encode_claim_stake_token(recipient) do
    encode_address_call(:claim_stake_token, recipient)
  end

  def encode_claim_and_restake_stake_token do
    selector(:claim_and_restake_stake_token)
  end

  def encode_sweep_usdc, do: selector(:sweep_usdc)

  def decode_call_data("0x" <> data) when is_binary(data) and byte_size(data) >= 8 do
    <<selector::binary-size(8), args::binary>> = data

    case selector do
      "7acb7757" -> decode_stake_call(args)
      "8381e182" -> decode_unstake_call(args)
      "42852610" -> decode_claim_usdc_call(args)
      "a47b7e27" -> decode_claim_stake_token_call(args)
      "9de65fcc" -> decode_claim_and_restake_stake_token_call(args)
      "f4d1e0cb" -> decode_sweep_usdc_call(args)
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

  def decode_accounting_tag_log(%{
        address: ingress_address,
        topics: [@accounting_tag_recorded_topic0, tag_index_topic, depositor_topic],
        data: data,
        block_number: log_block_number,
        transaction_hash: transaction_hash,
        log_index: log_index
      }) do
    with {:ok, tag_index} <- decode_uint256_word(tag_index_topic),
         {:ok, depositor} <- decode_address_word(depositor_topic),
         {:ok, [block_number_word, amount_word, source_tag_word]} <- decode_words_payload(data, 3),
         {:ok, block_number} <- decode_uint256_word(block_number_word),
         {:ok, amount} <- decode_uint256_word(amount_word),
         {:ok, source_tag} <- decode_bytes32_word(source_tag_word) do
      {:ok,
       %{
         ingress_address: String.downcase(ingress_address),
         tag_index: tag_index,
         block_number: block_number,
         log_block_number: log_block_number,
         depositor: depositor,
         amount_raw: amount,
         label: source_tag,
         source: "ingress_deposit",
         transaction_hash: transaction_hash,
         log_index: log_index
       }}
    else
      _ -> {:error, :invalid_accounting_tag_log}
    end
  end

  def decode_accounting_tag_log(_log), do: {:error, :invalid_accounting_tag_log}

  def decode_direct_revenue_log(%{
        address: splitter_address,
        topics: [
          @usdc_revenue_deposited_topic0,
          @direct_deposit_source_kind_topic,
          depositor_topic,
          _source_ref_topic
        ],
        data: data,
        block_number: log_block_number,
        transaction_hash: transaction_hash,
        log_index: log_index
      }) do
    with {:ok, depositor} <- decode_address_word(depositor_topic),
         {:ok,
          [
            amount_word,
            _protocol_amount_word,
            _eligible_share_bps_word,
            _staker_eligible_amount_word,
            _treasury_reserved_amount_word,
            _staker_entitlement_word,
            _treasury_residual_amount_word,
            source_tag_word
          ]} <- decode_words_payload(data, 8),
         {:ok, amount} <- decode_uint256_word(amount_word),
         {:ok, source_tag} <- decode_bytes32_word(source_tag_word) do
      {:ok,
       %{
         splitter_address: String.downcase(splitter_address),
         ingress_address: nil,
         tag_index: nil,
         block_number: log_block_number,
         log_block_number: log_block_number,
         depositor: depositor,
         amount_raw: amount,
         label: source_tag,
         source: "direct_deposit",
         transaction_hash: transaction_hash,
         log_index: log_index
       }}
    else
      _ -> {:error, :invalid_direct_revenue_log}
    end
  end

  def decode_direct_revenue_log(_log), do: {:error, :invalid_direct_revenue_log}

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
    with {:ok, []} <- decode_words(args, 0) do
      {:ok, %{action: :sweep_ingress}}
    end
  end

  defp decode_claim_stake_token_call(args) do
    with {:ok, [recipient_word]} <- decode_words(args, 1),
         {:ok, recipient} <- decode_address_word(recipient_word) do
      {:ok, %{action: :claim_stake_token, recipient: recipient}}
    end
  end

  defp decode_claim_and_restake_stake_token_call(args) do
    with {:ok, []} <- decode_words(args, 0) do
      {:ok, %{action: :claim_and_restake_stake_token}}
    end
  end

  defp decode_words(args, expected_count) do
    if is_binary(args) and byte_size(args) == expected_count * 64 do
      {:ok, split_words(String.downcase(args), expected_count, [])}
    else
      {:error, :invalid_call_data}
    end
  end

  defp decode_words_payload("0x" <> args, expected_count), do: decode_words(args, expected_count)
  defp decode_words_payload(_args, _expected_count), do: {:error, :invalid_call_data}

  defp split_words(_data, 0, acc), do: Enum.reverse(acc)

  defp split_words(data, count, acc) when count > 0 and byte_size(data) >= 64 do
    <<word::binary-size(64), rest::binary>> = data
    split_words(rest, count - 1, ["0x" <> word | acc])
  end
end
