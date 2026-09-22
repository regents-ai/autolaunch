defmodule AutolaunchWeb.AuctionPage do
  @moduledoc false

  alias Autolaunch.Robinhood.Auctions
  alias AutolaunchWeb.Endpoint

  @salt "public-listings-v1"

  def read(cursor, mode, sort, limit, autolaunch \\ Autolaunch) do
    scope = {:auctions, mode, sort}

    with {:ok, position} <- position(cursor, scope),
         {:ok, robinhood} <- robinhood(position, mode, sort) do
      {visible, remaining} = Enum.split(robinhood, limit)

      case remaining do
        [_ | _] ->
          {:ok, page(visible, [], {:robinhood, List.last(visible).launch_id}, scope)}

        [] ->
          base_page(visible, position, mode, sort, limit, scope, autolaunch)
      end
    end
  end

  defp position(nil, _scope), do: {:ok, {:robinhood, nil}}

  defp position(cursor, scope) when is_binary(cursor) and byte_size(cursor) <= 4096 do
    case Phoenix.Token.verify(Endpoint, @salt, cursor, max_age: 86_400) do
      {:ok, {^scope, {:robinhood, id}}} when is_integer(id) and id > 0 ->
        {:ok, {:robinhood, id}}

      {:ok, {^scope, {:base, keyset}}} when is_nil(keyset) or is_binary(keyset) ->
        {:ok, {:base, keyset}}

      _invalid ->
        {:error, :invalid_query}
    end
  end

  defp position(_cursor, _scope), do: {:error, :invalid_query}

  defp robinhood({:base, _keyset}, _mode, _sort), do: {:ok, []}

  defp robinhood({:robinhood, after_id}, mode, sort) do
    with {:ok, auctions} <- Auctions.list(mode, sort) do
      {:ok, Enum.filter(auctions, &after_launch?(&1.launch_id, after_id, sort))}
    end
  end

  defp after_launch?(_id, nil, _sort), do: true
  defp after_launch?(id, after_id, "newest"), do: id < after_id
  defp after_launch?(id, after_id, "oldest"), do: id > after_id

  defp base_page(robinhood, position, mode, sort, limit, scope, autolaunch) do
    remaining = limit - length(robinhood)
    opts = [limit: max(remaining, 1)]
    opts = if keyset = base_keyset(position), do: Keyword.put(opts, :after, keyset), else: opts

    with {:ok, base} <- autolaunch.page_public_auctions(mode, sort, actor: nil, page: opts) do
      {:ok, page(robinhood, base_records(base, remaining), base_next(base, remaining), scope)}
    end
  end

  defp base_keyset({:base, keyset}), do: keyset
  defp base_keyset({:robinhood, _id}), do: nil

  # An exactly full Robinhood page probes Base without consuming its first row.
  defp base_records(_base, 0), do: []
  defp base_records(base, _remaining), do: base.results

  defp base_next(%{results: []}, 0), do: nil
  defp base_next(_base, 0), do: {:base, nil}

  defp base_next(%{more?: true, results: results}, _remaining),
    do: {:base, List.last(results).__metadata__.keyset}

  defp base_next(_base, _remaining), do: nil

  defp page(robinhood, records, next, scope) do
    %{
      robinhood: robinhood,
      records: records,
      pagination: %{
        has_more: not is_nil(next),
        next_cursor: if(next, do: Phoenix.Token.sign(Endpoint, @salt, {scope, next}))
      }
    }
  end
end
