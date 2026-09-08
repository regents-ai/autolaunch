defmodule Autolaunch.LabRpc do
  @moduledoc false

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.{Lab, LabAbi}

  def current(required_addresses \\ []) do
    with {:ok, config} <- Lab.current(),
         opts <- opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         :ok <- live_contracts(config, required_addresses, block, opts) do
      {:ok, config, block, opts}
    end
  end

  def opts(config, scope \\ "autolaunch local lab") do
    [
      rpc_url: config.rpc_url,
      expected_chain_id: config.chain_id,
      client_key: :autolaunch_lab_http_client,
      log_scope: scope
    ]
  end

  def uint(config, contract, signature, arguments, block, opts) do
    Rpc.call_uint(
      Lab.address!(config, contract),
      LabAbi.encode(Lab.abi!(config, abi_contract(contract)), signature, arguments),
      block,
      opts
    )
  end

  def bool(config, contract, signature, arguments, block, opts) do
    Rpc.call_bool(
      Lab.address!(config, contract),
      LabAbi.encode(Lab.abi!(config, abi_contract(contract)), signature, arguments),
      block,
      opts
    )
  end

  def address(config, contract, signature, arguments, block, opts) do
    Rpc.call_address(
      Lab.address!(config, contract),
      LabAbi.encode(Lab.abi!(config, abi_contract(contract)), signature, arguments),
      block,
      opts
    )
  end

  def words(config, contract, signature, arguments, count, block, opts) do
    Rpc.call_words(
      Lab.address!(config, contract),
      LabAbi.encode(Lab.abi!(config, abi_contract(contract)), signature, arguments),
      block,
      count,
      opts
    )
  end

  def call_uint(config, address, abi_name, signature, arguments, block, opts) do
    Rpc.call_uint(
      address,
      LabAbi.encode(Lab.abi!(config, abi_name), signature, arguments),
      block,
      opts
    )
  end

  def call_words(config, address, abi_name, signature, arguments, count, block, opts) do
    Rpc.call_words(
      address,
      LabAbi.encode(Lab.abi!(config, abi_name), signature, arguments),
      block,
      count,
      opts
    )
  end

  def ensure_contract(address, block, opts) do
    case Rpc.request(
           "eth_getCode",
           [address, %{blockHash: block.hash, requireCanonical: true}],
           opts
         ) do
      {:ok, "0x" <> code} when code != "" -> :ok
      {:ok, _empty_or_invalid} -> {:error, :lab_contract_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  def canonical_outcome(config, envelope, step, hash) do
    with {:ok, evidence} <- canonical_outcome_evidence(config, envelope, step, hash),
         do: {:ok, evidence.outcome}
  end

  def canonical_outcome_evidence(config, envelope, step, hash) do
    with {:ok, current} <- Lab.current(),
         true <- current.rpc_url == config.rpc_url,
         true <- current.chain_id == config.chain_id,
         opts <- opts(current),
         {:ok, block} <- Rpc.latest_block(opts) do
      Rpc.canonical_outcome_evidence(
        hash,
        envelope["expected_signer"],
        step["to"],
        step["data"],
        block,
        opts
      )
    else
      false -> {:error, :lab_config_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  def block_from_logs(logs) when is_list(logs) do
    case logs |> Enum.map(& &1["blockHash"]) |> Enum.uniq() do
      [hash] when is_binary(hash) ->
        if Rpc.valid_hash?(hash),
          do: {:ok, %{hash: String.downcase(hash)}},
          else: invalid_receipt()

      _other ->
        invalid_receipt()
    end
  end

  defp live_contracts(config, keys, block, opts) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      address = Lab.address!(config, key)

      case ensure_contract(address, block, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp abi_contract(contract) when contract in [:factory, :strategy, :permit2, :regent],
    do: if(contract == :regent, do: "token", else: Atom.to_string(contract))

  defp invalid_receipt, do: {:error, :invalid_receipt}
end
