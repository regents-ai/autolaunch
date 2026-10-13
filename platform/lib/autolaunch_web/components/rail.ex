defmodule AutolaunchWeb.Components.Rail do
  @moduledoc false
  use Phoenix.Component

  # Four destinations. Explore also covers the auction and token lists and
  # their pages; New Stocks is the Upcoming page; Learn covers its persistent
  # information-page navigation. Launching starts from the home page's one
  # "Launch a token" button.
  @items [
    %{
      label: "Explore",
      path: "/",
      covers: ["/auctions", "/tokens", "/robinhood"]
    },
    %{label: "New Stocks", path: "/upcoming", covers: []},
    %{label: "Portfolio", path: "/portfolio", covers: []},
    %{
      label: "Learn",
      path: "/how-it-works",
      covers: []
    }
  ]

  attr :current_path, :string, required: true

  def rail(assigns) do
    assigns = assign(assigns, :items, @items)

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
        </li>
      </ul>
    </nav>
    """
  end

  defp current?(path, %{label: "Learn"}),
    do: Enum.any?(AutolaunchWeb.Components.LearnNavigation.paths(), &under?(path, &1))

  defp current?(path, %{path: own, covers: covers}),
    do: Enum.any?([own | covers], &under?(path, &1))

  defp under?(path, "/"), do: path == "/"

  defp under?(path, prefix) when is_binary(path),
    do: path == prefix or String.starts_with?(path, prefix <> "/")

  defp under?(_path, _prefix), do: false
end
