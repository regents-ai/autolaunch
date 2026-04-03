defmodule Autolaunch.CCA.Abi do
  @moduledoc false

  @max_u256 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
  @submit_bid_data_offset 128
  @empty_bytes_word String.duplicate("0", 64)

  @selectors %{
    checkpoint: "0xc2c4c5c1",
    currency_raised: "0x998ba4fc",
    total_cleared: "0x3e9d9174",
    floor_price: "0x9363c812",
    tick_spacing: "0xd0c93a7c",
    next_active_tick_price: "0x60d3ded7",
    sum_currency_demand_above_clearing_q96: "0xa9176e45",
    total_supply: "0x18160ddd",
    required_currency_raised: "0x465a8928",
    end_block: "0x083c6323",
    claim_block: "0x37dfbc4b",
    start_block: "0x48cd4cb1",
    is_graduated: "0x9e5f2602",
    max_bid_price: "0xae91fa33",
    ticks: "0x534cb30d",
    bids: "0x4423c5f1",
    checkpoints: "0xa2865d89",
    last_checkpointed_block: "0x1c630ee8",
    submit_bid_simple: "0x140fe8ee",
    submit_bid_with_prev_tick: "0xa52c8728",
    exit_bid: "0x8e4deb17",
    exit_partially_filled_bid: "0x36dec5f2",
    claim_tokens: "0x46e04a2f"
  }
  @event_topics %{
    bid_submitted: "0x650baad5cd8ca09b8f580be220fa04ce2ba905a041f764b6a3fe2c848eb70540",
    bid_exited: "0x054fe6469466a0b4d2a6ae4b100e5f9c494c958f04b4000f44d470088dd97930",
    tokens_claimed: "0x880f2ef2613b092f1a0a819f294155c98667eb294b7e6bf7a3810278142c1a1c",
    checkpoint_updated: "0xf1e4b6d7d0d7c5deb6393a39862d66a2f2ecb034f3283a8a597f9bf0c36f76fa",
    clearing_price_updated: "0x30adbe996d7a69a21fdebcc1f8a46270bf6c22d505a7d872c1ab4767aa707609"
  }

  def max_u256, do: @max_u256

  def selector(name), do: Map.fetch!(@selectors, name)
  def event_topic(name), do: Map.fetch!(@event_topics, name)

  def encode_uint256(value) when is_integer(value) and value >= 0 do
    value
    |> Integer.to_string(16)
    |> String.pad_leading(64, "0")
  end

  def encode_address_word("0x" <> address) when byte_size(address) == 40 do
    String.pad_leading(String.downcase(address), 64, "0")
  end

  def encode_call(selector_name, []), do: selector(selector_name)

  def encode_call(selector_name, [{:uint256, value}]) do
    selector(selector_name) <> encode_uint256(value)
  end

  def encode_submit_bid(max_price_q96, amount_wei, owner_address) do
    selector(:submit_bid_simple) <>
      encode_uint256(max_price_q96) <>
      encode_uint256(amount_wei) <>
      encode_address_word(owner_address) <>
      encode_uint256(@submit_bid_data_offset) <>
      @empty_bytes_word
  end

  def encode_exit_bid(bid_id), do: selector(:exit_bid) <> encode_uint256(bid_id)

  def encode_exit_partially_filled_bid(bid_id, last_fully_filled_checkpoint_block, outbid_block) do
    selector(:exit_partially_filled_bid) <>
      encode_uint256(bid_id) <>
      encode_uint256(last_fully_filled_checkpoint_block) <>
      encode_uint256(outbid_block)
  end

  def encode_claim_tokens(bid_id), do: selector(:claim_tokens) <> encode_uint256(bid_id)

  def decode_uint256(<<"0x", hex::binary>>) when byte_size(hex) == 64 do
    String.to_integer(hex, 16)
  end

  def decode_bool(<<"0x", _::binary-size(63), last::binary-size(1)>>), do: last == "1"

  def decode_words(<<"0x", data::binary>>) when rem(byte_size(data), 64) == 0 do
    for <<word::binary-size(64) <- data>>, do: String.to_integer(word, 16)
  end

  def decode_checkpoint(result) do
    case decode_words(result) do
      [
        clearing_price,
        currency_raised_at_clearing_price_q96_x7,
        cumulative_mps_per_price,
        cumulative_mps,
        prev_block,
        next_block
      ] ->
        {:ok,
         %{
           clearing_price_q96: clearing_price,
           currency_raised_at_clearing_price_q96_x7: currency_raised_at_clearing_price_q96_x7,
           cumulative_mps_per_price: cumulative_mps_per_price,
           cumulative_mps: cumulative_mps,
           prev_block: prev_block,
           next_block: next_block
         }}

      _ ->
        {:error, :invalid_checkpoint}
    end
  end

  def decode_tick(result) do
    case decode_words(result) do
      [next_price, currency_demand_q96] ->
        {:ok, %{next_price_q96: next_price, currency_demand_q96: currency_demand_q96}}

      _ ->
        {:error, :invalid_tick}
    end
  end

  def decode_bid(result) do
    case decode_words(result) do
      [
        start_block,
        start_cumulative_mps,
        exited_block,
        max_price_q96,
        owner_word,
        amount_q96,
        tokens_filled_units
      ] ->
        {:ok,
         %{
           start_block: start_block,
           start_cumulative_mps: start_cumulative_mps,
           exited_block: exited_block,
           max_price_q96: max_price_q96,
           owner_address: decode_address_word(owner_word),
           amount_q96: amount_q96,
           tokens_filled_units: tokens_filled_units
         }}

      _ ->
        {:error, :invalid_bid}
    end
  end

  def decode_bid_submitted_log(%{topics: [topic0, bid_id_topic, owner_topic], data: data})
      when is_binary(topic0) do
    if topic0 == event_topic(:bid_submitted) do
      case decode_words(data) do
        [price_q96, amount_wei] ->
          {:ok,
           %{
             onchain_bid_id: decode_topic_uint(bid_id_topic),
             owner_address: decode_topic_address(owner_topic),
             max_price_q96: price_q96,
             amount_wei: amount_wei
           }}

        _ ->
          {:error, :invalid_bid_submitted_log}
      end
    else
      {:error, :unexpected_event_topic}
    end
  end

  def decode_bid_exited_log(%{topics: [topic0, bid_id_topic, owner_topic], data: data})
      when is_binary(topic0) do
    if topic0 == event_topic(:bid_exited) do
      case decode_words(data) do
        [tokens_filled_units, currency_refunded_wei] ->
          {:ok,
           %{
             onchain_bid_id: decode_topic_uint(bid_id_topic),
             owner_address: decode_topic_address(owner_topic),
             tokens_filled_units: tokens_filled_units,
             currency_refunded_wei: currency_refunded_wei
           }}

        _ ->
          {:error, :invalid_bid_exited_log}
      end
    else
      {:error, :unexpected_event_topic}
    end
  end

  def decode_tokens_claimed_log(%{topics: [topic0, bid_id_topic, owner_topic], data: data})
      when is_binary(topic0) do
    if topic0 == event_topic(:tokens_claimed) do
      case decode_words(data) do
        [tokens_filled_units] ->
          {:ok,
           %{
             onchain_bid_id: decode_topic_uint(bid_id_topic),
             owner_address: decode_topic_address(owner_topic),
             tokens_filled_units: tokens_filled_units
           }}

        _ ->
          {:error, :invalid_tokens_claimed_log}
      end
    else
      {:error, :unexpected_event_topic}
    end
  end

  def decode_checkpoint_updated_log(%{topics: [topic0], data: data, block_number: block_number})
      when is_binary(topic0) do
    if topic0 == event_topic(:checkpoint_updated) do
      case decode_words(data) do
        [checkpoint_block_number, clearing_price_q96, cumulative_mps] ->
          {:ok,
           %{
             checkpoint_block_number: checkpoint_block_number,
             block_number: block_number,
             clearing_price_q96: clearing_price_q96,
             cumulative_mps: cumulative_mps
           }}

        _ ->
          {:error, :invalid_checkpoint_updated_log}
      end
    else
      {:error, :unexpected_event_topic}
    end
  end

  defp decode_topic_uint(<<"0x", topic::binary>>) when byte_size(topic) == 64 do
    String.to_integer(topic, 16)
  end

  defp decode_topic_address(<<"0x", topic::binary>>) when byte_size(topic) == 64 do
    decode_address_word(String.to_integer(topic, 16))
  end

  defp decode_address_word(word) when is_integer(word) do
    word
    |> Integer.to_string(16)
    |> String.pad_leading(40, "0")
    |> String.slice(-40, 40)
    |> then(&("0x" <> &1))
    |> String.downcase()
  end
end
