defmodule AutolaunchWeb.AuctionPage do
  @moduledoc false

  alias Autolaunch.Robinhood.Auctions
  alias AutolaunchWeb.Endpoint

  # Shared with the former Base-only cursor so links already issued remain valid.
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

      # Old cursors already returned all Robinhood entries on their first page.
      {:ok, {^scope, keyset}} when is_binary(keyset) ->
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

    keyset =
      case position do
        {:base, keyset} -> keyset
        {:robinhood, _id} -> nil
      end

    opts = [limit: max(remaining, 1)]
    opts = if keyset, do: Keyword.put(opts, :after, keyset), else: opts

    with {:ok, base} <- autolaunch.page_public_auctions(mode, sort, actor: nil, page: opts) do
      # An exactly full Robinhood page probes Base without consuming its first row.
      if remaining == 0 do
        next = if base.results != [], do: {:base, nil}
        {:ok, page(robinhood, [], next, scope)}
      else
        next = if base.more?, do: {:base, List.last(base.results).__metadata__.keyset}
        {:ok, page(robinhood, base.results, next, scope)}
      end
    end
  end

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
