defmodule Autolaunch.CCA.Rpc do
  @moduledoc false

  def block_number(chain_id) do
    rpc_adapter().block_number(chain_id)
  end

  def eth_call(chain_id, to, data) do
    rpc_adapter().eth_call(chain_id, to, data)
  end

  def tx_receipt(chain_id, tx_hash) do
    rpc_adapter().tx_receipt(chain_id, tx_hash)
  end

  def tx_by_hash(chain_id, tx_hash) do
    rpc_adapter().tx_by_hash(chain_id, tx_hash)
  end

  def get_logs(chain_id, filter) do
    rpc_adapter().get_logs(chain_id, filter)
  end

  def rpc_url(chain_id) do
    __MODULE__.HttpAdapter.rpc_url(chain_id)
  end

  defp rpc_adapter do
    Application.get_env(:autolaunch, :cca_rpc_adapter, __MODULE__.HttpAdapter)
  end

  defmodule HttpAdapter do
    @moduledoc false

    @timeout 15_000

    def block_number(chain_id) do
      chain_id
      |> call("eth_blockNumber", [])
      |> decode_quantity()
    end

    def eth_call(chain_id, to, data) do
      call(chain_id, "eth_call", [%{"to" => to, "data" => data}, "latest"])
      |> normalize_hex_result()
    end

    def tx_receipt(chain_id, tx_hash) do
      case call(chain_id, "eth_getTransactionReceipt", [tx_hash]) do
        {:ok, nil} -> {:ok, nil}
        {:ok, %{} = receipt} -> {:ok, normalize_receipt(receipt)}
        {:error, _} = error -> error
        _ -> {:error, :invalid_rpc_response}
      end
    end

    def tx_by_hash(chain_id, tx_hash) do
      case call(chain_id, "eth_getTransactionByHash", [tx_hash]) do
        {:ok, nil} -> {:ok, nil}
        {:ok, %{} = tx} -> {:ok, normalize_transaction(tx)}
        {:error, _} = error -> error
        _ -> {:error, :invalid_rpc_response}
      end
    end

    def get_logs(chain_id, filter) when is_map(filter) do
      case call(chain_id, "eth_getLogs", [filter]) do
        {:ok, logs} when is_list(logs) -> {:ok, Enum.map(logs, &normalize_log/1)}
        {:error, _} = error -> error
        _ -> {:error, :invalid_rpc_response}
      end
    end

    def rpc_url(chain_id) do
      launch_config = Application.get_env(:autolaunch, :launch, [])
      regent_staking_config = Application.get_env(:autolaunch, :regent_staking, [])

      case chain_id do
        1 -> fetch_url(launch_config, :eth_mainnet_rpc_url)
        8_453 -> fetch_url(regent_staking_config, :rpc_url)
        11_155_111 -> fetch_url(launch_config, :eth_sepolia_rpc_url)
        _ -> {:error, :invalid_chain_id}
      end
    end

    defp call(chain_id, method, params) do
      with {:ok, rpc_url} <- rpc_url(chain_id),
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
