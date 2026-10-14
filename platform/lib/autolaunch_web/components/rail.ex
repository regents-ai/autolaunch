defmodule AutolaunchWeb.Components.Rail do
  @moduledoc false
  use Phoenix.Component

  # Explore has two smaller links to its auction and token views. It also
  # covers their search and detail pages; Docs covers the persistent
  # information-page navigation. Launching starts from the home page's one
  # "Launch a token" button.
  @items [
    %{
      label: "Explore",
      path: "/",
      covers: ["/auctions", "/tokens", "/robinhood"]
    },
    %{label: "Onchain Stocks", path: "/upcoming-stocks", covers: []},
    %{label: "Portfolio", path: "/portfolio", covers: []},
    %{
      label: "Docs",
      path: "/docs",
      covers: []
    }
  ]

  @explore_views [
    %{label: "Auctions", path: "/", view: "auctions"},
    %{label: "Tokens", path: "/?view=tokens", view: "tokens"}
  ]

  attr :current_path, :string, required: true
  attr :market_view, :string, default: nil

  def rail(assigns) do
    assigns = assign(assigns, items: @items, explore_views: @explore_views)

    ~H"""
    <nav class="shell-rail" aria-label="Site">
      <div class="shell-rail__bar">
        <a class="shell-wordmark" href="/">Autolaunch</a>
      </div>
      <ul class="shell-rail__list">
        <li :for={item <- @items} class="shell-rail__item">
          <.link
            href={item.path}
            class="rg-button rg-button--primary shell-rail__link"
            aria-current={if current?(@current_path, item), do: "page"}
          >
            {item.label}
          </.link>
          <ul :if={item.path == "/"} class="shell-rail__sublist" aria-label="Explore views">
            <li :for={view <- @explore_views}>
              <.link
                href={view.path}
                class="rg-button rg-button--primary shell-rail__link shell-rail__sublink"
                aria-current={if view_current?(@current_path, @market_view, view.view), do: "page"}
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

  defp current?(path, %{label: "Docs"}),
    do: Enum.any?(AutolaunchWeb.Components.LearnNavigation.paths(), &under?(path, &1))

  defp current?(path, %{path: own, covers: covers}),
    do: Enum.any?([own | covers], &under?(path, &1))

  defp view_current?("/", view, target), do: (view || "auctions") == target
  defp view_current?(path, _view, "tokens"), do: under?(path, "/tokens")

  defp view_current?(path, _view, "auctions"),
    do: under?(path, "/auctions") or under?(path, "/robinhood")

  defp under?(path, "/"), do: path == "/"

  defp under?(path, prefix) when is_binary(path),
    do: path == prefix or String.starts_with?(path, prefix <> "/")

  defp under?(_path, _prefix), do: false
end
