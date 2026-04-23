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
     |> assign_launch_state()
     |> assign_launch_focus()}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign_launch_focus(socket)}
  end

  def handle_event("change_metadata", %{"metadata" => metadata}, socket) do
    {:noreply, assign(socket, :metadata_form, Presenter.metadata_form(metadata))}
  end

  def handle_event("save_metadata", %{"metadata" => metadata}, socket) do
    case socket.assigns.launch_readiness.active_plan do
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Save a launch plan from the CLI before adding public details."
         )}

      %{plan_id: plan_id} ->
        save_plan_metadata(socket, plan_id, metadata)
    end
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

          <div class="al-route-hero-visual" aria-hidden="true">
            <div class="al-route-hero-visual-head">
              <span class="al-route-hero-visual-kicker">Launch path</span>
              <span class="al-route-hero-visual-pill">Base</span>
            </div>

            <div class="al-route-hero-track">
              <div class="al-route-hero-step is-active">
                <span>1</span>
                <strong>Plan</strong>
              </div>
              <div class="al-route-hero-step">
                <span>2</span>
                <strong>Deploy</strong>
              </div>
              <div class="al-route-hero-step">
                <span>3</span>
                <strong>Launch</strong>
              </div>
            </div>
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
              <article :for={item <- @launch_readiness.steps} class="al-launch-checklist-item">
                <div class="al-launch-checklist-mark" data-status={status_token(item.status)}></div>
                <div class="al-launch-checklist-copy">
                  <strong>{item.title}</strong>
                  <p>{item.detail}</p>
                </div>
                <span class={["al-launch-pill", status_token(item.status)]}>{item.status}</span>
              </article>
            </div>

            <div class="al-launch-next-action">
              <p class="al-kicker">Next action</p>
              <strong>{@launch_readiness.next_action.title}</strong>
              <p>{@launch_readiness.next_action.body}</p>

              <div class="al-launch-card-footer">
                <.link
                  :if={@launch_readiness.next_action.path}
                  navigate={@launch_readiness.next_action.path}
                  class="al-submit"
                >
                  {@launch_readiness.next_action.label}
                </.link>

                <button
                  :if={@launch_readiness.next_action.copy_command}
                  type="button"
                  class="al-submit"
                  data-copy-value={@launch_readiness.next_action.command || @cli_command}
                >
                  {@launch_readiness.next_action.label}
                </button>
              </div>
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
                Copy direct CLI command
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
                Open agent-assisted brief
              </.link>
            </div>
          </article>
        </section>

        <%= if @launch_readiness.active_plan do %>
          <section
            id="launch-plan-companion"
            class="al-launch-companion-grid"
            phx-hook="MissionMotion"
          >
            <article class="al-panel al-launch-metadata-card">
              <div class="al-section-head">
                <div>
                  <p class="al-kicker">Public details</p>
                  <h3>Complete the page people see before they bid.</h3>
                </div>
                <span class={["al-launch-pill", status_token(@launch_readiness.enrichment.status)]}>
                  {@launch_readiness.enrichment.status}
                </span>
              </div>

              <p class="al-inline-note">
                CLI starts the launch. Web completes public details and trust review.
              </p>

              <.form
                for={to_form(@metadata_form, as: :metadata)}
                id="launch-metadata-form"
                phx-change="change_metadata"
                phx-submit="save_metadata"
                class="al-launch-metadata-form"
              >
                <label>
                  <span>Title</span>
                  <input type="text" name="metadata[title]" value={@metadata_form["title"]} />
                </label>

                <label>
                  <span>Subtitle</span>
                  <input type="text" name="metadata[subtitle]" value={@metadata_form["subtitle"]} />
                </label>

                <label class="al-launch-field-wide">
                  <span>Description</span>
                  <textarea name="metadata[description]" rows="5"><%= @metadata_form["description"] %></textarea>
                </label>

                <label>
                  <span>Website</span>
                  <input
                    type="url"
                    name="metadata[website_url]"
                    value={@metadata_form["website_url"]}
                  />
                </label>

                <label>
                  <span>Image URL</span>
                  <input type="url" name="metadata[image_url]" value={@metadata_form["image_url"]} />
                </label>

                <div class="al-launch-form-actions">
                  <button type="submit" class="al-submit">Save public details</button>
                  <button type="button" class="al-ghost" data-copy-value={@cli_command}>
                    Copy CLI command
                  </button>
                </div>
              </.form>
            </article>

            <aside class="al-panel al-launch-preview-card">
              <div class="al-section-head">
                <div>
                  <p class="al-kicker">Plan preview</p>
                  <h3>{@launch_preview.title}</h3>
                </div>
              </div>

              <div class="al-launch-preview-art">
                <%= if @launch_preview.image_url do %>
                  <img src={@launch_preview.image_url} alt="" />
                <% else %>
                  <span aria-hidden="true">◎</span>
                <% end %>
              </div>

              <div class="al-launch-preview-copy">
                <strong>{@launch_preview.subtitle}</strong>
                <p>{@launch_preview.description}</p>
                <a :if={@launch_preview.website_url} href={@launch_preview.website_url}>
                  {@launch_preview.website_url}
                </a>
              </div>

              <div class="al-launch-trust-actions">
                <p class="al-kicker">Trust review</p>
                <.link :for={action <- @launch_readiness.trust_actions} navigate={action.path} class="al-ghost">
                  {action.label}
                </.link>
              </div>
            </aside>
          </section>
        <% else %>
          <section
            id="launch-plan-companion-empty"
            class="al-panel al-launch-companion-empty"
            phx-hook="MissionMotion"
          >
            <div>
              <p class="al-kicker">Plan companion</p>
              <h3>Save a plan from the CLI first.</h3>
              <p>
                After the plan exists, this space opens public details, preview, and trust review without moving launch execution into the browser.
              </p>
            </div>
            <button type="button" class="al-submit" data-copy-value={@cli_command}>
              Copy starter command
            </button>
          </section>
        <% end %>

        <section
          id="launch-footnote-strip"
          class="al-panel al-launch-footnote-strip"
          phx-hook="MissionMotion"
        >
          <div class="al-launch-footnote-copy">
            <p class="al-kicker">What comes next</p>
            <h3>Stay in one operator flow from command line to live market.</h3>
            <p>
              Use this page to review the saved plan, complete public details, and return for
              auctions, token holder actions, and contract review after the market is live.
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

  defp assign_launch_state(socket) do
    readiness =
      Presenter.launch_readiness(
        socket.assigns[:current_human],
        launch_module(),
        prelaunch_module()
      )

    socket
    |> assign(:launch_readiness, readiness)
    |> assign(:metadata_form, Presenter.metadata_form(readiness.active_plan))
    |> assign(:launch_preview, Presenter.metadata_preview(readiness.active_plan))
  end

  defp save_plan_metadata(socket, plan_id, metadata) do
    case prelaunch_module().update_metadata(
           plan_id,
           %{"metadata" => metadata},
           socket.assigns.current_human
         ) do
      {:ok, %{metadata_preview: preview}} ->
        {:noreply,
         socket
         |> assign_launch_state()
         |> assign(:metadata_form, Presenter.metadata_form(metadata))
         |> assign(:launch_preview, Presenter.metadata_preview(preview))
         |> put_flash(:info, "Public details saved.")}

      {:ok, _payload} ->
        {:noreply, socket |> assign_launch_state() |> put_flash(:info, "Public details saved.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Public details could not be saved.")}
    end
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
  defp status_token("Live"), do: "ready"
  defp status_token("Optional"), do: "optional"
  defp status_token("In progress"), do: "recommended"
  defp status_token(_status), do: "pending"

  defp route_css, do: @route_css

  defp launch_module do
    Application.get_env(:autolaunch, :launch_live, [])
    |> Keyword.get(:launch_module, Autolaunch.Launch)
  end

  defp prelaunch_module do
    Application.get_env(:autolaunch, :launch_live, [])
    |> Keyword.get(:prelaunch_module, Autolaunch.Prelaunch)
  end
end
