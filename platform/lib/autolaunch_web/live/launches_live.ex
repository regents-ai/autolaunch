defmodule AutolaunchWeb.LaunchesLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers

  def mount(_params, _session, socket) do
    {:ok,
     assign_async(socket, [:records, :creators], fn -> read_index(&Autolaunch.list_launches/0) end)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <section id="autolaunch-launches" class="autolaunch-page">
      <header class="autolaunch-heading">
        <p class="autolaunch-kicker">Autolaunch</p>
        <h1>Launches</h1>
        <p>Follow public launch progress from preparation through completion.</p>
      </header>
      <.empty_state
        :if={@records.ok? && @records.result == []}
        copy="No public launches yet."
      />
      <.empty_state
        :if={@records.failed}
        copy="Public launches are unavailable right now."
      />
      <ol :if={@records.ok? && @records.result != []} class="autolaunch-record-list">
        <li :for={launch <- @records.result}>
          <.link navigate={"/launches/#{launch.job_id}"}>
            <strong>{launch_label(launch)}</strong>
            <span>
              {display_action(launch.status)} · {display_action(launch.step)} · {launch_agent(launch)}
            </span>
          </.link>
          <.treasury_security report={report(launch)} surface={"launch-#{launch.job_id}"} />
        </li>
      </ol>
    </section>
    """
  end
end
