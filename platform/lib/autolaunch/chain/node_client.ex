defmodule Autolaunch.Chain.NodeClient do
  @moduledoc """
  JSON-RPC reads of Base and Ethereum mainnet for the shared Regent libraries, the
  template's: the Points bonus counts the NFTs a person's wallets hold on Base, and
  Regent Credits reads its purchases' transactions. Every read is at `latest`:
  never count confirmations and never wait for `safe` or `finalized`. The node is
  the site's own for the chain (`:chain_nodes`), never the public address a wallet
  adds the chain with. Autolaunch's own launch and market reads go through
  `Autolaunch.Chain.Rpc`.
  """

  @behaviour RegentCredits.ChainClient
  @behaviour RegentPoints.ChainClient

  @doc "The transaction sent as `hash`, or `nil` while the chain does not know it."
  @impl RegentCredits.ChainClient
  def transaction(chain, hash), do: rpc(chain, "eth_getTransactionByHash", [hash])

  @doc "The receipt for `hash`, or `nil` while it has not landed."
  @impl RegentCredits.ChainClient
  def receipt(chain, hash), do: rpc(chain, "eth_getTransactionReceipt", [hash])

  @doc "The newest block number."
  @impl RegentCredits.ChainClient
  def block_number(chain) do
    with {:ok, "0x" <> hex} <- rpc(chain, "eth_blockNumber", []) do
      {:ok, String.to_integer(hex, 16)}
    end
  end

  @doc "`eth_getLogs` with `filter` as given."
  @impl RegentCredits.ChainClient
  def logs(chain, filter), do: rpc(chain, "eth_getLogs", [filter])

  @doc """
  One JSON-RPC request to the node; one that gets no answer counts in
  `health.chain_request_failures.total`. A chain the site has no node for gets no
  answer either: `{:error, :no_node}`, and nothing is sent anywhere.
  """
  @impl RegentPoints.ChainClient
  def rpc(%{chain_id: chain_id} = chain, method, params) do
    case :autolaunch |> Application.fetch_env!(:chain_nodes) |> Map.fetch(chain_id) do
      {:ok, url} -> post(url, chain, method, params)
      :error -> failed(chain, method, :no_node)
    end
  end

  defp post(url, chain, method, params) do
    case Req.post(url,
           json: %{jsonrpc: "2.0", id: 1, method: method, params: params},
           retry: false,
           receive_timeout: 5_000
         ) do
      {:ok, %{status: 200, body: %{"result" => result}}} -> {:ok, result}
      {:ok, %{body: %{"error" => error}}} -> failed(chain, method, {:rpc, error})
      {:ok, %{status: status}} -> failed(chain, method, {:http, status})
      {:error, error} -> failed(chain, method, error)
    end
  end

  defp failed(chain, method, reason) do
    :telemetry.execute([:autolaunch, :rpc, :failure], %{count: 1}, %{
      method: method,
      class: class(reason),
      chain_id: chain.chain_id,
      scope: "wallet"
    })

    {:error, reason}
  end

  defp class(:no_node), do: :no_node
  defp class({:rpc, _error}), do: :rpc
  defp class({:http, status}), do: {:http_status, status}

  defp class(%Req.TransportError{reason: reason}) when reason in [:timeout, :connect_timeout],
    do: :timeout

  defp class(_transport), do: :transport
end
