defmodule AutolaunchWeb.Components.TopBar do
  @moduledoc false
  use Phoenix.Component

  import AutolaunchWeb.Components.AccountControl

  attr :account_control, Autolaunch.AccessContext.AccountControl, required: true
  attr :search_query, :string, default: ""

  attr :home?, :boolean, default: false
  attr :market_options, :map, default: %{}

  def top_bar(assigns) do
    ~H"""
    <header class="shell-top home-top" id="home-top">
      <%!-- Hidden until opening: before then there is nothing to search. --%>
      <form
        :if={!Autolaunch.Prelaunch.read_only?()}
        id="home-search"
        class="home-search"
        action="/"
        method="get"
        role="search"
        phx-hook="HomeSearch"
        data-query={@search_query}
        phx-submit={if @home?, do: "search"}
        phx-change={if @home?, do: "type_search"}
        data-home={if @home?, do: "true"}
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
          placeholder="Search coins, stocks, creators and addresses…"
          autocomplete="off"
          phx-debounce="300"
        />
        <input
          :for={{key, value} <- Map.take(@market_options, [:view, :sort, :display, :state])}
          type="hidden"
          name={key}
          value={value}
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
      <AutolaunchWeb.Components.RegentLinks.header_links>
        <:lead>
          <Regent.Primitives.button
            :if={Autolaunch.Prelaunch.read_only?()}
            disabled
            class="create-button"
            title="Opens soon"
          >+ Create</Regent.Primitives.button>
          <.link
            :if={!Autolaunch.Prelaunch.read_only?()}
            navigate="/create"
            class="rg-button create-button"
          >+ Create</.link>
        </:lead>
        <:trail><.theme_toggle /></:trail>
      </AutolaunchWeb.Components.RegentLinks.header_links>
      <div class="home-top__actions">
        <.account_control account_control={@account_control} />
      </div>
    </header>
    """
  end

  # The switch names the theme showing by itself, from the page's theme or the
  # device's setting, so the server passes no theme. The browser owns the press:
  # it writes the theme cookie the server reads on the next render and restyles
  # the page, so LiveView leaves the switch alone.
  defp theme_toggle(assigns) do
    ~H"""
    <div id="theme-control" class="theme-control" phx-update="ignore">
      <Regent.ThemeToggle.button id="theme-control-button" data-theme-toggle />
    </div>
    """
  end
end
