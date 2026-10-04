defmodule AutolaunchWeb.Components.TopBar do
  @moduledoc false
  use Phoenix.Component

  import AutolaunchWeb.Components.AccountControl

  attr :account_control, Autolaunch.AccessContext.AccountControl, required: true

  def top_bar(assigns) do
    ~H"""
    <header class="shell-top home-top" id="home-top">
      <%!-- Hidden until opening: before then there is nothing to search. --%>
      <button
        :if={!Autolaunch.Prelaunch.read_only?()}
        type="button"
        id="home-search"
        class="home-search"
        data-open-search
        aria-haspopup="dialog"
        aria-controls="search-dialog"
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
        <span class="home-search__prompt">Search coins, stocks, creators and addresses…</span>
        <kbd class="home-search__shortcut" aria-hidden="true">⌘ K</kbd>
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
