defmodule Autolaunch.TreasuryChainClient do
  @moduledoc """
  Read-only Base evidence for immutable treasury classification.

  Every state read is pinned to one EIP-1898 block identity. Transaction and
  receipt evidence is canonicalized through its own receipt block, then the
  complete Safe configuration is read again at that historical block.
  """

  alias Autolaunch.Chain.{Address, Rpc}
  alias Autolaunch.TreasurySecurity

  @manifest_path Path.expand("../../contracts/treasury-security-evidence.yaml", __DIR__)
  @external_resource @manifest_path
  @manifest YamlElixir.read_from_file!(@manifest_path)

  @rpc_opts [client_key: :autolaunch_treasury_http_client, log_scope: "autolaunch treasury"]
  @zero "0x0000000000000000000000000000000000000000"
  @sentinel "0x0000000000000000000000000000000000000001"
  @page_size 100
  @max_module_pages 32

  @version_selector "0xffa1ad74"
  @owners_selector "0xa0e67e2b"
  @threshold_selector "0xe75235b8"
  @modules_selector "0xcc2f8452"
  @exec_selector "0x6a761202"
  @execution_success "0x442e715f626346e8c54381002da614f62bee8d27386535b2521ec8540898556e"
  @transfer "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

  @singleton get_in(@manifest, ["safe", "singleton", "address"])
  @singleton_hash get_in(@manifest, ["safe", "singleton", "code_keccak256"])
  @safe_version get_in(@manifest, ["safe", "singleton", "version"])
  @proxy_runtime_hash get_in(@manifest, ["safe", "proxy_runtime", "runtime_keccak256"])
  @compatibility_fallback get_in(@manifest, ["safe", "compatibility_fallback_handler", "address"])
  @compatibility_fallback_hash get_in(@manifest, [
                                 "safe",
                                 "compatibility_fallback_handler",
                                 "code_keccak256"
                               ])
  @guard_slot get_in(@manifest, ["safe", "storage_slots", "guard"])
  @fallback_slot get_in(@manifest, ["safe", "storage_slots", "fallback_handler"])
  @usdc get_in(@manifest, ["tokens", "usdc"])
  @regent get_in(@manifest, ["tokens", "regent"])

  @type evidence_hashes :: %{
          usdc: String.t() | nil,
          regent: String.t() | nil,
          outbound: String.t() | nil
        }

  @callback observe(String.t(), evidence_hashes()) :: {:ok, map()} | {:error, atom()}
  @callback canonical?(non_neg_integer(), String.t()) :: boolean()

  def observe(address, evidence) do
    case module() do
      __MODULE__ -> read_observation(address, evidence)
      module -> module.observe(address, evidence)
    end
  end

  def canonical?(number, hash) do
    case module() do
      __MODULE__ -> canonical_block?(number, hash)
      module -> module.canonical?(number, hash)
    end
  end

  def module do
    configured = Application.get_env(:autolaunch, :autolaunch_treasury_chain_client, __MODULE__)

    if configured == __MODULE__ and System.get_env("AUTOLAUNCH_BROWSER_TEST") == "1" do
      Autolaunch.TestAutolaunchTreasuryChainClient
    else
      configured
    end
  end

  defp read_observation(address, evidence) do
    with {:ok, block} <- Rpc.safe_block(@rpc_opts),
         {:ok, runtime} <- code(address, block),
         {:ok, observation} <- classify(address, runtime, block) do
      attach_evidence(address, observation, evidence)
    end
  end

  defp classify(_address, "0x" = runtime, block), do: {:ok, base(runtime, block)}

  defp classify(_address, "0xef0100" <> delegate = runtime, block)
       when byte_size(delegate) == 40,
       do: {:ok, base(runtime, block)}

  defp classify(address, runtime, block) do
    runtime_hash = keccak(runtime)

    if runtime_hash == @proxy_runtime_hash do
      with {:ok, config} <- safe_config(address, block),
           do: {:ok, Map.merge(base(runtime, block), config)}
    else
      {:ok, base(runtime, block)}
    end
  end

  defp base(runtime, block) do
    %{
      block: block,
      runtime_code: runtime,
      runtime_identity: keccak(runtime),
      admitted_safe?: false,
      admitted_split?: false,
      safe_singleton: nil,
      safe_version: nil,
      owners: [],
      threshold: nil,
      modules: [],
      guard: @zero,
      fallback_handler: @zero,
      fallback_admitted?: false,
      evidence: %{}
    }
  end

  defp safe_config(address, block) do
    with {:ok, runtime} <- code(address, block),
         true <- keccak(runtime) == @proxy_runtime_hash,
         {:ok, singleton} <- storage_address(address, "0x0", block),
         true <- singleton == @singleton,
         {:ok, singleton_code} <- code(singleton, block),
         true <- keccak(singleton_code) == @singleton_hash,
         {:ok, version_raw} <- call(address, @version_selector, block),
         {:ok, @safe_version} <- decode_string(version_raw),
         {:ok, owners_raw} <- call(address, @owners_selector, block),
         {:ok, owners} <- decode_address_array(owners_raw),
         true <- owners != [],
         true <- Enum.all?(owners, &(&1 != @zero)),
         {:ok, threshold_raw} <- call(address, @threshold_selector, block),
         {:ok, threshold} <- decode_uint(threshold_raw),
         true <- threshold > 0 and threshold <= length(owners),
         {:ok, modules} <- modules(address, block),
         {:ok, guard} <- optional_storage_address(address, @guard_slot, block),
         {:ok, fallback} <- optional_storage_address(address, @fallback_slot, block),
         {:ok, fallback_admitted?} <- fallback_admitted?(fallback, block) do
      {:ok,
       %{
         admitted_safe?: true,
         safe_singleton: singleton,
         safe_version: @safe_version,
         owners: owners,
         threshold: threshold,
         modules: modules,
         guard: guard,
         fallback_handler: fallback,
         fallback_admitted?: fallback_admitted?,
         runtime_identity: keccak(runtime),
         runtime_code: runtime
       }}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :treasury_safe_evidence_mismatch}
      _malformed -> {:error, :treasury_observation_incomplete}
    end
  end

  defp attach_evidence(_address, %{admitted_safe?: false} = observation, _hashes),
    do: {:ok, observation}

  defp attach_evidence(address, observation, hashes) do
    fingerprint = TreasurySecurity.fingerprint(address, observation)

    with {:ok, usdc} <-
           token_evidence(address, hashes.usdc, @usdc, observation.block, fingerprint),
         {:ok, regent} <-
           token_evidence(address, hashes.regent, @regent, observation.block, fingerprint),
         {:ok, outbound} <-
           outbound_evidence(address, hashes.outbound, observation.block, fingerprint) do
      {:ok, %{observation | evidence: %{usdc: usdc, regent: regent, outbound: outbound}}}
    end
  end

  defp token_evidence(_safe, nil, _token, _block, _fingerprint), do: {:ok, nil}

  defp token_evidence(safe, hash, token, safe_block, fingerprint) do
    with {:ok, transaction, receipt, receipt_block} <- canonical_receipt(hash, safe_block),
         true <- is_map(transaction),
         {:ok, historical} <- safe_config(safe, receipt_block),
         ^fingerprint <-
           TreasurySecurity.fingerprint(safe, Map.merge(historical, %{block: receipt_block})),
         {:ok, log, amount} <- transfer_log(receipt["logs"], token, safe),
         {:ok, log_index} <- quantity(log["logIndex"]),
         :ok <- log_identity(log, hash, receipt_block) do
      {:ok,
       %{
         verified: true,
         transaction_hash: String.downcase(hash),
         receipt_block_number: receipt_block.number,
         receipt_block_hash: receipt_block.hash,
         log_index: log_index,
         token: token,
         amount: Integer.to_string(amount),
         safe_address: safe,
         historical_fingerprint: fingerprint,
         decoded: "erc20_transfer_into_safe"
       }}
    else
      false -> {:error, :treasury_evidence_invalid}
      {:error, reason} -> {:error, reason}
      _mismatch -> {:error, :treasury_configuration_drift}
    end
  end

  defp outbound_evidence(_safe, nil, _block, _fingerprint), do: {:ok, nil}

  defp outbound_evidence(safe, hash, safe_block, fingerprint) do
    with {:ok, transaction, receipt, receipt_block} <- canonical_receipt(hash, safe_block),
         {:ok, target} <- Address.normalize(transaction["to"]),
         true <- target == safe,
         {:ok, call} <- decode_exec(transaction["input"]),
         true <- call.operation == 0 and call.target != safe,
         true <- call.value > 0 or call.data != "0x",
         {:ok, historical} <- safe_config(safe, receipt_block),
         ^fingerprint <-
           TreasurySecurity.fingerprint(safe, Map.merge(historical, %{block: receipt_block})),
         {:ok, log} <- execution_success(receipt["logs"], safe),
         {:ok, log_index} <- quantity(log["logIndex"]),
         :ok <- log_identity(log, hash, receipt_block) do
      {:ok,
       %{
         verified: true,
         transaction_hash: String.downcase(hash),
         receipt_block_number: receipt_block.number,
         receipt_block_hash: receipt_block.hash,
         log_index: log_index,
         safe_address: safe,
         target: call.target,
         value: Integer.to_string(call.value),
         operation: "CALL",
         historical_fingerprint: fingerprint,
         decoded: "safe_exec_transaction_success"
       }}
    else
      false -> {:error, :treasury_evidence_invalid}
      {:error, reason} -> {:error, reason}
      _mismatch -> {:error, :treasury_configuration_drift}
    end
  end

  defp canonical_receipt(hash, safe_block) do
    with true <- Rpc.valid_hash?(hash),
         {:ok, receipt} <- Rpc.request("eth_getTransactionReceipt", [hash], @rpc_opts),
         {:ok, transaction} <- Rpc.request("eth_getTransactionByHash", [hash], @rpc_opts),
         true <- is_map(receipt) and is_map(transaction),
         true <- downcase(receipt["transactionHash"]) == downcase(hash),
         true <- downcase(transaction["hash"]) == downcase(hash),
         true <- receipt["status"] == "0x1" and is_list(receipt["logs"]),
         {:ok, number} <- quantity(receipt["blockNumber"]),
         true <- number <= safe_block.number,
         hash when is_binary(hash) <- receipt["blockHash"],
         true <- Rpc.valid_hash?(hash),
         true <- downcase(transaction["blockHash"]) == downcase(hash),
         {:ok, ^number} <- quantity(transaction["blockNumber"]),
         {:ok, header} <- Rpc.request("eth_getBlockByNumber", [hex(number), false], @rpc_opts),
         true <- is_map(header),
         {:ok, ^number} <- quantity(header["number"]),
         true <- downcase(header["hash"]) == downcase(hash) do
      {:ok, transaction, receipt, %{number: number, hash: downcase(hash)}}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :treasury_evidence_invalid}
    end
  end

  defp modules(address, block), do: modules(address, block, @sentinel, MapSet.new(), [], 0)

  defp modules(_address, _block, _start, _seen, _modules, @max_module_pages),
    do: {:error, :treasury_module_pagination_incomplete}

  defp modules(address, block, start, seen, modules, pages) do
    if MapSet.member?(seen, start) do
      {:error, :treasury_module_pagination_cycle}
    else
      data = @modules_selector <> word_address(start) <> word_uint(@page_size)

      with {:ok, raw} <- call(address, data, block),
           {:ok, page, next} <- decode_modules_page(raw),
           true <- Enum.all?(page, &(&1 != @zero)),
           combined <- modules ++ page,
           true <- length(combined) == length(Enum.uniq(combined)) do
        continue_modules(address, block, next, MapSet.put(seen, start), combined, pages)
      else
        {:error, reason} -> {:error, reason}
        _invalid -> {:error, :treasury_module_pagination_incomplete}
      end
    end
  end

  defp continue_modules(_address, _block, @sentinel, _seen, combined, _pages),
    do: {:ok, combined}

  defp continue_modules(address, block, next, seen, combined, pages),
    do: modules(address, block, next, seen, combined, pages + 1)

  defp transfer_log(logs, token, safe) do
    matches =
      Enum.filter(logs, fn
        %{"address" => emitter, "topics" => [topic, _from, to], "data" => data} ->
          Address.equal?(emitter, token) and downcase(topic) == @transfer and
            topic_address(to) == {:ok, safe} and positive_word?(data)

        _ ->
          false
      end)

    case matches do
      [%{"data" => data} = log] -> {:ok, log, word_value!(data)}
      _ -> {:error, :treasury_transfer_evidence_invalid}
    end
  end

  defp execution_success(logs, safe) do
    matches =
      Enum.filter(logs, fn
        %{"address" => emitter, "topics" => [topic, tx_hash], "data" => data} ->
          Address.equal?(emitter, safe) and downcase(topic) == @execution_success and
            word?(tx_hash) and word?(data)

        _ ->
          false
      end)

    case matches do
      [log] -> {:ok, log}
      _ -> {:error, :treasury_execution_evidence_invalid}
    end
  end

  defp decode_exec(@exec_selector <> body) when rem(byte_size(body), 64) == 0 do
    with {:ok, target} <- word_address_at(body, 0),
         {:ok, value} <- word_uint_at(body, 1),
         {:ok, data_offset} <- word_uint_at(body, 2),
         {:ok, operation} <- word_uint_at(body, 3),
         {:ok, data} <- dynamic_bytes(body, data_offset) do
      {:ok, %{target: target, value: value, data: data, operation: operation}}
    end
  end

  defp decode_exec(_input), do: {:error, :treasury_execution_input_invalid}

  defp decode_string("0x" <> body) do
    with {:ok, 32} <- word_uint_at(body, 0),
         {:ok, size} <- word_uint_at(body, 1),
         true <- size <= 128,
         bytes when byte_size(bytes) == size * 2 <- binary_part(body, 128, size * 2),
         {:ok, decoded} <- Base.decode16(bytes, case: :mixed),
         true <- String.valid?(decoded) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_chain_response}
    end
  end

  defp decode_address_array("0x" <> body) do
    with {:ok, 32} <- word_uint_at(body, 0),
         {:ok, count} <- word_uint_at(body, 1),
         true <- count <= 256,
         true <- byte_size(body) == (2 + count) * 64 do
      body
      |> words(2, count)
      |> addresses()
    else
      _ -> {:error, :invalid_chain_response}
    end
  end

  defp decode_modules_page("0x" <> body) do
    with {:ok, 64} <- word_uint_at(body, 0),
         {:ok, next} <- word_address_at(body, 1),
         {:ok, count} <- word_uint_at(body, 2),
         true <- count <= @page_size,
         true <- byte_size(body) == (3 + count) * 64,
         {:ok, page} <- body |> words(3, count) |> addresses() do
      {:ok, page, next}
    else
      _ -> {:error, :invalid_chain_response}
    end
  end

  defp decode_uint("0x" <> body) when byte_size(body) == 64, do: word_uint_at(body, 0)
  defp decode_uint(_raw), do: {:error, :invalid_chain_response}

  defp storage_address(address, slot, block) do
    with {:ok, raw} <- request("eth_getStorageAt", [address, slot, block_ref(block)]),
         do: decode_word_address(raw)
  end

  defp optional_storage_address(address, slot, block) do
    with {:ok, raw} <- request("eth_getStorageAt", [address, slot, block_ref(block)]),
         do: decode_optional_word_address(raw)
  end

  defp fallback_admitted?(@zero, _block), do: {:ok, true}

  defp fallback_admitted?(@compatibility_fallback, block) do
    with {:ok, runtime} <- code(@compatibility_fallback, block),
         do: {:ok, keccak(runtime) == @compatibility_fallback_hash}
  end

  defp fallback_admitted?(_fallback, _block), do: {:ok, false}

  defp code(address, block) do
    with {:ok, code} when is_binary(code) <-
           request("eth_getCode", [address, block_ref(block)]),
         "0x" <> hex <- code,
         true <- rem(byte_size(hex), 2) == 0,
         {:ok, _bytes} <- Base.decode16(hex, case: :mixed) do
      {:ok, downcase(code)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_chain_response}
    end
  end

  defp call(address, data, block),
    do: request("eth_call", [%{to: address, data: data}, block_ref(block)])

  defp canonical_block?(number, hash) do
    with {:ok, header} when is_map(header) <-
           request("eth_getBlockByNumber", [hex(number), false]),
         {:ok, ^number} <- quantity(header["number"]),
         canonical when is_binary(canonical) <- header["hash"],
         true <- Rpc.valid_hash?(canonical),
         true <- Rpc.valid_hash?(hash) do
      downcase(canonical) == downcase(hash)
    else
      _ -> false
    end
  end

  defp request(method, params), do: Rpc.request(method, params, @rpc_opts)
  defp block_ref(%{hash: hash}), do: %{blockHash: hash, requireCanonical: true}

  defp decode_word_address("0x" <> word) when byte_size(word) == 64 do
    if String.slice(word, 0, 24) == String.duplicate("0", 24),
      do: Address.normalize("0x" <> String.slice(word, 24, 40)),
      else: {:error, :invalid_chain_response}
  end

  defp decode_word_address(_word), do: {:error, :invalid_chain_response}

  defp decode_optional_word_address("0x" <> word = raw) when byte_size(word) == 64 do
    if word == String.duplicate("0", 64), do: {:ok, @zero}, else: decode_word_address(raw)
  end

  defp decode_optional_word_address(_word), do: {:error, :invalid_chain_response}

  defp log_identity(log, transaction_hash, block) do
    with true <- downcase(log["transactionHash"]) == downcase(transaction_hash),
         true <- downcase(log["blockHash"]) == downcase(block.hash),
         {:ok, number} <- quantity(log["blockNumber"]),
         true <- number == block.number do
      :ok
    else
      _ -> {:error, :treasury_evidence_invalid}
    end
  end

  defp words(_body, _start, 0), do: []

  defp words(body, start, count) do
    for index <- start..(start + count - 1), do: binary_part(body, index * 64, 64)
  end

  defp addresses(words) do
    Enum.reduce_while(words, {:ok, []}, fn word, {:ok, values} ->
      case decode_word_address("0x" <> word) do
        {:ok, address} -> {:cont, {:ok, values ++ [address]}}
        _ -> {:halt, {:error, :invalid_chain_response}}
      end
    end)
  end

  defp word_address_at(body, index),
    do: decode_word_address("0x" <> binary_part(body, index * 64, 64))

  defp word_uint_at(body, index) do
    word = binary_part(body, index * 64, 64)

    case Integer.parse(word, 16) do
      {value, ""} -> {:ok, value}
      _ -> {:error, :invalid_chain_response}
    end
  rescue
    _ -> {:error, :invalid_chain_response}
  end

  defp dynamic_bytes(body, offset) when rem(offset, 32) == 0 do
    index = div(offset, 32)

    with {:ok, size} <- word_uint_at(body, index),
         true <- size <= 131_072,
         start = (index + 1) * 64,
         bytes when byte_size(bytes) == size * 2 <- binary_part(body, start, size * 2),
         {:ok, _decoded} <- Base.decode16(bytes, case: :mixed) do
      {:ok, "0x" <> downcase(bytes)}
    else
      _ -> {:error, :treasury_execution_input_invalid}
    end
  rescue
    _ -> {:error, :treasury_execution_input_invalid}
  end

  defp dynamic_bytes(_body, _offset), do: {:error, :treasury_execution_input_invalid}

  defp word_address(address),
    do: address |> String.trim_leading("0x") |> String.pad_leading(64, "0")

  defp word_uint(value), do: value |> Integer.to_string(16) |> String.pad_leading(64, "0")

  defp topic_address("0x" <> word), do: decode_word_address("0x" <> word)
  defp topic_address(_topic), do: {:error, :invalid_chain_response}

  defp word?("0x" <> hex), do: byte_size(hex) == 64 and String.match?(hex, ~r/\A[0-9a-fA-F]+\z/)
  defp word?(_value), do: false
  defp positive_word?(value), do: word?(value) and word_value!(value) > 0
  defp word_value!("0x" <> hex), do: String.to_integer(hex, 16)

  defp quantity("0x0"), do: {:ok, 0}

  defp quantity("0x" <> <<first, _rest::binary>> = encoded)
       when first in ?1..?9 or first in ?a..?f do
    "0x" <> hex = encoded

    case Integer.parse(hex, 16) do
      {value, ""} when value >= 0 ->
        if encoded == hex(value), do: {:ok, value}, else: {:error, :invalid_chain_response}

      _ ->
        {:error, :invalid_chain_response}
    end
  end

  defp quantity(_value), do: {:error, :invalid_chain_response}
  defp hex(value), do: "0x" <> String.downcase(Integer.to_string(value, 16))

  defp keccak("0x" <> hex) do
    {:ok, bytes} = Base.decode16(hex, case: :mixed)
    "0x" <> Base.encode16(:jose_jwa_sha3.keccak(1088, 512, bytes, 1, 32), case: :lower)
  rescue
    _ -> "invalid"
  end

  defp downcase(value) when is_binary(value), do: String.downcase(value)
  defp downcase(_value), do: nil
end
