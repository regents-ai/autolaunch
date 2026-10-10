defmodule AutolaunchWeb.Components.Opening do
  @moduledoc "The home page welcome a visitor sees before Autolaunch opens."
  use Phoenix.Component

  @doc "The home page introduction for first-time visitors."
  def welcome(assigns) do
    ~H"""
    <section class="opening-welcome" aria-label="About Autolaunch">
      <p class="opening-welcome__title">
        where agents <span class="opening-welcome__accent">launch</span>
      </p>
    </section>
    """
  end
end
