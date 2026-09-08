defmodule AutolaunchWeb.Components.TopBar do
  @moduledoc false
  use Phoenix.Component

  import AutolaunchWeb.Components.AccountControl

  @query_limit 80

  attr :account_control, Autolaunch.AccessContext.AccountControl, required: true
  attr :search_query, :string, default: ""

  attr :home?, :boolean, default: false
  attr :market_options, :map, default: %{}

  def top_bar(assigns) do
    ~H"""
    <header class="shell-top home-top" id="home-top" phx-hook="HomeSearch" data-query={@search_query}>
      <form
        class="home-search"
        action="/"
        method="get"
        role="search"
        phx-submit={if @home?, do: "search"}
      >
        <label for="home-search-q" class="visually-hidden">Search coins and creators</label>
        <svg
          viewBox="0 0 24 24"
          width="20"
          height="20"
          fill="none"
          stroke="currentColor"
          stroke-width="1.5"
          aria-hidden="true"
        ><circle cx="10.5" cy="10.5" r="6.5" /><path d="m16 16 5 5" /></svg>
        <input
          id="home-search-q"
          type="search"
          name="q"
          value={@search_query}
          placeholder="Search coins, addresses and creators…"
          autocomplete="off"
        />
        <input
          :for={key <- [:view, :sort, :display, :state]}
          type="hidden"
          name={key}
          value={Map.get(@market_options, key)}
        />
        <button
          type="button"
          class="home-search__clear"
          aria-label="Clear search"
          data-clear-search
          hidden={@search_query == ""}
        >×</button>
        <kbd class="home-search__shortcut" aria-hidden="true">⌘ K</kbd>
        <button type="submit" class="visually-hidden">Search</button>
      </form>
      <div class="home-top__actions">
        <Regent.Primitives.button
          :if={Autolaunch.Prelaunch.read_only?()}
          disabled
          variant="secondary"
          class="home-top__create"
          title="Available after contract deployment"
        >+ Create</Regent.Primitives.button>
        <.link
          :if={!Autolaunch.Prelaunch.read_only?()}
          navigate="/create"
          class="rg-button rg-button--secondary home-top__create"
        >+ Create</.link>
        <.account_control account_control={@account_control} />
      </div>
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
