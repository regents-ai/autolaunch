defmodule AutolaunchWeb.PublicPage do
  @moduledoc false
  alias AutolaunchWeb.Endpoint
  @salt "public-listings-v1"

  def options(nil, _scope, limit), do: {:ok, [limit: limit]}

  def options(cursor, scope, limit) when is_binary(cursor) and byte_size(cursor) <= 4096 do
    case Phoenix.Token.verify(Endpoint, @salt, cursor, max_age: 86_400) do
      {:ok, {^scope, keyset}} when is_binary(keyset) -> {:ok, [limit: limit, after: keyset]}
      _ -> {:error, :invalid_query}
    end
  end

  def options(_, _, _), do: {:error, :invalid_query}

  def metadata(page, scope) do
    cursor =
      if page.more? do
        Phoenix.Token.sign(Endpoint, @salt, {scope, List.last(page.results).__metadata__.keyset})
      end

    %{has_more: page.more?, next_cursor: cursor}
  end
end
