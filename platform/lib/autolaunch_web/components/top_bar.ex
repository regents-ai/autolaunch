defmodule AutolaunchWeb.Components.TopBar do
  @moduledoc false
  use Phoenix.Component

  import AutolaunchWeb.Components.AccountControl

  @query_limit 80

  attr :account_control, Autolaunch.AccessContext.AccountControl, required: true
  attr :search_query, :string, default: ""

  def top_bar(assigns) do
    ~H"""
    <header class="shell-top">
      <form class="shell-search" action="/" method="get" role="search">
        <label class="shell-search__label" for="shell-search-q">Search</label>
        <input
          id="shell-search-q"
          class="shell-search__input"
          type="search"
          name="q"
          value={@search_query}
          placeholder="Search for coins and users..."
          autocomplete="off"
        />
      </form>
      <.account_control account_control={@account_control} />
    </header>
    """
  end

  @doc """
  The one form a search query takes: trimmed and cut at eighty characters. The
  header field and the home listing read the same value, so what the field
  shows after a search is exactly what filtered the market.
  """
  def normalize_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.graphemes()
    |> Enum.take(@query_limit)
    |> Enum.join()
  end

  def normalize_query(_query), do: ""
end
