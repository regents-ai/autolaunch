defmodule AutolaunchWeb.MarketPage do
  @moduledoc """
  One page of a public market list across both chains, read from the stored
  records in keyset order. A signed cursor names the position the previous
  page ended at, so a reader who follows `next_cursor` sees every entry
  exactly once.

  `robinhood_unavailable` says Robinhood could not be read just now, so its
  entries show what was last read from it.
  """

  alias AutolaunchWeb.{Endpoint, LabMarket}

  @salt "public-listings-v1"

  @doc "Auctions in one mode and sort."
  def auctions(cursor, mode, sort, limit, autolaunch \\ Autolaunch) do
    read(
      {:auctions, mode, sort},
      cursor,
      limit,
      &autolaunch.page_public_auctions(mode, sort, actor: nil, page: &1)
    )
  end

  @doc "Graduated tokens, newest graduation first."
  def tokens(cursor, limit, autolaunch \\ Autolaunch),
    do: read(:tokens, cursor, limit, &autolaunch.page_public_tokens(actor: nil, page: &1))

  defp read(scope, cursor, limit, read) do
    with {:ok, keyset} <- keyset(cursor, scope),
         {:ok, page} <- read.(page_options(keyset, limit)) do
      {:ok,
       %{
         records: page.results,
         robinhood_unavailable: LabMarket.robinhood_stale?(),
         pagination: %{
           has_more: page.more?,
           next_cursor: next_cursor(page, scope)
         }
       }}
    end
  end

  defp keyset(nil, _scope), do: {:ok, nil}

  defp keyset(cursor, scope) when is_binary(cursor) and byte_size(cursor) <= 4096 do
    case Phoenix.Token.verify(Endpoint, @salt, cursor, max_age: 86_400) do
      {:ok, {^scope, keyset}} when is_binary(keyset) -> {:ok, keyset}
      _invalid -> {:error, :invalid_query}
    end
  end

  defp keyset(_cursor, _scope), do: {:error, :invalid_query}

  defp page_options(nil, limit), do: [limit: limit]
  defp page_options(keyset, limit), do: [limit: limit, after: keyset]

  defp next_cursor(%{more?: true, results: results}, scope),
    do: Phoenix.Token.sign(Endpoint, @salt, {scope, List.last(results).__metadata__.keyset})

  defp next_cursor(_page, _scope), do: nil
end
