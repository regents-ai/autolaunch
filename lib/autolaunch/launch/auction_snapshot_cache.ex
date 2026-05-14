defmodule Autolaunch.Launch.AuctionSnapshotCache do
  @moduledoc false

  alias Autolaunch.CCA.Contract, as: CCAContract
  alias Autolaunch.LocalCache

  @default_ttl_seconds 45

  def fetch(chain_id, auction_address, opts \\ []) do
    ttl_seconds =
      Keyword.get(opts, :ttl_seconds, config_value(:snapshot_ttl_seconds, @default_ttl_seconds))

    key = cache_key(chain_id, auction_address)

    fetch_cached(key, ttl_seconds, fn ->
      read_snapshot(chain_id, auction_address)
    end)
  end

  def invalidate(chain_id, auction_address) do
    LocalCache.delete(cache_key(chain_id, auction_address))
  end

  defp fetch_cached(key, ttl_seconds, fun) do
    case LocalCache.fetch(key, ttl_seconds, fun) do
      {:ok, value} ->
        case normalize_snapshot(value) do
          {:ok, snapshot} ->
            {:ok, snapshot}

          {:error, _reason} ->
            _ = LocalCache.delete(key)
            fetch_fresh(key, ttl_seconds, fun)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_fresh(key, ttl_seconds, fun) do
    with {:ok, value} <- LocalCache.fetch(key, ttl_seconds, fun),
         {:ok, snapshot} <- normalize_snapshot(value) do
      {:ok, snapshot}
    end
  end

  defp read_snapshot(chain_id, auction_address) do
    with {:ok, snapshot} <- CCAContract.snapshot(chain_id, auction_address) do
      {:ok, project_snapshot(snapshot)}
    end
  end

  defp project_snapshot(snapshot) do
    %{
      auction_address: snapshot.auction_address,
      chain_id: snapshot.chain_id,
      block_number: snapshot.block_number,
      checkpoint: %{
        clearing_price_q96: snapshot.checkpoint.clearing_price_q96
      },
      required_currency_raised_wei: snapshot.required_currency_raised_wei,
      currency_raised_wei: snapshot.currency_raised_wei,
      start_block: snapshot.start_block,
      end_block: snapshot.end_block,
      claim_block: snapshot.claim_block,
      is_graduated: snapshot.is_graduated,
      observed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp normalize_snapshot(value) when is_map(value) do
    with {:ok, auction_address} <- string_field(value, :auction_address),
         {:ok, chain_id} <- integer_field(value, :chain_id),
         {:ok, block_number} <- integer_field(value, :block_number),
         {:ok, checkpoint} <- normalize_checkpoint(field(value, :checkpoint)),
         {:ok, required_currency_raised_wei} <-
           integer_field(value, :required_currency_raised_wei),
         {:ok, currency_raised_wei} <- integer_field(value, :currency_raised_wei),
         {:ok, start_block} <- integer_field(value, :start_block),
         {:ok, end_block} <- integer_field(value, :end_block),
         {:ok, claim_block} <- integer_field(value, :claim_block),
         {:ok, is_graduated} <- boolean_field(value, :is_graduated) do
      {:ok,
       %{
         auction_address: auction_address,
         chain_id: chain_id,
         block_number: block_number,
         checkpoint: checkpoint,
         required_currency_raised_wei: required_currency_raised_wei,
         currency_raised_wei: currency_raised_wei,
         start_block: start_block,
         end_block: end_block,
         claim_block: claim_block,
         is_graduated: is_graduated,
         observed_at: optional_string_field(value, :observed_at)
       }}
    end
  end

  defp normalize_snapshot(_value), do: {:error, :invalid_snapshot}

  defp normalize_checkpoint(value) when is_map(value) do
    with {:ok, clearing_price_q96} <- integer_field(value, :clearing_price_q96) do
      {:ok, %{clearing_price_q96: clearing_price_q96}}
    end
  end

  defp normalize_checkpoint(_value), do: {:error, :invalid_checkpoint}

  defp string_field(map, key) do
    case field(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:invalid_string, key}}
    end
  end

  defp optional_string_field(map, key) do
    case field(map, key) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp integer_field(map, key) do
    case field(map, key) do
      value when is_integer(value) ->
        {:ok, value}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> {:ok, parsed}
          _parse_error -> {:error, {:invalid_integer, key}}
        end

      _value ->
        {:error, {:invalid_integer, key}}
    end
  end

  defp boolean_field(map, key) do
    case field(map, key) do
      value when is_boolean(value) -> {:ok, value}
      _value -> {:error, {:invalid_boolean, key}}
    end
  end

  defp field(map, key) do
    if Map.has_key?(map, key) do
      Map.get(map, key)
    else
      Map.get(map, Atom.to_string(key))
    end
  end

  defp cache_key(chain_id, auction_address) do
    normalized_address =
      auction_address
      |> to_string()
      |> String.trim()
      |> String.downcase()

    "autolaunch:auction_snapshot:v1:#{chain_id}:#{normalized_address}"
  end

  defp config_value(key, default) do
    :autolaunch
    |> Application.get_env(:auction_sync, [])
    |> Keyword.get(key, default)
  end
end
