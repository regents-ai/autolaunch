defmodule AutolaunchWeb.LaunchLive do
  use AutolaunchWeb, :live_view

  alias AutolaunchWeb.LaunchLive.Presenter

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Launch")
     |> assign(:active_view, "launch")
     |> assign(:cli_command, Presenter.launch_command())
     |> assign(:launch_inputs, Presenter.launch_inputs())
     |> assign(:launch_flow, Presenter.launch_flow())
     |> assign(:launch_transcript, Presenter.launch_cli_transcript())}
  end

  def render(assigns) do
    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <section id="launch-cli-hero" class="al-hero al-launch-hero al-panel" phx-hook="MissionMotion">
        <div class="al-launch-copy">
          <p class="al-kicker">Launch console</p>
          <h2>Run the launch from one main path.</h2>
          <p class="al-subcopy">
            Save the plan, validate it, publish it, run the launch, and monitor the auction. Come
            back here when you need the exact sequence and the supporting checks in one place.
          </p>

          <div class="al-hero-actions">
            <button type="button" class="al-cta-link al-cta-link--primary" data-copy-value={@cli_command}>
              Copy wizard command
            </button>
            <.link navigate={~p"/launch-via-agent"} class="al-ghost">Operator briefs</.link>
            <.link navigate={~p"/auctions"} class="al-ghost">Browse auctions</.link>
          </div>

          <div class="al-launch-tags" aria-label="Launch summary">
            <span class="al-launch-tag">Save one plan</span>
            <span class="al-launch-tag">Base Sepolia + Base mainnet</span>
            <span class="al-launch-tag">Canonical operator path</span>
          </div>
        </div>

        <.terminal_command_panel
          kicker="Start here"
          title="Starter command"
          command={@cli_command}
          output_label="What happens next"
          output={@launch_transcript}
        />
      </section>

      <section id="launch-cli-steps" class="al-detail-layout" phx-hook="MissionMotion">
        <article id="launch-cli-inputs" class="al-panel al-card" phx-hook="MissionMotion">
          <div class="al-section-head">
            <div>
              <p class="al-kicker">What this does</p>
              <h3>One repeatable launch path</h3>
            </div>
          </div>

          <div class="al-note-grid">
            <article class="al-note-card">
              <span>Save once</span>
              <strong>Capture the full launch plan in the CLI.</strong>
              <p>Keep the operator wallet, Agent Safe, and metadata in one reviewed plan.</p>
            </article>

            <article class="al-note-card">
              <span>Validate once</span>
              <strong>Check the plan before you publish or deploy.</strong>
              <p>Minimum raise, routing, and launch settings are reviewed before chain actions start.</p>
            </article>

            <article class="al-note-card">
              <span>Run once</span>
              <strong>Launch, monitor, and finalize from the same thread of work.</strong>
              <p>The web app picks up after launch for bidding, claims, staking, and revenue reads.</p>
            </article>
          </div>
        </article>

        <article id="launch-cli-needs" class="al-panel al-card" phx-hook="MissionMotion">
          <div class="al-section-head">
            <div>
              <p class="al-kicker">What you need</p>
              <h3>Review these before you start</h3>
            </div>
          </div>

          <div class="al-review-grid">
            <article :for={item <- @launch_inputs} class="al-review-card">
              <span>{item.title}</span>
              <strong>{item.value}</strong>
              <p>{item.body}</p>
            </article>
          </div>
        </article>

        <article id="launch-cli-flow" class="al-panel al-card" phx-hook="MissionMotion">
          <div class="al-section-head">
            <div>
              <p class="al-kicker">What to run</p>
              <h3>The exact sequence</h3>
            </div>
          </div>

          <div class="al-step-row" aria-label="Launch phases">
            <.step_chip :for={step <- @launch_flow} index={step.index} label={step.label} />
          </div>

          <div class="al-compact-list">
            <p><code>regent autolaunch prelaunch wizard</code></p>
            <p><code>regent autolaunch prelaunch validate --plan &lt;plan-id&gt;</code></p>
            <p><code>regent autolaunch prelaunch publish --plan &lt;plan-id&gt;</code></p>
            <p><code>regent autolaunch launch run --plan &lt;plan-id&gt; --watch</code></p>
            <p><code>regent autolaunch launch monitor --job &lt;job-id&gt; --watch</code></p>
            <p><code>regent autolaunch launch finalize --job &lt;job-id&gt; --submit</code></p>
          </div>

          <p class="al-inline-note">
            Keep the full launch in the command line so the same reviewed plan stays in place from
            start to finish.
          </p>
        </article>
      </section>

      <section id="launch-cli-browser-role" class="al-panel al-directory-facts" phx-hook="MissionMotion">
        <div class="al-section-head">
          <div>
            <p class="al-kicker">What stays in the browser</p>
            <h3>Come back here after the launch is live</h3>
          </div>
        </div>

        <div class="al-directory-facts-grid">
          <article class="al-directory-fact-card">
            <span>Auctions</span>
            <strong>Track the live sale, update bids, and inspect returns.</strong>
            <p>Once the token is live, bidders should use the browser instead of the CLI.</p>
          </article>

          <article class="al-directory-fact-card">
            <span>Token holder actions</span>
            <strong>Claim, stake, unstake, and sweep from the token page.</strong>
            <p>Revenue management stays visible to token holders without reopening the launch flow.</p>
          </article>

          <article class="al-directory-fact-card">
            <span>Contract reads</span>
            <strong>Open the contracts page when you want to review addresses or prepare the next action.</strong>
            <p>Use it when you need more detail after the launch is already underway.</p>
          </article>
        </div>

        <div class="al-action-row">
          <.link navigate={~p"/launch-via-agent"} class="al-submit">How to use agents</.link>
          <.link navigate={~p"/auctions"} class="al-ghost">Browse active auctions</.link>
          <.link navigate={~p"/contracts"} class="al-ghost">Open contracts</.link>
        </div>
      </section>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end
end
