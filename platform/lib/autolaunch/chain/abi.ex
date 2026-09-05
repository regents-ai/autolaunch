defmodule Autolaunch.Chain.Abi do
  @moduledoc false

  alias Autolaunch.Chain.Address

  @manifest_path Path.expand("../../../contracts/chain-contracts.yaml", __DIR__)
  @external_resource @manifest_path

  @manifest YamlElixir.read_from_file!(@manifest_path)
  @evidence Map.new(
              get_in(@manifest, ["contracts", Access.at(0), "reviewed_action_evidence"]),
              &{&1["contract_id"], &1}
            )

  @address_bound Integer.pow(2, 160)

  # The evidence manifest pins contract identities, not the ERC-20 interface every
  # token shares, so the standard calls this site prepares are declared here
  # against their canonical signatures.
  @erc20_interface [
    %{"id" => "approve", "signature" => "approve(address,uint256)", "selector" => "0x095ea7b3"},
    %{"id" => "balance_of", "signature" => "balanceOf(address)", "selector" => "0x70a08231"},
    %{
      "id" => "allowance",
      "signature" => "allowance(address,address)",
      "selector" => "0xdd62ed3e"
    }
  ]

  @doc false
  def erc20_interface, do: @erc20_interface

  @event_signatures %{
    approval: "Approval(address,address,uint256)"
  }

  @doc "Raises unless `abi` declares exactly this function or event signature."
  def declared!(abi, kind, signature) do
    [name] = Regex.run(~r/^(\w+)\(/, signature, capture: :all_but_first)

    Enum.any?(abi, fn
      %{"type" => ^kind, "name" => ^name, "inputs" => inputs} ->
        "#{name}(#{Enum.map_join(inputs, ",", & &1["type"])})" == signature

      _entry ->
        false
    end) || raise "pinned ABI is missing #{signature}"
  end

  def usdc_address,
    do: get_in(@evidence, ["regent_revenue_staking", "onchain_constants", "usdc"])

  @doc "The one REGENT address this site reads, quotes and approves against."
  def regent_address, do: @evidence["regent_erc20"]["address"]

  @doc "The admitted factory address, or `:none` while the manifest entry is address-free."
  @spec factory_address() :: {:ok, String.t()} | :none
  def factory_address do
    case @evidence["regents_autolaunch_factory_v1"]["address"] do
      address when is_binary(address) and address != "" -> {:ok, address}
      _absent -> :none
    end
  end

  def encode_erc20(id, arguments) when id in ["approve", "balance_of", "allowance"] do
    entry =
      Enum.find(@erc20_interface, &(&1["id"] == id)) || raise "missing ERC-20 ABI entry #{id}"

    encode_standard(entry, arguments)
  end

  @doc "Ethereum Keccak-256 of an exact event signature, which is its `topic0`."
  def topic0(signature),
    do: "0x" <> Base.encode16(:jose_jwa_sha3.keccak(1088, 512, signature, 1, 32), case: :lower)

  defp event_signature(id), do: Map.fetch!(@event_signatures, id)
  def event_topic(id), do: id |> event_signature() |> topic0()

  @doc """
  The one log in this receipt that is exactly this event.

  Emitter, `topic0`, indexed count and data width all have to be exact, and the
  event has to appear exactly once: absent and duplicated are both `:error`,
  while logs belonging to other events are ignored.
  """
  def one_event(logs, topic, emitter, indexed_count, data_words) when is_list(logs) do
    case Enum.filter(logs, &emitted?(&1, topic, emitter)) do
      [log] -> decode_event(log, indexed_count, data_words)
      _absent_or_duplicated -> :error
    end
  end

  def one_event(_logs, _topic, _emitter, _indexed_count, _data_words), do: :error

  @doc "The address a 32-byte word names, which requires its leading twelve bytes to be zero."
  def word_address(value) when is_integer(value) and value > 0 and value < @address_bound,
    do:
      {:ok,
       "0x" <>
         (value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(40, "0"))}

  def word_address(_value), do: :error

  @doc "The exact ERC-20 approval this transaction had to record."
  def approval_recorded?(logs, token, owner, spender, value) do
    with {:ok, {[owner_word, spender_word], [^value]}} <-
           one_event(logs, event_topic(:approval), token, 2, 1),
         {:ok, ^owner} <- word_address(owner_word),
         {:ok, ^spender} <- word_address(spender_word) do
      true
    else
      _contradiction -> false
    end
  end

  defp emitted?(%{"address" => address, "topics" => [topic | _indexed]}, expected, emitter)
       when is_binary(topic),
       do: String.downcase(topic) == expected and Address.equal?(address, emitter)

  defp emitted?(_log, _expected, _emitter), do: false

  defp decode_event(%{"topics" => [_topic | indexed], "data" => "0x" <> data}, count, words)
       when length(indexed) == count and byte_size(data) == words * 64 do
    {:ok,
     {Enum.map(indexed, &topic_word!/1), for(<<word::binary-size(64) <- data>>, do: word!(word))}}
  rescue
    _malformed -> :error
  end

  defp decode_event(_log, _count, _words), do: :error

  defp topic_word!("0x" <> hex) when byte_size(hex) == 64, do: word!(hex)

  defp word!(hex) do
    {:ok, bytes} = Base.decode16(hex, case: :mixed)
    :binary.decode_unsigned(bytes)
  end

  defp encode_standard(entry, arguments) do
    [encoded_types] = Regex.run(~r/^\w+\((.*)\)$/, entry["signature"], capture: :all_but_first)

    inputs =
      if encoded_types == "",
        do: [],
        else: Enum.map(String.split(encoded_types, ","), &%{"type" => &1})

    encode_inputs(entry, inputs, arguments)
  end

  defp encode_inputs(entry, inputs, arguments) do
    if length(inputs) != length(arguments) do
      raise ArgumentError, "ABI argument count does not match #{entry["signature"]}"
    end

    encoded =
      inputs
      |> Enum.zip(arguments)
      |> Enum.map_join(fn {input, argument} -> encode_static(input["type"], argument) end)

    String.downcase(entry["selector"] <> encoded)
  end

  defp encode_static("address", address) do
    normalized = normalize_address!(address)
    normalized |> String.trim_leading("0x") |> String.pad_leading(64, "0")
  end

  defp encode_static("uint256", value) when is_integer(value) and value >= 0 do
    value |> Integer.to_string(16) |> String.pad_leading(64, "0")
  end

  defp encode_static(type, _value), do: raise(ArgumentError, "unsupported ABI input #{type}")

  def normalize_address!(address) do
    case Address.normalize(address) do
      {:ok, normalized} -> normalized
      :error -> raise ArgumentError, "wallet address is invalid"
    end
  end
end
