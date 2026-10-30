defmodule AutolaunchWeb.Components.Rail do
  @moduledoc false
  use Phoenix.Component
  use AutolaunchWeb, :verified_routes

  # Explore has two smaller links, to the auctions list and the tokens list. It
  # also covers their search and detail pages; Docs covers the persistent
  # information-page navigation. Stocks has one, to covered calls, while the
  # site offers them. Launch is the last, orange destination.
  @items [
    %{
      label: "Explore",
      path: "/",
      covers: ["/auctions", "/tokens", "/robinhood"]
    },
    %{label: "Stocks", path: "/stock-listing", covers: []},
    %{label: "Portfolio", path: "/portfolio", covers: []},
    %{
      label: "Docs",
      path: "/docs",
      covers: []
    },
    %{label: "Launch", path: "/create", covers: []}
  ]

  attr :current_path, :string, required: true

  def rail(assigns) do
    assigns = assign(assigns, items: @items)

    ~H"""
    <nav class="shell-rail" aria-label="Site">
      <ul class="shell-rail__list">
        <li :for={item <- @items} class="shell-rail__item">
          <.link
            href={item.path}
            class={[
              "rg-button rg-button--primary shell-rail__link",
              item.path == "/create" && "shell-rail__launch"
            ]}
            aria-current={if current?(@current_path, item), do: "page"}
          >
            {item.label}
          </.link>
          <ul
            :if={views(item) != []}
            class="shell-rail__sublist"
            aria-label={"#{item.label} views"}
          >
            <li :for={view <- views(item)}>
              <.link
                navigate={view.path}
                class="rg-button rg-button--primary shell-rail__link shell-rail__sublink"
                aria-current={if current?(@current_path, view), do: "page"}
              >
                {view.label}
              </.link>
            </li>
          </ul>
        </li>
      </ul>
    </nav>
    """
  end

  attr :current_path, :string, required: true

  @doc """
  On a phone the rail folds into this drawer behind the top bar's Menu button,
  as the template's rail and sidebar do (ash-template `Shell`, `#shell-drawer`):
  the same destinations as plain rows, with Launch as the one main button. It
  comes in from the left edge under the top bar, which stays in place, and its
  Close navigation bar is its first row. The browser opens and closes it
  (`assets/js/shell_menu.ts`), so the server always draws it closed.
  """
  def drawer(assigns) do
    assigns =
      assign(assigns,
        rows: Enum.reject(@items, &(&1.path == "/create"))
      )

    ~H"""
    <div id="shell-drawer" tabindex="-1">
      <Regent.Primitives.button
        variant="quiet"
        type="button"
        class="shell-menu-close"
        data-shell-menu-close
      >
        Close navigation
      </Regent.Primitives.button>
      <nav class="shell-drawer__nav" aria-label="Site">
        <ul>
          <li :for={item <- @rows}>
            <.link
              href={item.path}
              class="shell-drawer__row"
              aria-current={if row_current?(@current_path, item), do: "page"}
            >
              {item.label}
            </.link>
            <ul :if={views(item) != []} aria-label={"#{item.label} views"}>
              <li :for={view <- views(item)}>
                <.link
                  navigate={view.path}
                  class="shell-drawer__row shell-drawer__row--sub"
                  aria-current={if current?(@current_path, view), do: "page"}
                >
                  {view.label}
                </.link>
              </li>
            </ul>
          </li>
        </ul>
        <.link
          href={~p"/create"}
          class="rg-button rg-button--primary shell-rail__launch shell-drawer__launch"
          aria-current={if under?(@current_path, "/create"), do: "page"}
        >
          Launch
        </.link>
      </nav>
    </div>
    """
  end

  # A row marks only the page you are on: Explore is the home page, and its
  # two views mark themselves.
  defp row_current?(path, %{path: "/"}), do: path == "/"
  defp row_current?(path, item), do: current?(path, item)

  defp views(%{path: "/"}) do
    [
      %{label: "Auctions", path: ~p"/auctions", covers: ["/robinhood"]},
      %{label: "Tokens", path: ~p"/tokens", covers: []}
    ]
  end

  defp views(%{path: "/stock-listing"}) do
    if Autolaunch.CoveredCalls.Deployment.enabled?(),
      do: [%{label: "Covered calls", path: ~p"/covered-calls", covers: []}],
      else: []
  end

  defp views(_item), do: []

  defp current?(path, %{label: "Docs"}),
    do: Enum.any?(AutolaunchWeb.Components.LearnNavigation.paths(), &under?(path, &1))

  defp current?(path, %{path: own, covers: covers}),
    do: Enum.any?([own | covers], &under?(path, &1))

  defp under?(path, "/"), do: path == "/"

  defp under?(path, prefix) when is_binary(path),
    do: path == prefix or String.starts_with?(path, prefix <> "/")

  defp under?(_path, _prefix), do: false
end
