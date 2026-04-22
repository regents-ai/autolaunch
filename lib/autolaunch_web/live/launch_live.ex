defmodule AutolaunchWeb.LaunchLive do
  use AutolaunchWeb, :live_view

  alias AutolaunchWeb.LaunchLive.Presenter

  @route_css_path Path.expand("../../../priv/static/launch-docs-live.css", __DIR__)
  @external_resource @route_css_path
  @route_css File.read!(@route_css_path)

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Launch")
     |> assign(:active_view, "launch")
     |> assign(:cli_command, Presenter.launch_command())
     |> assign(:launch_transcript, Presenter.launch_cli_transcript())
     |> assign(:launch_console_steps, Presenter.launch_console_steps())
     |> assign(:launch_flow, Presenter.launch_flow())
     |> assign(:launch_inputs, Presenter.launch_inputs())
     |> assign(:direct_operator_cards, Presenter.direct_operator_cards())
     |> assign(:operator_guides, Presenter.operator_guides())
     |> assign(:agent_assisted_cards, Presenter.agent_assisted_cards())
     |> assign_launch_focus()}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign_launch_focus(socket)}
  end

  def render(assigns) do
    ~H"""
    <style><%= Phoenix.HTML.raw(route_css()) %></style>
    <.shell current_human={@current_human} active_view={@active_view}>
      <div id="al-launch-page" data-focus={@path_focus}>
        <section
          id="launch-route-hero"
          class="al-panel al-route-hero al-route-hero--launch"
          phx-hook="MissionMotion"
        >
          <div class="al-route-hero-copy">
            <p class="al-kicker">Launch</p>
            <h2>Launch your agent on Base, the right way.</h2>
            <p class="al-subcopy">
              Start with one saved plan, review the path once, and choose whether you want to run
              the launch yourself or hand the execution to an operator agent.
            </p>
          </div>
        </section>

        <section
          id="launch-console-strip"
          class="al-panel al-launch-console-strip"
          phx-hook="MissionMotion"
        >
          <div class="al-launch-console-shell">
            <div class="al-launch-console-head">
              <div class="al-launch-console-badge">
                <span aria-hidden="true">⌁</span>
              </div>

              <div>
                <p class="al-kicker">Launch console</p>
                <h3>Starter command</h3>
              </div>
            </div>

            <div class="al-launch-command-bar">
              <code>{@cli_command} --chain base-sepolia</code>
              <button type="button" class="al-submit" data-copy-value={@cli_command}>
                Copy command
              </button>
            </div>

            <p class="al-inline-note">
              Run this in your terminal to start the guided launch flow.
            </p>
          </div>

          <ol class="al-launch-console-steps" aria-label="Launch path overview">
            <li :for={step <- @launch_console_steps}>
              <span class="al-launch-console-step-mark" aria-hidden="true"></span>
              <div>
                <strong>{step.title}</strong>
                <p>{step.body}</p>
              </div>
            </li>
          </ol>
        </section>

        <section id="launch-split-layout" class="al-launch-split-layout" phx-hook="MissionMotion">
          <article class="al-panel al-launch-checklist-card">
            <div class="al-section-head">
              <div>
                <p class="al-kicker">Checklist</p>
                <h3>Review launch setup</h3>
              </div>
            </div>

            <div class="al-launch-checklist">
              <article :for={item <- Presenter.launch_checklist(@current_human)} class="al-launch-checklist-item">
                <div class="al-launch-checklist-mark" data-status={status_token(item.status)}></div>
                <div class="al-launch-checklist-copy">
                  <strong>{item.title}</strong>
                  <p>{item.detail || "Connect wallet"}</p>
                </div>
                <span class={["al-launch-pill", status_token(item.status)]}>{item.status}</span>
              </article>
            </div>

            <div class="al-launch-card-footer">
              <button type="button" class="al-ghost" data-copy-value={@cli_command}>
                Review launch setup
              </button>
            </div>
          </article>

          <article class={["al-panel al-launch-path-card", @path_focus == "direct" && "is-focused"]}>
            <div class="al-launch-path-head">
              <div class="al-launch-path-icon" aria-hidden="true">◎</div>
              <div>
                <p class="al-kicker">Direct operator path</p>
                <h3>You run the commands. You stay in control.</h3>
              </div>
            </div>

            <div class="al-launch-path-list">
              <article :for={item <- @direct_operator_cards}>
                <strong>{item.title}</strong>
                <p>{item.body}</p>
              </article>
            </div>

            <div class="al-launch-card-footer">
              <button type="button" class="al-submit" data-copy-value={@cli_command}>
                Start direct operator flow
              </button>
            </div>
          </article>

          <article class={["al-panel al-launch-path-card is-agent", @path_focus == "agent" && "is-focused"]}>
            <div class="al-launch-path-head">
              <div class="al-launch-path-icon" aria-hidden="true">✦</div>
              <div>
                <p class="al-kicker">Agent-assisted path</p>
                <h3>Let an agent carry the launch while you approve the steps.</h3>
              </div>
            </div>

            <div class="al-launch-agent-guides">
              <article :for={guide <- @operator_guides} class="al-launch-agent-guide">
                <div>
                  <strong>{guide.eyebrow}</strong>
                  <p>{guide.title}</p>
                </div>

                <div class="al-launch-agent-guide-actions">
                  <span :if={guide.status} class="al-launch-pill recommended">{guide.status}</span>
                  <button type="button" class="al-ghost" data-copy-value={guide.prompt}>
                    {guide.copy_label}
                  </button>
                </div>
              </article>
            </div>

            <div class="al-launch-path-list">
              <article :for={item <- @agent_assisted_cards}>
                <strong>{item.title}</strong>
                <p>{item.body}</p>
              </article>
            </div>

            <div class="al-launch-card-footer">
              <.link navigate={~p"/launch-via-agent"} class="al-submit">
                Start agent-assisted flow
              </.link>
            </div>
          </article>
        </section>

        <section
          id="launch-footnote-strip"
          class="al-panel al-launch-footnote-strip"
          phx-hook="MissionMotion"
        >
          <div class="al-launch-footnote-copy">
            <p class="al-kicker">What comes next</p>
            <h3>Stay in one operator flow from command line to live market.</h3>
            <p>
              Use this page to start the run. Come back for auctions, token holder actions, and
              contract review after the market is live.
            </p>
          </div>

          <div class="al-action-row">
            <.link navigate={~p"/auctions"} class="al-ghost">Open auctions</.link>
            <.link navigate={~p"/how-auctions-work"} class="al-ghost">How auctions work</.link>
            <.link navigate={~p"/contracts"} class="al-ghost">Open contracts</.link>
          </div>
        </section>
      </div>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end

  defp assign_launch_focus(socket) do
    path_focus =
      case socket.assigns.live_action do
        :agent -> "agent"
        _ -> "direct"
      end

    assign(socket, :path_focus, path_focus)
  end

  defp status_token("Connected"), do: "connected"
  defp status_token("Ready"), do: "ready"
  defp status_token("Optional"), do: "optional"
  defp status_token(_status), do: "pending"

  defp route_css, do: @route_css
end
