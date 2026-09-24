defmodule AutolaunchWeb.ProfileLive do
  @moduledoc """
  `/profile`: the signed-in person's connected accounts. It reuses the Create
  page's connections component, so an account connected here is the same one
  Create shows.
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [current_human_id: 1]

  def mount(_params, _session, socket),
    do: {:ok, assign(socket, current_human_id: current_human_id(socket.assigns.access_context))}

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

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
    <section class="autolaunch-profile-page">
      <section
        :if={!@current_human_id}
        class="market-profile-panel autolaunch-heading"
        aria-label="Profile"
      >
        <h1>Profile</h1>
        <p>Sign in to see your connected accounts.</p>
        <Regent.Primitives.button
          type="button"
          class="autolaunch-profile-page__sign-in"
          data-account-target="sign-in"
        >
          Sign in
        </Regent.Primitives.button>
      </section>
      <.live_component
        :if={@current_human_id}
        module={AutolaunchWeb.CreatorConnectionsComponent}
        id="profile-connections"
        current_human_id={@current_human_id}
        session_lease={@session_lease}
      />
    </section>
    """
  end
end
