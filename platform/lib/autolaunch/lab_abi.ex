defmodule Autolaunch.LabAbi do
  @moduledoc false

  alias Autolaunch.Chain.{Abi, Address}

  @swap_fee_settled "SwapFeeSettled(bytes32,address,address,uint256,uint256,bool)"

  @required %{
    "factory" => [
      f:
        {"launch((string,string,string,string,string,address,uint128,uint256))", "nonpayable",
         ["uint256", "address", "address", "address"]},
      f: {"launchFee()", "view", ["uint256"]},
      f: {"launchesPaused()", "view", ["bool"]},
      f: {"strategy()", "view", ["address"]},
      f: {"launches(uint256)", "view", ["(address,address,address,address,address)"]},
      f: {"launchIdOfSubject(address)", "view", ["uint256"]},
      e:
        {"LaunchCreated(uint256,address,address,address,address,address,uint128,uint64,uint64)",
         [true, true, true, false, false, false, false, false, false]}
    ],
    "strategy" => [
      f: {"factory()", "view", ["address"]},
      f: {"hook()", "view", ["address"]},
      f: {"START_DELAY_BLOCKS()", "view", ["uint64"]},
      f: {"AUCTION_DURATION_BLOCKS()", "view", ["uint64"]},
      f: {"CLAIM_DELAY_BLOCKS()", "view", ["uint64"]},
      f: {"MIGRATION_DELAY_BLOCKS()", "view", ["uint64"]},
      f: {"FLOOR_PRICE_Q96()", "view", ["uint256"]},
      f: {"BID_TICK_Q96()", "view", ["uint256"]},
      f: {"AUCTION_ALLOCATION()", "view", ["uint128"]},
      f: {"RESERVE_ALLOCATION()", "view", ["uint128"]},
      f: {"PENDING_ALLOCATION()", "view", ["uint256"]},
      f: {"POOL_FEE()", "view", ["uint24"]},
      f: {"POOL_TICK_SPACING()", "view", ["int24"]},
      f: {"MAX_REACHABLE_RAISE()", "view", ["uint128"]},
      f: {"auctionOfSubject(address)", "view", ["address"]},
      f:
        {"distribution(address)", "view",
         [
           "(uint8,uint64,uint64,uint64,uint64,uint128,uint128,uint128,uint128,uint160,uint256,address,address,address,address,address,bytes32,uint256)"
         ]},
      f: {"migrate(address)", "nonpayable", []},
      e:
        {"DistributionCreated(uint256,address,address,address,address,uint64,uint64,uint128,uint128)",
         [true, true, true, false, false, false, false, false, false]},
      e:
        {"LaunchGraduated(address,address,bytes32,address,address,uint160,uint256,uint128,uint128)",
         [true, true, true, false, false, false, false, false, false]},
      e: {"LaunchRetired(address,address,uint128)", [true, true, false]}
    ],
    "auction" => [
      f: {"submitBid(uint256,uint128,address,uint256,bytes)", "payable", ["uint256"]},
      f: {"exitBid(uint256)", "nonpayable", []},
      f: {"exitPartiallyFilledBid(uint256,uint64,uint64)", "nonpayable", []},
      f: {"claimTokens(uint256)", "nonpayable", []},
      f: {"bids(uint256)", "view", ["(uint64,uint24,uint64,uint256,address,uint256,uint256)"]},
      f: {"checkpoints(uint64)", "view", ["(uint256,uint256,uint256,uint24,uint64,uint64)"]},
      f: {"startBlock()", "view", ["uint64"]},
      f: {"endBlock()", "view", ["uint64"]},
      f: {"claimBlock()", "view", ["uint64"]},
      f: {"isGraduated()", "view", ["bool"]},
      f: {"clearingPrice()", "view", ["uint256"]},
      f: {"currency()", "view", ["address"]},
      f: {"floorPrice()", "view", ["uint256"]},
      f: {"tickSpacing()", "view", ["uint256"]},
      f: {"MAX_BID_PRICE()", "view", ["uint256"]},
      f: {"checkpoint()", "nonpayable", ["(uint256,uint256,uint256,uint24,uint64,uint64)"]},
      f: {"ticks(uint256)", "view", ["(uint256,uint256)"]},
      e: {"BidSubmitted(uint256,address,uint256,uint128)", [true, true, false, false]},
      e: {"BidExited(uint256,address,uint256,uint256)", [true, true, false, false]},
      e: {"TokensClaimed(uint256,address,uint256)", [true, true, false]}
    ],
    "permit2" => [
      f: {"approve(address,address,uint160,uint48)", "nonpayable", []},
      f: {"allowance(address,address,address)", "view", ["uint160", "uint48", "uint48"]}
    ],
    # The pool page reads the frozen fee hook's settled swap fees for a pool.
    "hook" => [
      e: {@swap_fee_settled, [true, true, true, false, false, false]}
    ],
    "token" => [
      f: {"approve(address,uint256)", "nonpayable", ["bool"]},
      f: {"balanceOf(address)", "view", ["uint256"]},
      f: {"allowance(address,address)", "view", ["uint256"]},
      e: {"Approval(address,address,uint256)", [true, true, false]}
    ]
  }

  @uint256_max Integer.pow(2, 256) - 1
  @zero_address "0x" <> String.duplicate("0", 40)

  @doc false
  def required_signatures do
    Map.new(@required, fn {contract, requirements} ->
      {contract,
       Enum.map(requirements, fn
         {:f, {signature, _mutability, _outputs}} -> signature
         {:e, {signature, _indexed}} -> signature
       end)}
    end)
  end

  @doc false
  def requirements, do: @required

  def swap_fee_settled_signature, do: @swap_fee_settled

  def validate(abis, required \\ @required)

  def validate(abis, required) when is_map(abis) and is_map(required) do
    Enum.reduce_while(required, :ok, fn {contract, requirements}, :ok ->
      abi = Map.get(abis, contract, [])

      case Enum.find(requirements, &(not requirement_declared?(abi, &1))) do
        nil -> {:cont, :ok}
        _missing -> {:halt, {:error, :missing_required_abi}}
      end
    end)
  end

  def validate(_abis, _required), do: {:error, :invalid_abis}

  def declared?(abi, signature) when is_list(abi) and is_binary(signature) do
    Enum.any?(abi, &(canonical_signature(&1) == signature))
  end

  defp requirement_declared?(abi, {:f, {signature, mutability, outputs}}) do
    Enum.any?(abi, fn entry ->
      entry["type"] == "function" and canonical_signature(entry) == signature and
        entry["stateMutability"] == mutability and
        Enum.map(entry["outputs"] || [], &canonical_type/1) == outputs
    end)
  end

  defp requirement_declared?(abi, {:e, {signature, indexed}}) do
    Enum.any?(abi, fn entry ->
      entry["type"] == "event" and canonical_signature(entry) == signature and
        entry["anonymous"] == false and
        Enum.map(entry["inputs"] || [], & &1["indexed"]) == indexed
    end)
  end

  def function!(abi, signature) do
    Enum.find(abi, fn entry ->
      entry["type"] == "function" and canonical_signature(entry) == signature and
        entry["stateMutability"] in ["pure", "view", "nonpayable", "payable"] and
        is_list(entry["outputs"])
    end) || raise ArgumentError, "lab ABI is missing #{signature}"
  end

  def event!(abi, signature) do
    Enum.find(abi, fn entry ->
      entry["type"] == "event" and canonical_signature(entry) == signature and
        Enum.all?(entry["inputs"] || [], &is_boolean(&1["indexed"]))
    end) || raise ArgumentError, "lab ABI is missing #{signature}"
  end

  def encode(abi, signature, arguments) when is_list(arguments) do
    entry = function!(abi, signature)
    inputs = entry["inputs"] || []

    if length(inputs) != length(arguments) do
      raise ArgumentError, "ABI argument count does not match #{signature}"
    end

    selector(signature) <> encode_sequence(inputs, arguments)
  end

  def selector(signature), do: String.slice(Abi.topic0(signature), 0, 10)
  def topic(signature), do: Abi.topic0(signature)

  def decode_words("0x" <> hex) when rem(byte_size(hex), 64) == 0 do
    {:ok,
     for <<word::binary-size(64) <- hex>> do
       case Base.decode16(word, case: :mixed) do
         {:ok, bytes} -> :binary.decode_unsigned(bytes)
         :error -> throw(:invalid_word)
       end
     end}
  catch
    :invalid_word -> {:error, :invalid_chain_response}
  end

  def decode_words(_value), do: {:error, :invalid_chain_response}

  def event_words(abi, signature, logs, emitter) do
    entry = event!(abi, signature)
    inputs = entry["inputs"]
    indexed = Enum.count(inputs, & &1["indexed"])
    data_words = length(inputs) - indexed
    Abi.one_event(logs, topic(signature), emitter, indexed, data_words)
  end

  def canonical_signature(%{"type" => type, "name" => name, "inputs" => inputs})
      when type in ["function", "event"] and is_binary(name) and is_list(inputs) do
    "#{name}(#{Enum.map_join(inputs, ",", &canonical_type/1)})"
  end

  def canonical_signature(_entry), do: nil

  defp canonical_type(%{"type" => "tuple", "components" => components}) when is_list(components),
    do: "(" <> Enum.map_join(components, ",", &canonical_type/1) <> ")"

  defp canonical_type(%{"type" => type}) when is_binary(type), do: type

  defp encode_sequence(types, values) do
    head_size = Enum.reduce(types, 0, &(&2 + head_size(&1)))

    {head, tail, _offset} =
      types
      |> Enum.zip(values)
      |> Enum.reduce({[], [], head_size}, fn {type, value}, {head, tail, offset} ->
        if dynamic?(type) do
          encoded = encode_dynamic(type, value)
          {[word(offset) | head], [encoded | tail], offset + div(byte_size(encoded), 2)}
        else
          {[encode_static(type, value) | head], tail, offset}
        end
      end)

    Enum.join(Enum.reverse(head)) <> Enum.join(Enum.reverse(tail))
  end

  defp dynamic?(%{"type" => type}) when type in ["string", "bytes"], do: true

  defp dynamic?(%{"type" => "tuple", "components" => components}),
    do: Enum.any?(components, &dynamic?/1)

  defp dynamic?(_type), do: false

  defp head_size(type), do: if(dynamic?(type), do: 32, else: static_size(type))

  defp static_size(%{"type" => "tuple", "components" => components}),
    do: Enum.reduce(components, 0, &(&2 + static_size(&1)))

  defp static_size(_type), do: 32

  defp encode_dynamic(%{"type" => "string"}, value) when is_binary(value),
    do: encode_bytes(value)

  defp encode_dynamic(%{"type" => "bytes"}, "0x" <> hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> encode_bytes(bytes)
      :error -> raise ArgumentError, "invalid bytes"
    end
  end

  defp encode_dynamic(%{"type" => "tuple", "components" => components}, value),
    do: encode_sequence(components, tuple_values!(components, value))

  defp encode_static(%{"type" => "tuple", "components" => components}, value),
    do: encode_sequence(components, tuple_values!(components, value))

  # The zero address is not an account and `Address` refuses it everywhere else;
  # here it is the exact "no subject splitter" word the Stocks launch takes.
  defp encode_static(%{"type" => "address"}, @zero_address), do: String.duplicate("0", 64)

  defp encode_static(%{"type" => "address"}, value) do
    case Address.normalize(value) do
      {:ok, address} -> address |> String.trim_leading("0x") |> String.pad_leading(64, "0")
      :error -> raise ArgumentError, "invalid address"
    end
  end

  defp encode_static(%{"type" => "bool"}, value) when is_boolean(value),
    do: word(if(value, do: 1, else: 0))

  defp encode_static(%{"type" => "uint" <> width}, value)
       when is_integer(value) and value >= 0 do
    bits = if(width == "", do: 256, else: String.to_integer(width))

    if bits in 8..256//8 and value < Integer.pow(2, bits),
      do: word(value),
      else: raise(ArgumentError, "unsigned integer is out of range")
  end

  defp encode_static(%{"type" => "bytes" <> width}, "0x" <> hex) when width != "" do
    bytes = String.to_integer(width)

    if bytes in 1..32 and byte_size(hex) == bytes * 2 and String.match?(hex, ~r/\A[0-9a-fA-F]+\z/) do
      String.downcase(String.pad_trailing(hex, 64, "0"))
    else
      raise ArgumentError, "fixed bytes are invalid"
    end
  end

  defp encode_static(type, _value),
    do: raise(ArgumentError, "unsupported lab ABI input #{inspect(type["type"])}")

  defp tuple_values!(components, values)
       when is_list(values) and length(components) == length(values),
       do: values

  defp tuple_values!(components, values) when is_map(values) do
    Enum.map(components, &tuple_value(values, &1["name"]))
  end

  defp tuple_values!(_components, _values), do: raise(ArgumentError, "invalid tuple")

  defp tuple_value(values, name) do
    case Map.fetch(values, name) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(values, &named_tuple_value(&1, name))
    end
  end

  defp named_tuple_value({key, value}, name) do
    if to_string(key) == name, do: value
  end

  defp encode_bytes(bytes) do
    hex = Base.encode16(bytes, case: :lower)
    padding = rem(64 - rem(byte_size(hex), 64), 64)
    word(byte_size(bytes)) <> hex <> String.duplicate("0", padding)
  end

  defp word(value) when is_integer(value) and value in 0..@uint256_max,
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")
end
