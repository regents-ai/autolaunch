defmodule Autolaunch.RegentFacts do
  @moduledoc false

  alias Autolaunch.Chain.Abi
  alias Autolaunch.Chain.Address
  alias Autolaunch.Chain.Rpc

  @manifest_path Path.expand("../../contracts/chain-contracts.yaml", __DIR__)
  @external_resource @manifest_path

  @manifest YamlElixir.read_from_file!(@manifest_path)
  @staking Enum.find(
             get_in(@manifest, ["contracts", Access.at(0), "reviewed_action_evidence"]),
             &(&1["contract_id"] == "regent_revenue_staking")
           )

  # name()
  @name "0x06fdde03"
  # symbol()
  @symbol "0x95d89b41"
  # decimals()
  @decimals "0x313ce567"
  # totalSupply()
  @total_supply "0x18160ddd"

  @doc """
  One REGENT reading pinned to a single Base `safe` block.

  `stakeToken()` on the pinned staking contract must name the same REGENT
  address the manifest does; a mismatch is `{:error, :stake_token_mismatch}`.
  """
  @spec read() ::
          {:ok,
           %{
             block_number: non_neg_integer(),
             block_hash: String.t(),
             name: String.t(),
             symbol: String.t(),
             address: String.t(),
             decimals: non_neg_integer(),
             total_supply: String.t(),
             total_staked: String.t()
           }}
          | {:error, atom()}
  def read do
    token = Abi.regent_address()
    staking = staking_address()

    with {:ok, block} <- Rpc.safe_block(),
         {:ok, name} <- call_string(token, @name, block),
         {:ok, symbol} <- call_string(token, @symbol, block),
         {:ok, decimals} <- Rpc.call_uint(token, @decimals, block),
         {:ok, total_supply} <- Rpc.call_uint(token, @total_supply, block),
         {:ok, stake_token} <- Rpc.call_address(staking, staking_selector("stake_token"), block),
         {:ok, total_staked} <- Rpc.call_uint(staking, staking_selector("total_staked"), block),
         :ok <- match_stake_token(stake_token, token) do
      {:ok,
       %{
         block_number: block.number,
         block_hash: block.hash,
         name: name,
         symbol: symbol,
         address: token,
         decimals: decimals,
         total_supply: Rpc.format_units(total_supply, decimals),
         total_staked: Rpc.format_units(total_staked, decimals)
       }}
    end
  end

  defp staking_address, do: @staking["address"]

  defp staking_selector(id) do
    @staking["reads"]
    |> Enum.find(&(&1["id"] == id))
    |> Map.fetch!("selector")
  end

  defp match_stake_token(actual, expected) do
    if Address.equal?(actual, expected), do: :ok, else: {:error, :stake_token_mismatch}
  end

  # name() and symbol() are ABI strings. Rpc has no string decoder, so the
  # block-pinned eth_call is issued through request/3 and decoded here.
  defp call_string(to, data, %{hash: hash}) do
    block = %{blockHash: hash, requireCanonical: true}

    case Rpc.request("eth_call", [%{to: to, data: data}, block]) do
      {:ok, result} -> decode_string(result)
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_string("0x" <> hex) when rem(byte_size(hex), 2) == 0 do
    with {:ok, raw} <- Base.decode16(hex, case: :mixed),
         <<offset::256, _::binary>> <- raw,
         true <- offset + 32 <= byte_size(raw),
         <<len::256, payload::binary>> <- binary_part(raw, offset, byte_size(raw) - offset),
         true <- byte_size(payload) >= len do
      {:ok, binary_part(payload, 0, len)}
    else
      _malformed -> {:error, :invalid_chain_response}
    end
  end

  defp decode_string(_), do: {:error, :invalid_chain_response}
end
