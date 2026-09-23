defmodule AutolaunchWeb.Components.Rail do
  @moduledoc false
  use Phoenix.Component

  @items [
    %{id: :home, label: "Home", path: "/", icon: :home},
    %{id: :auctions, label: "Auctions", path: "/auctions", icon: :auctions},
    %{id: :tokens, label: "Tokens", path: "/tokens", icon: :tokens},
    %{id: :token_details, label: "Token details", path: "/token-details", icon: :token_details},
    %{id: :portfolio, label: "Portfolio", path: "/portfolio", icon: :portfolio},
    %{id: :regent, label: "REGENT", path: "/regent", icon: :regent}
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
          <.link
            href={item.path}
            class="shell-rail__link"
            aria-current={if active?(@current_path, item.path), do: "page"}
            aria-label={item.label}
          >
            <span class="shell-rail__content">
              <.icon name={item.icon} />
              <span class="shell-rail__label">{item.label}</span>
            </span>
          </.link>
        </li>
        <%!-- Narrow screens keep only the header's Create. --%>
        <li class="shell-rail__item shell-rail__item--create">
          <Regent.Primitives.button
            :if={Autolaunch.Prelaunch.read_only?()}
            disabled
            class="create-button"
            title={"Opens #{Autolaunch.Prelaunch.opens_at_label()}"}
          >+ Create</Regent.Primitives.button>
          <.link
            :if={!Autolaunch.Prelaunch.read_only?()}
            href="/create"
            class="rg-button create-button"
            aria-current={if active?(@current_path, "/create"), do: "page"}
          >+ Create</.link>
        </li>
      </ul>
    </nav>
    """
  end

  def active?("/", "/"), do: true
  def active?(_path, "/"), do: false

  def active?(path, prefix) when is_binary(path) and is_binary(prefix) do
    path == prefix or String.starts_with?(path, prefix <> "/")
  end

  def active?(_path, _prefix), do: false

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
      <g :if={@name == :home}>
        <path d="M4 11.5 12 4l8 7.5" />
        <path d="M7 10.5V20h10v-9.5" />
      </g>
      <g :if={@name == :auctions}>
        <path d="M5 20h14" />
        <path d="M8 16 4 8l4-2 6 8" />
        <path d="M12 14h5l3 6" />
      </g>
      <g :if={@name == :tokens}>
        <circle cx="12" cy="12" r="7.25" />
        <path d="M12 8.5v7M9.5 10.25h3.4a2.1 2.1 0 0 1 0 4.2H9.5" />
      </g>
      <g :if={@name == :token_details}>
        <rect x="5" y="4" width="14" height="16" />
        <path d="M8.5 9h7M8.5 12.5h7M8.5 16h4" />
      </g>
      <g :if={@name == :portfolio}>
        <rect x="4.5" y="7" width="15" height="12" />
        <path d="M8 7V5.5h8V7" />
        <path d="M4.5 12h15" />
      </g>
      <svg
        :if={@name == :regent}
        x="2"
        y="5"
        width="20"
        height="14"
        viewBox="31 46 178 106"
        fill="currentColor"
        stroke="none"
      >
        <rect :for={x <- [31, 103, 175]} x={x} y="46" width="34" height="34" />
        <rect :for={x <- [31, 67, 103, 139, 175]} x={x} y="82" width="34" height="34" />
        <rect :for={x <- [31, 67, 103, 139, 175]} x={x} y="118" width="34" height="34" />
      </svg>
    </svg>
    """
  end
end
