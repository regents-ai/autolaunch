defmodule AutolaunchWeb.MarketPage do
  @moduledoc """
  One page of a public market list across both chains. The Robinhood entries,
  read from their chain and ordered by launch id, lead; the stored Base
  records follow in keyset order. One signed cursor names the position in
  whichever group the previous page ended in, so a reader who follows
  `next_cursor` sees every entry of both chains exactly once.

  Robinhood that cannot be read never takes the Base records down with it:
  the page then lists Base alone and says Robinhood is unavailable.
  """

  alias Autolaunch.Robinhood.Auctions
  alias AutolaunchWeb.Endpoint

  @salt "public-listings-v1"

  @doc "Auctions in one mode and sort: Robinhood auctions in launch order, then Base auctions."
  def auctions(cursor, mode, sort, limit, autolaunch \\ Autolaunch) do
    read(
      {:auctions, mode, sort},
      sort,
      cursor,
      limit,
      fn -> Auctions.list(mode, sort) end,
      &autolaunch.page_public_auctions(mode, sort, actor: nil, page: &1)
    )
  end

  @doc "Graduated tokens: Robinhood tokens newest launch first, then Base tokens newest graduation first."
  def tokens(cursor, limit, autolaunch \\ Autolaunch) do
    read(
      :tokens,
      "newest",
      cursor,
      limit,
      &Auctions.graduated/0,
      &autolaunch.page_public_tokens(actor: nil, page: &1)
    )
  end

  defp read(scope, sort, cursor, limit, robinhood, base) do
    with {:ok, position} <- position(cursor, scope) do
      case robinhood(position, sort, robinhood) do
        {:ok, entries} -> listed(entries, position, limit, scope, base)
        {:error, _reason} -> unavailable(position, limit, scope, base)
      end
    end
  end

  defp listed(robinhood, position, limit, scope, base) do
    {visible, remaining} = Enum.split(robinhood, limit)

    case remaining do
      [_ | _] ->
        {:ok, page(visible, [], {:robinhood, List.last(visible).launch_id}, scope)}

      [] ->
        base_page(visible, position, limit, scope, base)
    end
  end

  # Base from its first record, since the Robinhood entries it would follow
  # could not be read.
  defp unavailable(position, limit, scope, base) do
    with {:ok, page} <- base_page([], base_position(position), limit, scope, base) do
      {:ok, %{page | robinhood_unavailable: true}}
    end
  end

  defp base_position({:robinhood, _id}), do: {:base, nil}
  defp base_position(position), do: position

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

  defp robinhood({:base, _keyset}, _sort, _read), do: {:ok, []}

  defp robinhood({:robinhood, after_id}, sort, read) do
    with {:ok, entries} <- read.() do
      {:ok, Enum.filter(entries, &after_launch?(&1.launch_id, after_id, sort))}
    end
  end

  defp after_launch?(_id, nil, _sort), do: true
  defp after_launch?(id, after_id, "newest"), do: id < after_id
  defp after_launch?(id, after_id, "oldest"), do: id > after_id

  defp base_page(robinhood, position, limit, scope, read) do
    remaining = limit - length(robinhood)
    opts = [limit: max(remaining, 1)]
    opts = if keyset = base_keyset(position), do: Keyword.put(opts, :after, keyset), else: opts

    with {:ok, base} <- read.(opts) do
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
      robinhood_unavailable: false,
      records: records,
      pagination: %{
        has_more: not is_nil(next),
        next_cursor: if(next, do: Phoenix.Token.sign(Endpoint, @salt, {scope, next}))
      }
    }
  end
end
