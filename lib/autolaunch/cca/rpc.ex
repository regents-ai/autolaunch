defmodule Autolaunch.CCA.Rpc do
  @moduledoc false

  def block_number(chain_id) do
    block_number(chain_id, [])
  end

  def block_number(chain_id, opts) do
    call_adapter(:block_number, [chain_id], opts)
  end

  def eth_call(chain_id, to, data) do
    eth_call(chain_id, to, data, [])
  end

  def eth_call(chain_id, to, data, opts) do
    call_adapter(:eth_call, [chain_id, to, data], opts)
  end

  def tx_receipt(chain_id, tx_hash) do
    tx_receipt(chain_id, tx_hash, [])
  end

  def tx_receipt(chain_id, tx_hash, opts) do
    call_adapter(:tx_receipt, [chain_id, tx_hash], opts)
  end

  def tx_by_hash(chain_id, tx_hash) do
    tx_by_hash(chain_id, tx_hash, [])
  end

  def tx_by_hash(chain_id, tx_hash, opts) do
    call_adapter(:tx_by_hash, [chain_id, tx_hash], opts)
  end

  def get_logs(chain_id, filter) do
    get_logs(chain_id, filter, [])
  end

  def get_logs(chain_id, filter, opts) do
    call_adapter(:get_logs, [chain_id, filter], opts)
  end

  def rpc_url(chain_id) do
    rpc_url(chain_id, [])
  end

  def rpc_url(chain_id, opts) do
    call_adapter(:rpc_url, [chain_id], opts)
  end

  defp rpc_adapter do
    Application.get_env(:autolaunch, :cca_rpc_adapter, __MODULE__.HttpAdapter)
  end

  defp call_adapter(function_name, args, opts) do
    adapter = rpc_adapter()

    if function_exported?(adapter, function_name, length(args) + 1) do
      apply(adapter, function_name, args ++ [opts])
    else
      apply(adapter, function_name, args)
    end
  end

  defmodule HttpAdapter do
    @moduledoc false

    @timeout 15_000

    def block_number(chain_id) do
      block_number(chain_id, [])
    end

    def block_number(chain_id, opts) do
      chain_id
      |> call("eth_blockNumber", [], opts)
      |> decode_quantity()
    end

    def eth_call(chain_id, to, data) do
      eth_call(chain_id, to, data, [])
    end

    def eth_call(chain_id, to, data, opts) do
      call(chain_id, "eth_call", [%{"to" => to, "data" => data}, "latest"], opts)
      |> normalize_hex_result()
    end

    def tx_receipt(chain_id, tx_hash) do
      tx_receipt(chain_id, tx_hash, [])
    end

    def tx_receipt(chain_id, tx_hash, opts) do
      case call(chain_id, "eth_getTransactionReceipt", [tx_hash], opts) do
        {:ok, nil} -> {:ok, nil}
        {:ok, %{} = receipt} -> {:ok, normalize_receipt(receipt)}
        {:error, _} = error -> error
        _ -> {:error, :invalid_rpc_response}
      end
    end

    def tx_by_hash(chain_id, tx_hash) do
      tx_by_hash(chain_id, tx_hash, [])
    end

    def tx_by_hash(chain_id, tx_hash, opts) do
      case call(chain_id, "eth_getTransactionByHash", [tx_hash], opts) do
        {:ok, nil} -> {:ok, nil}
        {:ok, %{} = tx} -> {:ok, normalize_transaction(tx)}
        {:error, _} = error -> error
        _ -> {:error, :invalid_rpc_response}
      end
    end

    def get_logs(chain_id, filter) when is_map(filter) do
      get_logs(chain_id, filter, [])
    end

    def get_logs(chain_id, filter, opts) when is_map(filter) do
      case call(chain_id, "eth_getLogs", [filter], opts) do
        {:ok, logs} when is_list(logs) -> {:ok, Enum.map(logs, &normalize_log/1)}
        {:error, _} = error -> error
        _ -> {:error, :invalid_rpc_response}
      end
    end

    def rpc_url(chain_id) do
      rpc_url(chain_id, [])
    end

    def rpc_url(chain_id, opts) do
      launch_config = Application.get_env(:autolaunch, :launch, [])
      regent_staking_config = Application.get_env(:autolaunch, :regent_staking, [])
      regent_staking_chain_id = Keyword.get(regent_staking_config, :chain_id)
      launch_chain_id = Keyword.get(launch_config, :chain_id)
      source = Keyword.get(opts, :source, :launch)
      chain_rpc_urls = Keyword.get(launch_config, :chain_rpc_urls, %{})

      cond do
        source == :regent_staking and is_integer(regent_staking_chain_id) and
            chain_id == regent_staking_chain_id ->
          fetch_url(regent_staking_config, :rpc_url)

        is_map(chain_rpc_urls) and is_binary(Map.get(chain_rpc_urls, chain_id)) and
            String.trim(Map.get(chain_rpc_urls, chain_id)) != "" ->
          {:ok, String.trim(Map.get(chain_rpc_urls, chain_id))}

        is_integer(launch_chain_id) and chain_id == launch_chain_id ->
          fetch_url(launch_config, :rpc_url)

        is_integer(regent_staking_chain_id) and chain_id == regent_staking_chain_id ->
          fetch_url(regent_staking_config, :rpc_url)

        true ->
          {:error, :invalid_chain_id}
      end
    end

    defp call(chain_id, method, params, opts) do
      with {:ok, rpc_url} <- rpc_url(chain_id, opts),
           {:ok, response} <-
             Req.post(rpc_url,
               json: %{
                 "jsonrpc" => "2.0",
                 "id" => System.unique_integer([:positive]),
                 "method" => method,
                 "params" => params
               },
               receive_timeout: @timeout,
               connect_options: [timeout: @timeout]
             ),
           {:ok, body} <- normalize_body(response.body) do
        case body do
          %{"result" => result} ->
            {:ok, result}

          %{"error" => %{"message" => message}} when is_binary(message) ->
            {:error, {:rpc_error, message}}

          _ ->
            {:error, :invalid_rpc_response}
        end
      end
    end

    defp fetch_url(config, key) do
      case Keyword.get(config, key, "") do
        value when is_binary(value) and value != "" -> {:ok, value}
        _ -> {:error, :missing_rpc_url}
      end
    end

    defp normalize_hex_result({:ok, <<"0x", _::binary>> = result}), do: {:ok, result}
    defp normalize_hex_result({:error, _} = error), do: error
    defp normalize_hex_result(_result), do: {:error, :invalid_rpc_response}

    defp decode_quantity({:ok, <<"0x", hex::binary>>}) when hex != "" do
      {:ok, String.to_integer(hex, 16)}
    end

    defp decode_quantity({:ok, _other}), do: {:error, :invalid_hex_quantity}
    defp decode_quantity({:error, _} = error), do: error

    defp normalize_body(%{} = body), do: {:ok, body}
    defp normalize_body(_body), do: {:error, :invalid_rpc_response}

    defp normalize_receipt(receipt) do
      %{
        transaction_hash: Map.get(receipt, "transactionHash"),
        status: decode_optional_quantity(Map.get(receipt, "status")),
        block_number: decode_optional_quantity(Map.get(receipt, "blockNumber")),
        from: normalize_address(Map.get(receipt, "from")),
        to: normalize_address(Map.get(receipt, "to")),
        logs: Enum.map(Map.get(receipt, "logs", []), &normalize_log/1)
      }
    end

    defp normalize_log(log) do
      %{
        address: normalize_address(Map.get(log, "address")),
        topics: Map.get(log, "topics", []),
        data: Map.get(log, "data", "0x"),
        block_number: decode_optional_quantity(Map.get(log, "blockNumber")),
        transaction_hash: Map.get(log, "transactionHash"),
        log_index: decode_optional_quantity(Map.get(log, "logIndex"))
      }
    end

    defp normalize_transaction(tx) do
      %{
        transaction_hash: Map.get(tx, "hash"),
        from: normalize_address(Map.get(tx, "from")),
        to: normalize_address(Map.get(tx, "to")),
        input: Map.get(tx, "input", "0x"),
        value: Map.get(tx, "value", "0x0"),
        block_number: decode_optional_quantity(Map.get(tx, "blockNumber"))
      }
    end

    defp decode_optional_quantity(nil), do: nil

    defp decode_optional_quantity(<<"0x", hex::binary>>) when hex != "" do
      String.to_integer(hex, 16)
    end

    defp decode_optional_quantity(_value), do: nil

    defp normalize_address(value) when is_binary(value), do: String.downcase(String.trim(value))
    defp normalize_address(_value), do: nil
  end
end
