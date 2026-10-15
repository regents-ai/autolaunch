defmodule AutolaunchWeb.Components.Rail do
  @moduledoc false
  use Phoenix.Component
  use AutolaunchWeb, :verified_routes

  # Explore has two smaller links, to the auctions list and the tokens list. It
  # also covers their search and detail pages; Docs covers the persistent
  # information-page navigation. Launch is the last, orange destination.
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
    },
    %{label: "Launch", path: "/create", covers: []}
  ]

  attr :current_path, :string, required: true

  def rail(assigns) do
    assigns =
      assign(assigns,
        items: @items,
        explore_views: [
          %{label: "Auctions", path: ~p"/auctions", covers: ["/robinhood"]},
          %{label: "Tokens", path: ~p"/tokens", covers: []}
        ]
      )

    ~H"""
    <nav class="shell-rail" aria-label="Site">
      <div class="shell-rail__bar">
        <a class="shell-wordmark" href="/">Autolaunch</a>
      </div>
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
          <ul :if={item.path == "/"} class="shell-rail__sublist" aria-label="Explore views">
            <li :for={view <- @explore_views}>
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

  defp current?(path, %{label: "Docs"}),
    do: Enum.any?(AutolaunchWeb.Components.LearnNavigation.paths(), &under?(path, &1))

  defp current?(path, %{path: own, covers: covers}),
    do: Enum.any?([own | covers], &under?(path, &1))

  defp under?(path, "/"), do: path == "/"

  defp under?(path, prefix) when is_binary(path),
    do: path == prefix or String.starts_with?(path, prefix <> "/")

  defp under?(_path, _prefix), do: false
end
