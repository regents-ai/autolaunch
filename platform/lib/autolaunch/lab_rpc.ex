defmodule Autolaunch.LabRpc do
  @moduledoc false

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.{Lab, LabAbi}

  def current(required_addresses \\ []) do
    with {:ok, config} <- Lab.current(),
         opts = opts(config),
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
    address = Lab.address!(config, contract)
    Rpc.call_uint(address, data(config, contract, signature, arguments), block, opts)
  end

  def bool(config, contract, signature, arguments, block, opts) do
    address = Lab.address!(config, contract)
    Rpc.call_bool(address, data(config, contract, signature, arguments), block, opts)
  end

  def address(config, contract, signature, arguments, block, opts) do
    address = Lab.address!(config, contract)
    Rpc.call_address(address, data(config, contract, signature, arguments), block, opts)
  end

  def words(config, contract, signature, arguments, count, block, opts) do
    address = Lab.address!(config, contract)
    Rpc.call_words(address, data(config, contract, signature, arguments), block, count, opts)
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

  @doc """
  The outcome of `hash` at the latest block of the chain `opts` reads, when it
  is `signer`'s transaction to the saved step's target with its exact calldata.
  """
  def outcome(opts, signer, %{"to" => to, "data" => data}, hash) do
    with {:ok, block} <- Rpc.latest_block(opts),
         do: Rpc.canonical_outcome(hash, signer, to, data, block, opts)
  end

  def block_from_logs(logs) when is_list(logs) do
    case logs |> Enum.map(& &1["blockHash"]) |> Enum.uniq() do
      [hash] when is_binary(hash) ->
        if Rpc.valid_hash?(hash),
          do: {:ok, %{hash: String.downcase(hash)}},
          else: {:error, :invalid_receipt}

      _other ->
        {:error, :invalid_receipt}
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

  # The calldata for a deployment contract the site calls by key, encoded with
  # that contract's ABI.
  defp data(config, contract, signature, arguments),
    do: LabAbi.encode(Lab.abi!(config, abi(contract)), signature, arguments)

  defp abi(:regent), do: "token"

  defp abi(contract) when contract in [:factory, :strategy, :permit2],
    do: Atom.to_string(contract)
end
