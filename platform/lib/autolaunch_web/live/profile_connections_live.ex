defmodule AutolaunchWeb.ProfileConnectionsLive do
  @moduledoc """
  The connected accounts section of `/profile`, rendered inside the profile
  page. It reuses the Create page's connections component, so an account
  connected here is the same one Create shows.
  """
  use Phoenix.LiveView

  on_mount {AutolaunchWeb.Live.Session, :load_human}

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [current_human_id: 1]

  def mount(_params, _session, socket) do
    {:ok, assign(socket, current_human_id: current_human_id(socket.assigns.access_context))}
  end

  def handle_event("refresh_x_connections", _params, socket) do
    send_update(AutolaunchWeb.CreatorConnectionsComponent,
      id: "profile-connections",
      current_human_id: socket.assigns.current_human_id,
      session_lease: socket.assigns.session_lease
    )

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <.live_component
      :if={@current_human_id}
      module={AutolaunchWeb.CreatorConnectionsComponent}
      id="profile-connections"
      current_human_id={@current_human_id}
      session_lease={@session_lease}
    />
    """
  end
end
