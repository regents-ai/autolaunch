defmodule AutolaunchWeb.HomeLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <main>
      <h1>Autolaunch</h1>
    </main>
    """
  end
end
