defmodule AutolaunchWeb.Components.Rail do
  @moduledoc false
  use Phoenix.Component

  @items [
    %{id: :home, label: "Home", path: "/", icon: :home},
    %{id: :auctions, label: "Auctions", path: "/auctions", icon: :auctions},
    %{id: :tokens, label: "Tokens", path: "/tokens", icon: :tokens},
    %{id: :portfolio, label: "Portfolio", path: "/portfolio", icon: :portfolio},
    %{id: :regent, label: "REGENT", path: "/regent", icon: :regent},
    %{id: :create, label: "Create", path: "/create", icon: :create}
  ]

  attr :current_path, :string, required: true

  def rail(assigns) do
    assigns = assign(assigns, :items, @items)

    ~H"""
    <nav class="shell-rail" aria-label="Site">
      <a class="shell-wordmark" href="/">Autolaunch</a>
      <ul class="shell-rail__list">
        <li :for={item <- @items} class={item_class(item)}>
          <details :if={item.id == :create} id="rail-create-menu" class="shell-create-menu">
            <summary class="shell-rail__link rg-button rg-button--primary" aria-label="Create options">
              <span class="shell-rail__content"><.icon name={:create} /><span class="shell-rail__label">Create</span><span
                aria-hidden="true"
                class="shell-create-chevron"
              >⌄</span></span>
            </summary>
            <div class="shell-create-options">
              <Regent.Primitives.button
                disabled
                variant="secondary"
                title="Available after contract deployment"
              >Agent Revshare</Regent.Primitives.button>
              <Regent.Primitives.button
                disabled
                variant="secondary"
                title="Available after contract deployment"
              >Onchain Stock Pair</Regent.Primitives.button>
            </div>
          </details>
          <.link
            :if={item.id != :create}
            href={item.path}
            class={["shell-rail__link", item.id == :create && "rg-button rg-button--primary"]}
            aria-current={if active?(@current_path, item.path), do: "page"}
            aria-label={item.label}
          >
            <span class={["shell-rail__content", item.id == :create && "rg-button__label"]}>
              <.icon name={item.icon} />
              <span class="shell-rail__label">{item.label}</span>
            </span>
          </.link>
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

  defp item_class(%{id: :create}), do: "shell-rail__item shell-rail__item--create"
  defp item_class(_item), do: "shell-rail__item"

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
      <g :if={@name == :create}>
        <path d="M12 5v14M5 12h14" />
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
      <g :if={@name == :portfolio}>
        <rect x="4.5" y="7" width="15" height="12" />
        <path d="M8 7V5.5h8V7" />
        <path d="M4.5 12h15" />
      </g>
      <g :if={@name == :regent}>
        <path d="M12 3.75 20 12l-8 8.25L4 12z" />
      </g>
    </svg>
    """
  end
end
