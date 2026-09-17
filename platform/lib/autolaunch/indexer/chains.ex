defmodule Autolaunch.Indexer.Chains do
  @moduledoc """
  The chains this ledger follows, one endpoint and one watched address set each.

  Configuration names them under `:autolaunch, :autolaunch_indexer_chains`, a
  list of `%{chain_id, rpc_url, sources}` where every source is an address and
  the block it becomes interesting at. The endpoint is resolved only inside the
  transport's redaction boundary and never appears in an error raised here: a
  malformed setting is refused at boot with a fixed message, naming at most the
  integer chain id of the entry at fault, since any other field may carry a key.
  """

  alias Autolaunch.Chain.Address

  @type source :: %{address: String.t(), start_block: non_neg_integer()}
  @type chain :: %{chain_id: pos_integer(), rpc_url: String.t(), sources: [source()]}

  @doc "Every configured chain, validated; raises on a malformed or repeated entry."
  @spec configured() :: [chain()]
  def configured do
    case Application.fetch_env!(:autolaunch, :autolaunch_indexer_chains) do
      entries when is_list(entries) -> entries |> Enum.map(&validated/1) |> distinct()
      _other -> raise ArgumentError, "autolaunch indexer chains must be a list"
    end
  end

  @doc "The endpoint for one configured chain."
  @spec rpc_url!(pos_integer()) :: String.t()
  def rpc_url!(chain_id), do: chain!(chain_id).rpc_url

  @doc "The addresses one configured chain watches and the blocks they start at."
  @spec sources!(pos_integer()) :: [source()]
  def sources!(chain_id), do: chain!(chain_id).sources

  defp chain!(chain_id) do
    Enum.find(configured(), &(&1.chain_id == chain_id)) ||
      raise ArgumentError, "autolaunch indexer chain #{inspect(chain_id)} is not configured"
  end

  defp distinct(chains) do
    ids = Enum.map(chains, & &1.chain_id)

    if ids == Enum.uniq(ids),
      do: chains,
      else:
        raise(
          ArgumentError,
          "autolaunch indexer chains repeat a chain id: #{Enum.join(ids, ", ")}"
        )
  end

  defp validated(%{chain_id: chain_id, rpc_url: url, sources: sources})
       when is_integer(chain_id) and chain_id > 0 and is_list(sources) do
    if endpoint?(url),
      do: %{chain_id: chain_id, rpc_url: url, sources: Enum.map(sources, &source(chain_id, &1))},
      else: raise(ArgumentError, "autolaunch indexer chain #{chain_id} has a malformed endpoint")
  end

  defp validated(%{chain_id: chain_id}) when is_integer(chain_id),
    do: raise(ArgumentError, "autolaunch indexer chain #{chain_id} entry is malformed")

  defp validated(_entry),
    do: raise(ArgumentError, "autolaunch indexer chain entry has a malformed chain id")

  # An absolute http(s) URL with a host; the value itself is never reflected.
  defp endpoint?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      _malformed ->
        false
    end
  end

  defp endpoint?(_url), do: false

  defp source(chain_id, %{address: address, start_block: start_block})
       when is_integer(start_block) and start_block >= 0 do
    case Address.normalize(address) do
      {:ok, normalized} ->
        %{address: normalized, start_block: start_block}

      :error ->
        raise ArgumentError, "autolaunch indexer chain #{chain_id} names a malformed source"
    end
  end

  defp source(chain_id, _malformed),
    do: raise(ArgumentError, "autolaunch indexer chain #{chain_id} names a malformed source")
end
