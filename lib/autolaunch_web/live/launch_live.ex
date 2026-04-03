defmodule AutolaunchWeb.LaunchLive do
  use AutolaunchWeb, :live_view

  @cli_command "regent autolaunch prelaunch wizard"
  @launch_inputs [
    %{
      title: "Identity",
      value: "Agent id and linked operator wallet",
      body:
        "Use the wallet that actually controls the ERC-8004 identity. Launch still signs through SIWA."
    },
    %{
      title: "Token basics",
      value: "Name, symbol, and minimum USDC raise",
      body:
        "The minimum raise is now a first-class launch setting. If the auction misses it, bidders can return their USDC."
    },
    %{
      title: "Treasury routing",
      value: "Recovery safe, auction proceeds recipient, and Ethereum revenue treasury",
      body:
        "These addresses are part of the signed launch configuration, so double-check them before you run the launch."
    },
    %{
      title: "Hosted metadata",
      value: "Title, description, and image",
      body:
        "The CLI wizard can upload the image and save the hosted launch metadata before publish and launch."
    }
  ]
  @launch_flow [
    %{index: 1, label: "Save plan"},
    %{index: 2, label: "Validate"},
    %{index: 3, label: "Publish"},
    %{index: 4, label: "Run"},
    %{index: 5, label: "Monitor"},
    %{index: 6, label: "Finalize"}
  ]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Launch")
     |> assign(:active_view, "launch")
     |> assign(:cli_command, @cli_command)
     |> assign(:launch_inputs, @launch_inputs)
     |> assign(:launch_flow, @launch_flow)}
  end

  def render(assigns) do
    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <section id="launch-cli-hero" class="al-hero al-launch-hero al-panel" phx-hook="MissionMotion">
        <div class="al-launch-copy">
          <p class="al-kicker">CLI-first launch</p>
          <h2>Launch planning lives in the CLI. The browser stays for review.</h2>
          <p class="al-subcopy">
            Use one saved plan, one validation pass, and one launch run. The web app still handles
            auctions, bids, returns, staking, and claims, but the launch itself now follows the
            same CLI path every time.
          </p>

          <div class="al-hero-actions">
            <.link navigate={~p"/launch-via-agent"} class="al-cta-link al-cta-link--primary">
              Launch via agent
            </.link>
            <.link navigate={~p"/auctions"} class="al-ghost">Browse active auctions</.link>
            <.link navigate={~p"/contracts"} class="al-ghost">Open contract console</.link>
          </div>

          <div class="al-launch-tags" aria-label="Launch summary">
            <span class="al-launch-tag">One saved plan</span>
            <span class="al-launch-tag">Ethereum Sepolia only</span>
            <span class="al-launch-tag">Minimum raise explicit</span>
          </div>
        </div>

        <.terminal_command_panel
          kicker="Start here"
          title="Starter command"
          command={@cli_command}
          output_label="What happens next"
          output={launch_transcript()}
        />
      </section>

      <section class="al-detail-layout">
        <article id="launch-cli-inputs" class="al-panel al-card" phx-hook="MissionMotion">
          <div class="al-section-head">
            <div>
              <p class="al-kicker">What the CLI needs</p>
              <h3>The exact launch inputs</h3>
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
              <p class="al-kicker">Copy-paste flow</p>
              <h3>The launch sequence</h3>
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
            The deploy still runs through the backend worker and Foundry script. The CLI just gives
            operators one consistent review path.
          </p>
        </article>
      </section>

      <section id="launch-cli-tradeoffs" class="al-panel al-directory-facts" phx-hook="MissionMotion">
        <div class="al-section-head">
          <div>
            <p class="al-kicker">Tradeoffs</p>
            <h3>Why the cutover happened</h3>
          </div>
        </div>

        <div class="al-directory-facts-grid">
          <article class="al-directory-fact-card">
            <span>Operator clarity</span>
            <strong>The same plan file now feeds validate, publish, and launch.</strong>
            <p>That cuts down on browser-only state and keeps launch review in one place.</p>
          </article>

          <article class="al-directory-fact-card">
            <span>Safer economics review</span>
            <strong>Minimum raise is explicit before launch.</strong>
            <p>That makes failed-auction refunds a planned behavior instead of an afterthought.</p>
          </article>

          <article class="al-directory-fact-card">
            <span>Web still matters</span>
            <strong>The browser remains the place for bidders and token holders.</strong>
            <p>Auctions, returns, positions, staking, and claims stay available here.</p>
          </article>
        </div>

        <div class="al-action-row">
          <.link navigate={~p"/launch-via-agent"} class="al-submit">How to use agents</.link>
          <.link navigate={~p"/auctions"} class="al-ghost">Browse active auctions</.link>
        </div>
      </section>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end

  defp launch_transcript do
    """
    > regent autolaunch prelaunch validate --plan plan_alpha
    > regent autolaunch prelaunch publish --plan plan_alpha
    > regent autolaunch launch run --plan plan_alpha --watch
    > regent autolaunch launch monitor --job job_alpha --watch
    > regent autolaunch launch finalize --job job_alpha --submit
    """
    |> String.trim()
  end
end
