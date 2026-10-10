defmodule AutolaunchWeb.Components.LearnNavigation do
  @moduledoc "The same Learn heading and route links on every information page."
  use AutolaunchWeb, :html

  @pages [
    {"How it works", "/how-it-works"},
    {"REGENT", "/regent"},
    {"Fees", "/convert"},
    {"Docs", "/docs"},
    {"About", "/about"},
    {"Blog", "/blog"},
    {"Contact", "/contact"},
    {"Privacy", "/privacy"},
    {"Terms", "/terms"}
  ]

  def paths, do: Enum.map(@pages, &elem(&1, 1))

  attr :current_path, :string, required: true

  def navigation(assigns) do
    assigns = assign(assigns, :pages, @pages)

    ~H"""
    <header :if={learn?(@current_path)} class="learn-navigation">
      <p class="learn-navigation__title">Learn</p>
      <nav aria-label="Learn pages">
        <.link
          :for={{label, path} <- @pages}
          href={path}
          aria-current={if current?(@current_path, path), do: "page"}
        >
          {label}
        </.link>
      </nav>
    </header>
    """
  end

  defp learn?(path), do: Enum.any?(@pages, fn {_, page} -> current?(path, page) end)
  defp current?(path, page), do: path == page or String.starts_with?(path, page <> "/")
end
