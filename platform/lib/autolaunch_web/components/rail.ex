defmodule AutolaunchWeb.Components.Rail do
  @moduledoc false
  use Phoenix.Component

  # Four destinations. Explore also covers the auction and token lists and
  # their pages; Learn also covers the REGENT page it links to.
  @items [
    %{
      label: "Explore",
      path: "/",
      icon: :explore,
      covers: ["/auctions", "/tokens", "/robinhood"]
    },
    %{label: "Portfolio", path: "/portfolio", icon: :portfolio, covers: []},
    %{label: "Create", path: "/create", icon: :create, covers: []},
    %{label: "Learn", path: "/how-it-works", icon: :learn, covers: ["/regent"]}
  ]

  attr :current_path, :string, required: true

  def rail(assigns) do
    assigns = assign(assigns, :items, @items)

    ~H"""
    <nav class="shell-rail" aria-label="Site">
      <div class="shell-rail__bar">
        <a class="shell-wordmark" href="/">Autolaunch</a>
        <%!-- Narrow screens fold the links behind this button. --%>
        <button
          id="shell-menu-toggle"
          type="button"
          class="shell-rail__toggle"
          aria-label="Menu"
          aria-expanded="false"
          aria-controls="shell-menu"
          data-shell-menu-toggle
          phx-update="ignore"
        >
          <svg
            viewBox="0 0 24 24"
            width="24"
            height="24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.75"
            stroke-linecap="square"
            aria-hidden="true"
          >
            <path class="shell-rail__toggle-open" d="M4 7h16M4 12h16M4 17h16" />
            <path class="shell-rail__toggle-close" d="M6 6l12 12M18 6 6 18" />
          </svg>
        </button>
      </div>
      <ul id="shell-menu" class="shell-rail__list">
        <li :for={item <- @items} class="shell-rail__item">
          <span
            :if={item.path == "/create" && Autolaunch.Prelaunch.read_only?()}
            class="shell-rail__link shell-rail__link--closed"
            title={"Opens #{Autolaunch.Prelaunch.opens_at_label()}"}
          >
            <span class="shell-rail__content">
              <.icon name={item.icon} />
              <span class="shell-rail__label">{item.label}</span>
            </span>
          </span>
          <.link
            :if={item.path != "/create" || !Autolaunch.Prelaunch.read_only?()}
            href={item.path}
            class="shell-rail__link"
            aria-current={if current?(@current_path, item), do: "page"}
          >
            <span class="shell-rail__content">
              <.icon name={item.icon} />
              <span class="shell-rail__label">{item.label}</span>
            </span>
          </.link>
        </li>
      </ul>
    </nav>
    """
  end

  defp current?(path, %{path: own, covers: covers}),
    do: Enum.any?([own | covers], &under?(path, &1))

  defp under?(path, "/"), do: path == "/"

  defp under?(path, prefix) when is_binary(path),
    do: path == prefix or String.starts_with?(path, prefix <> "/")

  defp under?(_path, _prefix), do: false

  attr :name, :atom, required: true

  defp icon(assigns) do
    ~H"""
    <svg
      class="shell-rail__icon"
      viewBox="0 0 24 24"
      width="24"
      height="24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.75"
      stroke-linecap="square"
      stroke-linejoin="miter"
      aria-hidden="true"
    >
      <g :if={@name == :explore}>
        <path d="M4 11.5 12 4l8 7.5" />
        <path d="M7 10.5V20h10v-9.5" />
      </g>
      <g :if={@name == :create}>
        <rect x="4.5" y="4.5" width="15" height="15" />
        <path d="M12 8.5v7M8.5 12h7" />
      </g>
      <g :if={@name == :learn}>
        <rect x="5" y="4" width="14" height="16" />
        <path d="M8.5 9h7M8.5 12.5h7M8.5 16h4" />
      </g>
      <g :if={@name == :portfolio}>
        <rect x="4.5" y="7" width="15" height="12" />
        <path d="M8 7V5.5h8V7" />
        <path d="M4.5 12h15" />
      </g>
    </svg>
    """
  end
end
