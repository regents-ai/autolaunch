defmodule Autolaunch.Chain.Rpc do
  @moduledoc false

  require Logger

  alias Autolaunch.Chain.Address

  @timeout 8_000
  @chain_id 8453

  @type block :: %{number: non_neg_integer(), hash: String.t()}

  def verify_base_chain(opts \\ []) do
    verify_chain(@chain_id, opts)
  end

  def verify_chain(expected_chain_id, opts \\ []) when is_integer(expected_chain_id) do
    with {:ok, result} <- request("eth_chainId", [], opts),
         {:ok, chain_id} <- quantity(result),
         true <- chain_id == expected_chain_id do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :wrong_chain}
      _ -> {:error, :invalid_chain_response}
    end
  end

  def confirmed_transaction(hash, signer, to, data, opts \\ []) do
    case confirmed_transaction_receipt(hash, signer, to, data, opts) do
      {:ok, _receipt} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def confirmed_transaction_receipt(hash, signer, to, data, opts \\ []) do
    with :ok <- verify_chain(Keyword.get(opts, :expected_chain_id, @chain_id), opts),
         {:ok, receipt} <- identified_receipt(hash, signer, to, data, opts) do
      case receipt do
        %{"status" => "0x1", "blockNumber" => block} when is_binary(block) ->
          {:ok, receipt}

        %{"status" => "0x0", "blockNumber" => block} when is_binary(block) ->
          {:error, :transaction_reverted}

        nil ->
          {:error, :transaction_pending}

        _ ->
          {:error, :invalid_receipt}
      end
    end
  end

  def submission_status(hash, signer, to, data, opts \\ []) do
    case confirmed_transaction_receipt(hash, signer, to, data, opts) do
      {:ok, _receipt} -> {:ok, :success}
      {:error, :transaction_reverted} -> {:ok, :reverted}
      {:error, :transaction_pending} -> {:ok, :pending}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  One `safe` Base block, accepted only after the chain identity is proved.

  Every read of a snapshot is then executed against this exact block hash, so a
  page never mixes two histories and a moved block fails rather than answering.
  """
  @spec safe_block(keyword()) :: {:ok, block()} | {:error, atom()}
  def safe_block(opts \\ []) do
    with :ok <- verify_base_chain(opts),
         {:ok, header} <- request("eth_getBlockByNumber", ["safe", false], opts),
         do: block_identity(header)
  end

  @doc "The latest block from an explicitly selected chain endpoint."
  @spec latest_block(keyword()) :: {:ok, block()} | {:error, atom()}
  def latest_block(opts \\ []) do
    expected_chain_id = Keyword.get(opts, :expected_chain_id, @chain_id)

    with :ok <- verify_chain(expected_chain_id, opts),
         {:ok, header} <- request("eth_getBlockByNumber", ["latest", false], opts),
         do: block_identity(header)
  end

  @doc """
  The exact canonical outcome of one submitted transaction against one safe head.

  `:pending` is every state that may still resolve differently: a hash this RPC
  has not observed yet, no receipt yet, a receipt above the safe head, and a
  receipt whose block is no longer canonical. Success and revert are both read
  only from a receipt that is already canonical, so neither can be reported from
  a block this transaction may yet leave.

  The safe block passed in already proved the chain identity, so nothing here
  asks for it a second time.
  """
  @spec canonical_outcome(String.t(), String.t(), String.t(), String.t(), block(), keyword()) ::
          {:ok, :pending | :reverted | {:success, [map()]}} | {:error, atom()}
  def canonical_outcome(hash, signer, to, data, safe_block, opts \\ []) do
    with {:ok, %{outcome: outcome}} <-
           canonical_outcome_evidence(hash, signer, to, data, safe_block, opts),
         do: {:ok, outcome}
  end

  @doc "Canonical receipt evidence without changing the legacy outcome API."
  def canonical_outcome_evidence(hash, signer, to, data, safe_block, opts) do
    with {:ok, receipt} <- identified_receipt(hash, signer, to, data, opts),
         {:ok, number, block_hash} <- receipt_block(receipt),
         :ok <- canonical(number, block_hash, safe_block, opts),
         {:ok, outcome} <- settled(receipt) do
      {:ok, %{outcome: outcome, receipt: receipt}}
    else
      {:ok, :pending} -> {:ok, %{outcome: :pending, receipt: nil}}
      error -> error
    end
  end

  def call_uint(to, data, block, opts \\ []), do: call(to, data, block, &decode_uint/1, opts)

  def call_bool(to, data, block, opts \\ []),
    do: call(to, data, block, &(decode_uint(&1) != 0), opts)

  def call_address(to, data, block, opts \\ []),
    do: call(to, data, block, &decode_address/1, opts)

  def call_words(to, data, block, count, opts \\ []) when is_integer(count) and count > 0 do
    call(to, data, block, &decode_words(&1, count), opts)
  end

  def request(method, params, opts \\ []) do
    request = %{jsonrpc: "2.0", id: 1, method: method, params: params}

    client =
      Application.get_env(
        :autolaunch,
        Keyword.get(opts, :client_key, :wallet_http_client),
        Req
      )

    rpc_url =
      Keyword.get_lazy(opts, :rpc_url, fn ->
        Application.fetch_env!(:autolaunch, :base_read_rpc_url)
      end)

    case client.post(rpc_url,
           json: request,
           # Fly private-network names (.internal) publish only AAAA records;
           # inet6 makes Mint try IPv6 first and still fall back to IPv4.
           connect_options: [timeout: 3_000, transport_opts: [inet6: true]],
           pool_timeout: 3_000,
           receive_timeout: @timeout,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"result" => result}}} ->
        {:ok, result}

      {:ok, %{body: %{"error" => _error}}} ->
        {:error, :chain_unavailable}

      {:ok, _response} ->
        {:error, :chain_unavailable}

      {:error, reason} ->
        log_failure(method, reason, opts)
        {:error, :chain_unavailable}
    end
  rescue
    error ->
      log_failure(method, error, opts)
      {:error, :chain_unavailable}
  end

  def format_units(value, decimals) do
    value
    |> Decimal.new()
    |> Decimal.div(Decimal.new(Integer.pow(10, decimals)))
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  # `\z` and not `$`: `$` also matches before a trailing newline, which let
  # "0x" <> 63 hex <> "\n" pass the 64-byte guard as a canonical hash.
  def valid_hash?("0x" <> hash),
    do: byte_size(hash) == 64 and String.match?(hash, ~r/^[0-9a-fA-F]+\z/)

  def valid_hash?(_hash), do: false

  # EIP-1898: the block hash owns the read and `requireCanonical` refuses an
  # answer from a block that is no longer part of the chain.
  defp call(to, data, %{hash: hash}, decoder, opts) do
    with {:ok, result} <-
           request(
             "eth_call",
             [%{to: to, data: data}, %{blockHash: hash, requireCanonical: true}],
             opts
           ) do
      {:ok, decoder.(result)}
    end
  rescue
    _ -> {:error, :invalid_chain_response}
  end

  defp block_identity(%{"number" => number, "hash" => hash}) do
    with {:ok, number} <- quantity(number),
         true <- valid_hash?(hash) do
      {:ok, %{number: number, hash: String.downcase(hash)}}
    else
      _malformed -> {:error, :invalid_block_header}
    end
  end

  defp block_identity(_header), do: {:error, :invalid_block_header}

  defp identified_receipt(hash, signer, to, data, opts) do
    with true <- valid_hash?(hash),
         {:ok, receipt} <- request("eth_getTransactionReceipt", [hash], opts),
         {:ok, transaction} <- request("eth_getTransactionByHash", [hash], opts),
         :ok <- verify_receipt_hash(receipt, hash),
         :ok <- observed_identity(receipt, transaction, hash, signer, to, data) do
      {:ok, receipt}
    else
      false -> {:error, :invalid_confirmation}
      {:error, reason} -> {:error, reason}
    end
  end

  # A hash the wallet has just broadcast may not have reached this read RPC yet.
  # With neither a receipt nor the transaction itself, nothing has been observed
  # about it: the same hash stays pending rather than becoming unverifiable.
  defp observed_identity(nil, nil, _hash, _signer, _to, _data), do: :ok

  defp observed_identity(_receipt, transaction, hash, signer, to, data),
    do: verify_transaction(transaction, hash, signer, to, data)

  # `{:ok, :pending}` here is the whole answer: the `with` above carries it out
  # unchanged rather than reading a status this receipt does not have yet.
  defp receipt_block(nil), do: {:ok, :pending}

  defp receipt_block(%{"blockNumber" => number, "blockHash" => hash, "logs" => logs})
       when is_list(logs) do
    with {:ok, number} <- quantity(number),
         true <- valid_hash?(hash) do
      {:ok, number, String.downcase(hash)}
    else
      _malformed -> {:error, :invalid_receipt}
    end
  end

  defp receipt_block(_receipt), do: {:error, :invalid_receipt}

  # Above the safe head, and mined into a block that is no longer the canonical
  # one, are both states this transaction may still leave: neither is an answer,
  # whichever status the receipt carries right now.
  defp canonical(number, _hash, %{number: safe}, _opts) when number > safe, do: {:ok, :pending}

  defp canonical(number, hash, _safe, opts) do
    with {:ok, header} <- request("eth_getBlockByNumber", [hex_quantity(number), false], opts),
         {:ok, %{hash: ^hash}} <- block_identity(header) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _moved -> {:ok, :pending}
    end
  end

  defp settled(%{"status" => "0x1", "logs" => logs}), do: {:ok, {:success, logs}}
  defp settled(%{"status" => "0x0"}), do: {:ok, :reverted}
  defp settled(_receipt), do: {:error, :invalid_receipt}

  defp quantity("0x" <> hex) when hex != "" do
    case Integer.parse(hex, 16) do
      {value, ""} -> {:ok, value}
      _malformed -> :error
    end
  end

  defp quantity(_value), do: :error

  defp hex_quantity(value), do: "0x" <> (value |> Integer.to_string(16) |> String.downcase())

  defp verify_receipt_hash(nil, _hash), do: :ok

  defp verify_receipt_hash(%{"transactionHash" => receipt_hash}, hash)
       when is_binary(receipt_hash) do
    if String.downcase(receipt_hash) == String.downcase(hash),
      do: :ok,
      else: {:error, :receipt_mismatch}
  end

  defp verify_receipt_hash(_receipt, _hash), do: {:error, :invalid_receipt}

  defp verify_transaction(transaction, hash, signer, to, data) when is_map(transaction) do
    with {:ok, actual_signer} <- Address.normalize(transaction["from"]),
         {:ok, expected_signer} <- Address.normalize(signer),
         {:ok, actual_target} <- Address.normalize(transaction["to"]),
         {:ok, expected_target} <- Address.normalize(to),
         transaction_hash when is_binary(transaction_hash) <- transaction["hash"],
         true <- String.downcase(transaction_hash) == String.downcase(hash),
         true <- actual_signer == expected_signer,
         true <- actual_target == expected_target,
         true <- String.downcase(transaction["input"] || "") == String.downcase(data),
         true <- zero_quantity?(transaction["value"]) do
      :ok
    else
      _ -> {:error, :transaction_mismatch}
    end
  end

  defp verify_transaction(_transaction, _hash, _signer, _to, _data),
    do: {:error, :transaction_missing}

  defp decode_uint("0x" <> hex), do: String.to_integer(hex, 16)

  defp decode_address("0x" <> hex) when byte_size(hex) == 64 do
    {:ok, address} = Address.normalize("0x" <> String.slice(hex, -40, 40))
    address
  end

  defp decode_words("0x" <> hex, count) when byte_size(hex) == count * 64 do
    for <<word::binary-size(64) <- hex>>, do: String.to_integer(word, 16)
  end

  defp zero_quantity?(value) when value in ["0x0", "0x", "0"], do: true
  defp zero_quantity?(_value), do: false

  defp log_failure(method, reason, opts) do
    scope = Keyword.get(opts, :log_scope, "wallet")

    Logger.warning(
      "#{scope} chain read failed #{inspect(%{method: method, class: error_class(reason)})}"
    )
  end

  defp error_class(%Req.TransportError{reason: reason})
       when reason in [:timeout, :connect_timeout],
       do: :timeout

  defp error_class(%Req.TransportError{}), do: :transport
  defp error_class(_reason), do: :transport
end
