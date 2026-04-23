defmodule AutolaunchWeb.StatusLive do
  use AutolaunchWeb, :live_view

  alias AutolaunchWeb.Live.Refreshable
  alias AutolaunchWeb.OperatorStatus

  @poll_ms 20_000

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> Refreshable.schedule(@poll_ms)
     |> Refreshable.subscribe(:system)
     |> assign(:page_title, "Status")
     |> assign(:active_view, "contracts")
     |> assign(:status, status_module().snapshot())}
  end

  def handle_event("refresh_status", _params, socket) do
    {:noreply, assign(socket, :status, status_module().snapshot())}
  end

  def handle_info(:refresh, socket) do
    {:noreply, Refreshable.refresh(socket, @poll_ms, &reload_status/1)}
  end

  def handle_info({:autolaunch_live_update, :changed}, socket) do
    {:noreply, reload_status(socket)}
  end

  def render(assigns) do
    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <section class="al-status-page">
        <header class="al-status-hero">
          <div>
            <p class="al-kicker">System status</p>
            <h1>{if @status.ok, do: "Autolaunch is ready.", else: "Autolaunch needs attention."}</h1>
            <p>
              A compact read on the services that keep launches, market pages, wallet actions,
              and agent sign-in moving.
            </p>
          </div>

          <div class="al-status-hero-actions">
            <span>Checked {checked_label(@status.checked_at)}</span>
            <button type="button" class="al-submit" phx-click="refresh_status">Refresh</button>
          </div>
        </header>

        <section id="status-check-grid" class="al-status-check-grid" phx-hook="MissionMotion">
          <article :for={check <- @status.checks} class={["al-status-check", state_class(check.state)]}>
            <div class="al-status-check-mark" aria-hidden="true">{state_mark(check.state)}</div>
            <div>
              <h2>{check.label}</h2>
              <p>{check.detail}</p>
            </div>
            <span>{state_label(check.state)}</span>
          </article>
        </section>
      </section>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end

  defp reload_status(socket), do: assign(socket, :status, status_module().snapshot())

  defp checked_label(%DateTime{} = checked_at) do
    Calendar.strftime(checked_at, "%-I:%M:%S %p UTC")
  end

  defp state_label(:ready), do: "Ready"
  defp state_label(:muted), do: "Optional"
  defp state_label(:blocked), do: "Attention"

  defp state_mark(:ready), do: "OK"
  defp state_mark(:muted), do: "--"
  defp state_mark(:blocked), do: "!!"

  defp state_class(:ready), do: "is-ready"
  defp state_class(:muted), do: "is-muted"
  defp state_class(:blocked), do: "is-blocked"

  defp status_module do
    :autolaunch
    |> Application.get_env(:status_live, [])
    |> Keyword.get(:status_module, OperatorStatus)
  end
end
