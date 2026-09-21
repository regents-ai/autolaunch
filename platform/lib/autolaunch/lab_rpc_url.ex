defmodule Autolaunch.LabRpcUrl do
  @moduledoc """
  The two RPC doors of a deployment description.

  `admitted/1` is the site's own endpoint (`rpc_url`): the one its reads, its
  receipt checks and the faucet's impersonation calls reach. It is privileged
  and never reaches a browser or a log line. Admitted: loopback
  `http://127.0.0.1:PORT` (a local lab), a private `http://…internal:PORT` URL
  (Fly's private network) or an `https://` URL.

  `public/2` is the endpoint wallets add for the chain (`public_rpc_url`):
  `https://` only. A description whose own door is loopback may omit it, and
  then wallets are given that loopback door, as the local labs are; any other
  own door requires it, so a keyed endpoint never leaves the server.

  Neither door admits credentials, a query or a fragment.
  """

  @spec admitted(term()) :: {:ok, String.t()} | {:error, :rpc_not_admitted}
  def admitted(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{} = uri} -> admitted_uri(uri)
      {:error, _part} -> {:error, :rpc_not_admitted}
    end
  end

  def admitted(_value), do: {:error, :rpc_not_admitted}

  @spec public(term(), String.t()) ::
          {:ok, String.t()} | {:error, :missing_public_rpc | :invalid_public_rpc}
  def public(nil, rpc_url) do
    if loopback?(rpc_url), do: {:ok, rpc_url}, else: {:error, :missing_public_rpc}
  end

  def public(value, _rpc_url) when is_binary(value) do
    with {:ok, %URI{scheme: "https"} = uri} <- URI.new(value),
         true <- bare?(uri) and host?(uri.host) do
      {:ok, URI.to_string(uri)}
    else
      _ -> {:error, :invalid_public_rpc}
    end
  end

  def public(_value, _rpc_url), do: {:error, :invalid_public_rpc}

  @doc "Whether an admitted door is the loopback one, `http://127.0.0.1:PORT`."
  @spec loopback?(String.t()) :: boolean()
  def loopback?(rpc_url), do: match?({:ok, %URI{host: "127.0.0.1"}}, URI.new(rpc_url))

  # Loopback: `http://127.0.0.1:PORT` with nothing else.
  defp admitted_uri(%URI{scheme: "http", host: "127.0.0.1", port: port, path: path} = uri)
       when path in [nil, ""] do
    if bare?(uri) and port?(port),
      do: {:ok, "http://127.0.0.1:#{port}"},
      else: {:error, :rpc_not_admitted}
  end

  # Fly's private network: plain HTTP inside `.internal`, never on the public internet.
  defp admitted_uri(%URI{scheme: "http", host: host, port: port} = uri) when is_binary(host) do
    if bare?(uri) and port?(port) and internal?(host),
      do: {:ok, URI.to_string(uri)},
      else: {:error, :rpc_not_admitted}
  end

  defp admitted_uri(%URI{scheme: "https", host: host} = uri) do
    if bare?(uri) and host?(host),
      do: {:ok, URI.to_string(uri)},
      else: {:error, :rpc_not_admitted}
  end

  defp admitted_uri(_uri), do: {:error, :rpc_not_admitted}

  defp bare?(%URI{userinfo: nil, query: nil, fragment: nil}), do: true
  defp bare?(_uri), do: false

  defp port?(port), do: is_integer(port) and port in 1..65_535

  defp host?(host), do: is_binary(host) and host != ""

  defp internal?(host), do: host != ".internal" and String.ends_with?(host, ".internal")
end
