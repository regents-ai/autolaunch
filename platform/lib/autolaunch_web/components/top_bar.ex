defmodule AutolaunchWeb.Components.TopBar do
  @moduledoc false
  use Phoenix.Component

  import AutolaunchWeb.Components.AccountControl

  attr :account_control, Autolaunch.AccessContext.AccountControl, required: true
  attr :theme, :string, required: true

  def top_bar(assigns) do
    ~H"""
    <header class="shell-top home-top" id="home-top">
      <%!-- Hidden until opening: before then there is nothing to search.
           `AutolaunchWeb.SearchLive` opens its search window from this button. --%>
      <button
        :if={!Autolaunch.Prelaunch.read_only?()}
        type="button"
        class="home-search"
        aria-haspopup="dialog"
        aria-controls="site-search-dialog"
        aria-keyshortcuts="Meta+K Control+K /"
        data-search-open
      >
        <svg
          viewBox="0 0 24 24"
          width="20"
          height="20"
          fill="none"
          stroke="currentColor"
          stroke-width="1.5"
          aria-hidden="true"
        ><circle cx="10.5" cy="10.5" r="6.5" /><path d="m16 16 5 5" /></svg>
        <span class="home-search__label">Search auctions and tokens</span>
        <kbd
          id="home-search-shortcut"
          class="home-search__shortcut"
          aria-hidden="true"
          phx-update="ignore"
          data-search-shortcut
        >⌘ K</kbd>
      </button>
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
      </AutolaunchWeb.Components.RegentLinks.header_links>
      <div class="home-top__actions">
        <.theme_toggle theme={@theme} />
        <.account_control account_control={@account_control} />
      </div>
    </header>
    """
  end

  attr :theme, :string, required: true

  # The browser owns the switch: it writes the theme cookie the server reads on
  # the next render and restates the theme here on load and after every live
  # navigation, so LiveView leaves it alone. The server renders the theme it
  # served, so the switch reads correctly before any script runs.
  defp theme_toggle(assigns) do
    ~H"""
    <div id="theme-control" class="theme-control" phx-update="ignore">
      <Regent.ThemeToggle.button id="theme-control-button" theme={@theme} data-theme-toggle />
    </div>
    """
  end
end
