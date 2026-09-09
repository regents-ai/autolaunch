defmodule Autolaunch.LabRpcUrl do
  @moduledoc """
  The two RPC doors of a fork site.

  `admitted/2` is the site's own endpoint (`rpc_url`): the one its reads, its
  receipt checks and the faucet's impersonation calls reach. It is privileged
  and never reaches a browser or a log line. Loopback is admitted in every
  mode; fork mode also admits a private `http://…internal:PORT` URL (Fly's
  private network) or an `https://` URL.

  `public/3` is the endpoint wallets add as chain 31337 (`public_rpc_url`):
  `https://` only. It is required in fork mode; in base mode a configuration
  without it names its loopback `rpc_url` for wallets, as the local lab does.

  Neither door admits credentials, a query or a fragment.
  """

  alias Autolaunch.ChainMode

  @spec admitted(term(), ChainMode.t()) :: {:ok, String.t()} | {:error, :rpc_not_admitted}
  def admitted(value, mode) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{} = uri} -> admitted_uri(uri, mode)
      {:error, _part} -> {:error, :rpc_not_admitted}
    end
  end

  def admitted(_value, _mode), do: {:error, :rpc_not_admitted}

  @spec public(term(), String.t(), ChainMode.t()) ::
          {:ok, String.t()} | {:error, :missing_public_rpc | :invalid_public_rpc}
  def public(nil, rpc_url, :base), do: {:ok, rpc_url}
  def public(nil, _rpc_url, :fork), do: {:error, :missing_public_rpc}

  def public(value, _rpc_url, _mode) when is_binary(value) do
    with {:ok, %URI{scheme: "https"} = uri} <- URI.new(value),
         true <- bare?(uri) and host?(uri.host) do
      {:ok, URI.to_string(uri)}
    else
      _ -> {:error, :invalid_public_rpc}
    end
  end

  def public(_value, _rpc_url, _mode), do: {:error, :invalid_public_rpc}

  # Loopback: `http://127.0.0.1:PORT` with nothing else, in every mode.
  defp admitted_uri(%URI{scheme: "http", host: "127.0.0.1", port: port, path: path} = uri, _mode)
       when path in [nil, ""] do
    if bare?(uri) and port?(port),
      do: {:ok, "http://127.0.0.1:#{port}"},
      else: {:error, :rpc_not_admitted}
  end

  # Fly's private network: plain HTTP inside `.internal`, never on the public internet.
  defp admitted_uri(%URI{scheme: "http", host: host, port: port} = uri, :fork)
       when is_binary(host) do
    if bare?(uri) and port?(port) and internal?(host),
      do: {:ok, URI.to_string(uri)},
      else: {:error, :rpc_not_admitted}
  end

  defp admitted_uri(%URI{scheme: "https", host: host} = uri, :fork) do
    if bare?(uri) and host?(host),
      do: {:ok, URI.to_string(uri)},
      else: {:error, :rpc_not_admitted}
  end

  defp admitted_uri(_uri, _mode), do: {:error, :rpc_not_admitted}

  defp bare?(%URI{userinfo: nil, query: nil, fragment: nil}), do: true
  defp bare?(_uri), do: false

  defp port?(port), do: is_integer(port) and port in 1..65_535

  defp host?(host), do: is_binary(host) and host != ""

  defp internal?(host), do: host != ".internal" and String.ends_with?(host, ".internal")
end
