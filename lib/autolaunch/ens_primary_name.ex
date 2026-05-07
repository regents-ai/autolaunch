defmodule Autolaunch.EnsPrimaryName do
  @moduledoc false

  alias AgentEns.Internal.Contract
  alias AgentEns.Internal.RPC
  alias AgentEns.Verify
  alias Autolaunch.Evm

  @ethereum_chain_id 1
  @ens_registry "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e"

  @spec verified_primary_name(String.t() | nil) :: {:ok, String.t() | nil} | {:error, term()}
  def verified_primary_name(wallet_address) do
    with wallet when is_binary(wallet) <- Evm.normalize_address(wallet_address),
         rpc_url when is_binary(rpc_url) and rpc_url != "" <- ethereum_rpc_url(),
         {:ok, reverse_name} <- reverse_name(wallet, rpc_url),
         true <- reverse_name != "",
         {:ok, %{eth_address: ^wallet, normalized_name: normalized_name}} <-
           AgentEns.read_name(%{
             ens_name: reverse_name,
             chain_id: @ethereum_chain_id,
             rpc_url: rpc_url,
             rpc_module: rpc_module(),
             include_contenthash?: false
           }) do
      {:ok, normalized_name}
    else
      nil -> {:ok, nil}
      false -> {:ok, nil}
      {:ok, %{eth_address: _other}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
      _other -> {:ok, nil}
    end
  end

  defp reverse_name(wallet, rpc_url) do
    with {:ok, node} <- reverse_node(wallet),
         {:ok, resolver} <- Contract.fetch_resolver(rpc_module(), rpc_url, ens_registry(), node),
         {:ok, name} <- Contract.fetch_name_record(rpc_module(), rpc_url, resolver, node) do
      {:ok, String.trim(name)}
    end
  end

  defp reverse_node("0x" <> address), do: Verify.namehash("#{address}.addr.reverse")

  defp ethereum_rpc_url do
    :autolaunch
    |> Application.get_env(:ens_primary_name, [])
    |> Keyword.get(:rpc_url)
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> System.get_env("ETHEREUM_RPC_URL")
    end
  end

  defp ens_registry do
    :autolaunch
    |> Application.get_env(:ens_primary_name, [])
    |> Keyword.get(:ens_registry, @ens_registry)
  end

  defp rpc_module do
    :autolaunch
    |> Application.get_env(:ens_primary_name, [])
    |> Keyword.get(:rpc_module, RPC)
  end
end
