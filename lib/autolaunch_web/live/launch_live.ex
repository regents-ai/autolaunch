defmodule AutolaunchWeb.LaunchLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.Launch
  alias AutolaunchWeb.LaunchLive.{Flow, Presenter}
  alias AutolaunchWeb.RegentScenes

  @job_poll_ms 2_000
  def mount(_params, _session, socket) do
    current_human = socket.assigns[:current_human]
    agents = launch_module().list_agents(current_human)
    form = Flow.default_form(current_human)

    {:ok,
     socket
     |> assign(:page_title, "Launch")
     |> assign(:active_view, "launch")
     |> assign(:agents, agents)
     |> assign(:selected_agent_id, nil)
     |> assign(:selected_agent, nil)
     |> assign(:readiness, nil)
     |> assign(:form, form)
     |> assign(:preview, nil)
     |> assign(:step, 1)
     |> assign(:launching, false)
     |> assign(:job_id, nil)
     |> assign(:current_job, nil)
     |> assign(:fee_split, launch_module().fee_split_summary())
     |> assign_regent_scene()}
  end

  def handle_event("select_agent", %{"agent_id" => agent_id}, socket) do
    case Enum.find(socket.assigns.agents, &(&1.agent_id == agent_id or &1.id == agent_id)) do
      %{state: "eligible"} = agent ->
        readiness =
          launch_module().launch_readiness_for_agent(socket.assigns.current_human, agent.agent_id)

        form =
          socket.assigns.form
          |> Map.put("agent_id", agent.agent_id)

        {:noreply,
         socket
         |> assign(:selected_agent_id, agent.agent_id)
         |> assign(:selected_agent, agent)
         |> assign(:readiness, readiness)
         |> assign(:form, form)
         |> assign(:preview, nil)
         |> assign(:step, 2)
         |> assign_regent_scene()}

      %{state: state} ->
        {:noreply, put_flash(socket, :error, "Agent is #{String.replace(state, "_", " ")}.")}

      nil ->
        {:noreply, put_flash(socket, :error, "Agent not found.")}
    end
  end

  def handle_event("form_changed", %{"launch" => attrs}, socket) do
    {:noreply, assign(socket, :form, Map.merge(socket.assigns.form, attrs))}
  end

  def handle_event("go_to_step", %{"step" => step}, socket) do
    target_step = Flow.normalize_step(step)

    {:noreply,
     socket
     |> assign(:step, min(target_step, Flow.max_available_step(socket.assigns)))
     |> assign_regent_scene()}
  end

  def handle_event("prepare_review", _params, socket) do
    case launch_module().preview_launch(socket.assigns.form, socket.assigns.current_human) do
      {:ok, preview} ->
        {:noreply,
         socket |> assign(:preview, preview) |> assign(:step, 3) |> assign_regent_scene()}

      {:error, {:agent_not_eligible, _agent}} ->
        {:noreply, put_flash(socket, :error, "Selected agent is no longer eligible to launch.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Privy session required before launch.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Flow.preview_error(reason))}
    end
  end

  def handle_event("launch_submitting", _params, socket) do
    {:noreply, socket |> assign(:launching, true) |> assign_regent_scene()}
  end

  def handle_event("launch_error", %{"message" => message}, socket) do
    {:noreply,
     socket |> assign(:launching, false) |> assign_regent_scene() |> put_flash(:error, message)}
  end

  def handle_event("launch_queued", %{"job_id" => job_id}, socket) do
    if connected?(socket), do: Process.send_after(self(), {:poll_job, job_id}, 100)

    {:noreply,
     socket
     |> put_flash(:info, "Launch job queued.")
     |> assign(:launching, false)
     |> assign(:job_id, job_id)
     |> assign(:step, 4)
     |> assign_regent_scene()}
  end

  def handle_event("regent:node_select", %{"meta" => %{"step" => step}}, socket) do
    handle_event("go_to_step", %{"step" => step}, socket)
  end

  def handle_event("regent:node_select", _params, socket), do: {:noreply, socket}

  def handle_event("regent:node_hover", _params, socket), do: {:noreply, socket}
  def handle_event("regent:surface_ready", _params, socket), do: {:noreply, socket}

  def handle_event("regent:surface_error", _params, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "The launch control surface could not render in this browser session."
     )}
  end

  def handle_info({:poll_job, job_id}, socket) do
    case launch_module().get_job_response(job_id) do
      %{job: job} = response ->
        socket = socket |> assign(:current_job, response) |> assign_regent_scene()

        if launch_module().terminal_status?(job.status) do
          flash =
            case job.status do
              "ready" -> put_flash(socket, :info, "Launch stack is live.")
              _ -> put_flash(socket, :error, job.error_message || "Launch job failed.")
            end

          {:noreply, flash}
        else
          Process.send_after(self(), {:poll_job, job_id}, @job_poll_ms)
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def render(assigns) do
    eligible_count = Enum.count(assigns.agents, &(&1.state == "eligible"))
    selected_agent = assigns.selected_agent

    current_reputation_prompt =
      Flow.current_reputation_prompt(assigns.preview, assigns.current_job)

    assigns =
      assigns
      |> assign(:eligible_count, eligible_count)
      |> assign(:selected_agent, selected_agent)
      |> assign(:current_reputation_prompt, current_reputation_prompt)
      |> assign(:regent_step_title, Presenter.regent_step_title(assigns.step))
      |> assign(
        :regent_step_summary,
        Presenter.regent_step_summary(assigns.step, selected_agent, assigns.current_job)
      )

    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <section class="al-regent-shell">
        <.surface
          id="launch-regent-surface"
          class="rg-regent-theme-autolaunch"
          scene={@regent_scene}
          scene_version={@regent_scene_version}
          selected_node_id={@regent_selected_node_id}
          theme="autolaunch"
          camera_distance={24}
        >
          <:chamber>
            <.chamber
              id="launch-regent-chamber"
              title={@regent_step_title}
              subtitle={"Step #{@step}"}
              summary={@regent_step_summary}
            >
              <div class="al-launch-tags" aria-label="Launch scene status">
                <span class="al-launch-tag">Eligible agents: {@eligible_count}</span>
                <span class="al-launch-tag">Fee split: 2% total</span>
                <span class="al-launch-tag">{Presenter.regent_job_status(@current_job)}</span>
              </div>
            </.chamber>
          </:chamber>

          <:ledger>
            <.ledger
              id="launch-regent-ledger"
              title="Control notes"
              subtitle="The sigil surface keeps orientation short. The wizard below still owns the real launch inputs, review, and signing."
            >
              <table class="rg-table">
                <tbody>
                  <tr>
                    <th scope="row">Current step</th>
                    <td>{@step}</td>
                  </tr>
                  <tr>
                    <th scope="row">Selected agent</th>
                    <td>{(@selected_agent && (@selected_agent.name || @selected_agent.agent_id)) || "Not selected"}</td>
                  </tr>
                  <tr>
                    <th scope="row">Queue state</th>
                    <td>{Presenter.regent_job_status(@current_job)}</td>
                  </tr>
                </tbody>
              </table>
            </.ledger>
          </:ledger>
        </.surface>
      </section>

      <section id="launch-hero" class="al-hero al-launch-hero al-panel" phx-hook="MissionMotion">
        <div class="al-launch-copy">
          <p class="al-kicker">Autolaunch</p>
          <h2>Launch the Agent Coin flow from one operator-grade surface.</h2>
          <p class="al-subcopy">
            The browser wizard is still here, but the main operator path now starts in the CLI:
            prelaunch the launch plan, run the launch, monitor the auction, finalize the post-auction
            actions, then release vested tokens later. This page stays useful for direct review and queue visibility.
          </p>

          <div class="al-hero-actions">
            <button
              type="button"
              class="al-cta-link al-cta-link--primary"
              data-copy-value={launch_hero_command()}
            >
              Copy `regent autolaunch prelaunch wizard` example
            </button>
            <a class="al-cta-link" href="https://github.com/regent-ai/autolaunch" target="_blank" rel="noreferrer">Star on GitHub</a>
            <a class="al-cta-link al-cta-link--quiet" href="#launch-wizard">Jump to wizard</a>
          </div>

          <div class="al-launch-tags" aria-label="Launch themes">
            <span class="al-launch-tag">ERC-8004 identity</span>
            <span class="al-launch-tag">10% sold, 100B total</span>
            <span class="al-launch-tag">USDC on Ethereum Sepolia</span>
          </div>

          <div class="al-stat-grid al-launch-stats">
            <.stat_card title="Launch path" value="Wizard + live queue" hint="Choose an agent, review, sign, and queue" />
            <.stat_card title="Eligible agents" value={Integer.to_string(@eligible_count)} hint="Owner or operator access" />
            <.stat_card title="Fee split" value="2% total" hint={@fee_split.headline} />
          </div>
        </div>

        <aside class="al-terminal-panel" aria-label="Launch command preview">
          <div class="al-terminal-shell">
            <div class="al-terminal-topbar">
              <div class="al-terminal-dots" aria-hidden="true">
                <span></span>
                <span></span>
                <span></span>
              </div>
              <div>
                <p class="al-kicker">Golden path</p>
                <p class="al-terminal-title">CLI-first launch flow</p>
              </div>
              <button
                type="button"
                class="al-copy-trigger"
                data-copy-value={launch_hero_command()}
              >
                Copy command
              </button>
            </div>

            <pre class="al-terminal-command"><code>{launch_hero_command()}</code></pre>

            <div class="al-terminal-output">
              <p class="al-terminal-output-label">Output</p>
              <pre><code>{launch_hero_transcript()}</code></pre>
            </div>
          </div>
        </aside>
      </section>

      <section
        id="launch-onboard"
        class="al-launch-onboard al-panel"
        phx-hook="MissionMotion"
        aria-label="Before you launch"
      >
        <div class="al-onboard-summary">
          <p class="al-kicker">Before you launch</p>
          <h3>The first pass should feel short, direct, and easy to verify.</h3>
          <p class="al-subcopy">
            The safest operator path is now: save a prelaunch plan in the CLI, validate it against
            backend checks, publish the hosted metadata draft, then queue the launch from that saved plan.
          </p>
        </div>

        <div class="al-onboard-grid">
          <article class="al-onboard-card">
            <p class="al-onboard-mark">01</p>
            <strong>Start with the CLI prelaunch plan, not raw launch flags.</strong>
            <p>
              The backend now tracks one opinionated launch draft per agent identity. Use that to
              lock the image, safes, backup wallet, and launch blockers before you sign anything.
            </p>
          </article>

          <article class="al-onboard-card">
            <p class="al-onboard-mark">02</p>
            <strong>Use the browser for review, not as the only source of truth.</strong>
            <p>
              The sale size stays fixed at 10% of a 100 billion supply, and only Sepolia USDC that
              reaches the revenue share splitter counts for staking. The CLI plan is the cleaner way
              to confirm where proceeds, treasury, and fallback control should route.
            </p>
          </article>

          <article class="al-onboard-card">
            <p class="al-onboard-mark">03</p>
            <strong>After launch, switch back to CLI monitor and finalize.</strong>
            <p>
              Migration, currency sweep, token sweep, and vesting release are still lifecycle steps.
              The CLI now owns that guided operator flow, while this page keeps the live queue and auction links visible.
            </p>
          </article>
        </div>
      </section>

      <section id="launch-wizard" class="al-wizard-layout" phx-hook="MissionMotion">
        <article class="al-panel al-main-panel">
          <div class="al-step-intro">
            Use the browser wizard for local review if needed, but treat the CLI golden path as the
            primary launch route: prelaunch, launch run, monitor, finalize, then vesting status.
          </div>

          <div class="al-step-row">
            <.step_chip index={1} label="Choose agent" active={@step == 1} complete={@step > 1} />
            <.step_chip index={2} label="Configure token" active={@step == 2} complete={@step > 2} />
            <.step_chip index={3} label="Review and sign" active={@step == 3} complete={@step > 3} />
            <.step_chip index={4} label="Optional trust check" active={@step == 4} complete={@step > 4} />
            <.step_chip index={5} label="Deployment status" active={@step == 5} complete={false} />
          </div>

          <%= if @step == 1 do %>
            <div class="al-section-head">
              <div>
                <p class="al-kicker">Step 1</p>
                <h3>Choose an eligible agent</h3>
              </div>
            </div>

            <%= cond do %>
              <% is_nil(@current_human) -> %>
                <.empty_state
                  title="Connect with Privy to inspect your ERC-8004 identities."
                  body="Linked wallets are checked for ERC-8004 owner and operator access. Wallet-bound identities are shown separately but cannot launch by themselves."
                />
              <% @agents == [] -> %>
                <.empty_state
                  title="No ERC-8004 identities found for your linked wallets."
                  body="Connect a wallet that owns or operates an ERC-8004 identity, or mint a new identity first."
                />
              <% true -> %>
                <div class="al-agent-grid">
                  <%= for agent <- @agents do %>
                    <article class={["al-agent-card", agent.state == "eligible" && "is-selectable"]}>
                      <div class="al-agent-media">
                        <%= if agent.image_url do %>
                          <img src={agent.image_url} alt={agent.name} class="al-agent-image" />
                        <% else %>
                          <div class="al-agent-image al-agent-image--placeholder">
                            <span>ERC-8004</span>
                          </div>
                        <% end %>
                      </div>

                      <div class="al-agent-card-head">
                        <div>
                          <p class="al-kicker">{agent.source}</p>
                          <h3>{agent.name}</h3>
                          <p class="al-inline-note">{agent.agent_id}</p>
                        </div>
                        <.agent_state_badge state={agent.state} />
                      </div>

                      <div class="al-pill-row">
                        <span class={["al-network-badge", "al-access-badge"]}>{Presenter.access_mode_label(agent.access_mode)}</span>
                        <span :for={chain <- agent.supported_chains} class="al-network-badge">{chain.short_label}</span>
                      </div>

                      <dl class="al-agent-meta">
                        <div>
                          <dt>Owner</dt>
                          <dd>{Presenter.short_address(agent.owner_address)}</dd>
                        </div>
                        <div :if={(agent.operator_addresses || []) != []}>
                          <dt>Operators</dt>
                          <dd>{Enum.count(agent.operator_addresses)}</dd>
                        </div>
                        <div :if={agent.ens}>
                          <dt>ENS</dt>
                          <dd>{agent.ens}</dd>
                        </div>
                        <div>
                          <dt>Token ID</dt>
                          <dd>{agent.token_id}</dd>
                        </div>
                      </dl>

                      <p :if={agent.description} class="al-inline-note">{agent.description}</p>

                      <%= if agent.blocker_texts != [] do %>
                        <ul class="al-compact-list">
                          <li :for={blocker <- agent.blocker_texts}>{blocker}</li>
                        </ul>
                      <% else %>
                        <p class="al-inline-note">Launch path is clear for this ERC-8004 identity.</p>
                      <% end %>

                      <button
                        :if={agent.state == "eligible"}
                        type="button"
                        class="al-submit"
                        phx-click="select_agent"
                        phx-value-agent_id={agent.agent_id}
                      >
                        Use this agent
                      </button>

                      <div :if={agent.state != "eligible"} class="al-muted-box">
                        {Presenter.disabled_agent_message(agent)}
                      </div>
                    </article>
                  <% end %>
                </div>
              <% end %>
          <% end %>

          <%= if @step == 2 do %>
            <div class="al-section-head">
              <div>
                <p class="al-kicker">Step 2</p>
                <h3>Configure launch details</h3>
              </div>
            </div>

            <form phx-change="form_changed" class="al-form">
              <input type="hidden" name="launch[agent_id]" value={@form["agent_id"]} />

              <div class="al-field-grid">
                <label>
                  <span>Name</span>
                  <input type="text" name="launch[token_name]" value={@form["token_name"]} placeholder="Agent Coin Name" />
                </label>
                <label>
                  <span>Symbol</span>
                  <input type="text" name="launch[token_symbol]" value={@form["token_symbol"]} placeholder="AGENT-N" />
                </label>
                <label>
                  <span>Recovery Safe (Ethereum)</span>
                  <input
                    type="text"
                    name="launch[recovery_safe_address]"
                    value={@form["recovery_safe_address"]}
                    placeholder="0x..."
                  />
                </label>
                <label>
                  <span>Auction proceeds recipient</span>
                  <input
                    type="text"
                    name="launch[auction_proceeds_recipient]"
                    value={@form["auction_proceeds_recipient"]}
                    placeholder="0x..."
                  />
                </label>
                <label>
                  <span>Ethereum revenue treasury</span>
                  <input
                    type="text"
                    name="launch[ethereum_revenue_treasury]"
                    value={@form["ethereum_revenue_treasury"]}
                    placeholder="0x..."
                  />
                </label>
              </div>

              <label>
                <span>Launch notes</span>
                <textarea name="launch[launch_notes]" rows="4">{@form["launch_notes"]}</textarea>
              </label>
            </form>

            <div class="al-inline-banner">
              <strong>{@fee_split.headline}</strong>
              <p>
                Launch runs on Ethereum Sepolia only. Supply is fixed at 100 billion, the auction
                sells 10%, and recognized revenue means Sepolia USDC that reaches the revenue share splitter
                before stakers can claim from recognized revenue.
              </p>
            </div>

            <div class="al-action-row">
              <button type="button" class="al-ghost" phx-click="go_to_step" phx-value-step="1">Back</button>
              <button type="button" class="al-submit" phx-click="prepare_review">Review economics and sign</button>
            </div>
          <% end %>

          <%= if @step == 3 do %>
            <div class="al-section-head">
              <div>
                <p class="al-kicker">Step 3</p>
                <h3>Review economics and sign</h3>
              </div>
            </div>

            <div id="launch-review-root" phx-hook="LaunchForm" class="al-review-stack">
              <input type="hidden" name="launch[agent_id]" value={@form["agent_id"]} />
              <input type="hidden" name="launch[token_name]" value={@form["token_name"]} />
              <input type="hidden" name="launch[token_symbol]" value={@form["token_symbol"]} />
              <input type="hidden" name="launch[recovery_safe_address]" value={@form["recovery_safe_address"]} />
              <input type="hidden" name="launch[auction_proceeds_recipient]" value={@form["auction_proceeds_recipient"]} />
              <input type="hidden" name="launch[ethereum_revenue_treasury]" value={@form["ethereum_revenue_treasury"]} />
              <input type="hidden" name="launch[total_supply]" value={@form["total_supply"]} />
              <textarea class="hidden" name="launch[launch_notes]"><%= @form["launch_notes"] %></textarea>

              <div class="al-review-grid">
                <div class="al-review-card">
                  <span>Agent</span>
                  <strong>{@selected_agent && @selected_agent.name}</strong>
                  <p>{@selected_agent && @selected_agent.agent_id}</p>
                </div>
                <div class="al-review-card">
                  <span>Token</span>
                  <strong>{@preview && @preview.token.name}</strong>
                  <p>{@preview && @preview.token.symbol}</p>
                </div>
                <div class="al-review-card">
                  <span>Launch network</span>
                  <strong>{@preview && @preview.token.chain_label}</strong>
                  <p>Recovery Safe {@preview && Presenter.short_address(@preview.token.recovery_safe_address)}</p>
                </div>
                <div class="al-review-card">
                  <span>Fixed supply</span>
                  <strong>100B Agent Coin</strong>
                  <p>10% is sold in the auction and 90% stays with the subject side.</p>
                </div>
                <div class="al-review-card">
                  <span>Revenue routing</span>
                  <strong>USDC treasury {@preview && Presenter.short_address(@preview.token.ethereum_revenue_treasury)}</strong>
                  <p>Sepolia USDC only counts after it reaches the revenue share splitter.</p>
                </div>
              </div>

              <div class="al-note-grid">
                <article class="al-note-card">
                  <p class="al-kicker">What happens next</p>
                  <ul class="al-compact-list">
                    <li :for={item <- (@preview && @preview.next_steps) || []}>{item}</li>
                  </ul>
                </article>
                <article class="al-note-card">
                  <p class="al-kicker">Permanence notes</p>
                  <ul class="al-compact-list">
                    <li :for={item <- (@preview && @preview.permanence_notes) || []}>{item}</li>
                  </ul>
                </article>
              </div>

              <article :if={@preview && @preview.reputation_prompt} class="al-note-card">
                <p class="al-kicker">Optional trust check</p>
                <strong>{@preview.reputation_prompt.prompt}</strong>
                <p>{@preview.reputation_prompt.warning}</p>
                <ul class="al-compact-list">
                  <li :for={instruction <- @preview.reputation_prompt.instructions}>{instruction}</li>
                </ul>
                <p class="al-inline-note">
                  The next screen gives the links and lets you skip this without blocking launch.
                </p>
              </article>

              <div class="al-action-row">
                <button type="button" class="al-ghost" phx-click="go_to_step" phx-value-step="2">Edit configuration</button>
                <button
                  type="button"
                  class={["al-submit", @launching && "is-disabled"]}
                  data-launch-submit
                  data-launch-chain-id={@preview && @preview.token.chain_id}
                  data-launch-endpoint={~p"/api/launch/jobs"}
                  data-nonce-endpoint="/v1/agent/siwa/nonce"
                  disabled={@launching}
                >
                  {if @launching, do: "Waiting for signature...", else: "Sign and queue launch"}
                </button>
              </div>
            </div>
          <% end %>

          <%= if @step == 4 do %>
            <div class="al-section-head">
              <div>
                <p class="al-kicker">Step 4</p>
                <h3>Optional trust check</h3>
              </div>
            </div>

            <%= if @current_reputation_prompt do %>
              <div class="al-note-grid">
                <article class="al-note-card">
                  <p class="al-kicker">Optional</p>
                  <strong>{@current_reputation_prompt.prompt}</strong>
                  <p>{@current_reputation_prompt.warning}</p>
                  <ul class="al-compact-list">
                    <li :for={instruction <- @current_reputation_prompt.instructions}>
                      {instruction}
                    </li>
                  </ul>
                </article>

                <article
                  :for={action <- @current_reputation_prompt.actions}
                  class="al-note-card"
                >
                  <p class="al-kicker">{Presenter.reputation_action_status(action.status)}</p>
                  <strong>{action.label}</strong>
                  <p>{action.note}</p>
                  <div class="al-pill-row">
                    <.link
                      :if={action.action_url}
                      navigate={action.action_url}
                      class="al-cta-link"
                    >
                      {reputation_action_cta(action)}
                    </.link>
                  </div>
                </article>

                <article :if={@current_job} class="al-note-card">
                  <p class="al-kicker">Deployment job</p>
                  <ul class="al-compact-list">
                    <li>Status: <strong>{@current_job.job.status}</strong></li>
                    <li>Step: <strong>{@current_job.job.step}</strong></li>
                    <li>Job id: <strong>{@current_job.job.job_id}</strong></li>
                  </ul>
                </article>
              </div>

              <div class="al-action-row">
                <button type="button" class="al-ghost" phx-click="go_to_step" phx-value-step="5">
                  {@current_reputation_prompt.skip_label}
                </button>
                <button type="button" class="al-submit" phx-click="go_to_step" phx-value-step="5">
                  Continue to launch status
                </button>
              </div>
            <% else %>
              <p class="al-inline-note">Waiting for launch job response.</p>
            <% end %>
          <% end %>

          <%= if @step == 5 do %>
            <div class="al-section-head">
              <div>
                <p class="al-kicker">Step 5</p>
                <h3>Queued and processing</h3>
              </div>
            </div>

            <%= if @current_job do %>
              <div class="al-job-grid">
                <div>
                  <span>Status</span>
                  <strong>{@current_job.job.status}</strong>
                </div>
                <div>
                  <span>Step</span>
                  <strong>{@current_job.job.step}</strong>
                </div>
                <div>
                  <span>Chain</span>
                  <strong>{@current_job.job.chain_label || @current_job.job.network}</strong>
                </div>
                <div>
                  <span>Job id</span>
                  <strong>{@current_job.job.job_id}</strong>
                </div>
              </div>

              <div class="al-note-grid">
                <article class="al-note-card">
                  <p class="al-kicker">Timeline</p>
                  <ul class="al-compact-list">
                    <li>Queued for launch orchestration.</li>
                    <li>Waiting for the deploy script to return the launch stack and routing addresses.</li>
                    <li :if={@current_job.auction}>Auction page becomes available after deployment.</li>
                    <li :if={@current_job.job.status == "ready"}>Bought tokens still need to be staked before they earn revenue.</li>
                  </ul>
                </article>

                <article class="al-note-card">
                  <p class="al-kicker">Next action</p>
                  <%= if @current_job.auction do %>
                    <div class="al-action-row">
                      <.link navigate={~p"/auctions/#{@current_job.auction.id}"} class="al-cta-link">
                        Open auction detail
                      </.link>
                      <.link
                        navigate={~p"/contracts?job_id=#{@current_job.job.job_id}"}
                        class="al-ghost"
                      >
                        Open contracts console
                      </.link>
                      <.link
                        :if={@current_job.job.subject_id}
                        navigate={~p"/subjects/#{@current_job.job.subject_id}"}
                        class="al-ghost"
                      >
                        Open subject revenue
                      </.link>
                    </div>
                  <% else %>
                    <div class="al-action-row">
                      <p>Stay on this page while launch orchestration runs.</p>
                      <.link
                        navigate={~p"/contracts?job_id=#{@current_job.job.job_id}"}
                        class="al-ghost"
                      >
                        Open contracts console
                      </.link>
                      <.link
                        :if={@current_job.job.subject_id}
                        navigate={~p"/subjects/#{@current_job.job.subject_id}"}
                        class="al-ghost"
                      >
                        Open subject revenue
                      </.link>
                    </div>
                  <% end %>
                </article>

                <article :if={@current_job.job.reputation_prompt} class="al-note-card">
                  <p class="al-kicker">Trust follow-up</p>
                  <p>{@current_job.job.reputation_prompt.warning}</p>
                  <button type="button" class="al-network-badge" phx-click="go_to_step" phx-value-step="4">
                    Open trust check
                  </button>
                </article>

                <article
                  :if={
                    @current_job.job.strategy_address || @current_job.job.vesting_wallet_address ||
                      @current_job.job.hook_address || @current_job.job.launch_fee_registry_address ||
                      @current_job.job.launch_fee_vault_address || @current_job.job.default_ingress_address ||
                      @current_job.job.subject_registry_address || @current_job.job.subject_id ||
                      @current_job.job.revenue_share_splitter_address || @current_job.job.pool_id
                  }
                  class="al-note-card"
                >
                  <p class="al-kicker">Launch stack</p>
                  <ul class="al-compact-list">
                    <li :if={@current_job.job.strategy_address}>
                      LBP strategy: <strong>{@current_job.job.strategy_address}</strong>
                    </li>
                    <li :if={@current_job.job.vesting_wallet_address}>
                      Vesting wallet: <strong>{@current_job.job.vesting_wallet_address}</strong>
                    </li>
                    <li :if={@current_job.job.hook_address}>
                      Fee hook: <strong>{@current_job.job.hook_address}</strong>
                    </li>
                    <li :if={@current_job.job.launch_fee_registry_address}>
                      Fee registry: <strong>{@current_job.job.launch_fee_registry_address}</strong>
                    </li>
                    <li :if={@current_job.job.launch_fee_vault_address}>
                      Fee vault: <strong>{@current_job.job.launch_fee_vault_address}</strong>
                    </li>
                    <li :if={@current_job.job.default_ingress_address}>
                      Default ingress: <strong>{@current_job.job.default_ingress_address}</strong>
                    </li>
                    <li :if={@current_job.job.subject_registry_address}>
                      Subject registry: <strong>{@current_job.job.subject_registry_address}</strong>
                    </li>
                    <li :if={@current_job.job.subject_id}>
                      Subject ID: <strong>{@current_job.job.subject_id}</strong>
                    </li>
                    <li :if={@current_job.job.revenue_share_splitter_address}>
                      Revenue share splitter: <strong>{@current_job.job.revenue_share_splitter_address}</strong>
                    </li>
                    <li :if={@current_job.job.pool_id}>
                      Pool ID: <strong>{@current_job.job.pool_id}</strong>
                    </li>
                  </ul>
                  <div class="al-action-row">
                    <.link
                      navigate={~p"/contracts?job_id=#{@current_job.job.job_id}"}
                      class="al-ghost"
                    >
                      Inspect full contract console
                    </.link>
                  </div>
                </article>
              </div>
            <% else %>
              <div class="al-note-card">
                <p class="al-inline-note">Waiting for launch job response.</p>
                <div class="al-action-row">
                  <.link
                    :if={@job_id}
                    navigate={~p"/contracts?job_id=#{@job_id}"}
                    class="al-ghost"
                  >
                    Open contracts console
                  </.link>
                </div>
              </div>
            <% end %>
          <% end %>
        </article>

        <aside class="al-panel al-side-panel">
          <div class="al-section-head">
            <div>
              <p class="al-kicker">Launch readiness</p>
              <h3>
                {if @selected_agent, do: @selected_agent.name, else: "Choose an agent to inspect blockers"}
              </h3>
            </div>
          </div>

          <%= if @readiness do %>
            <div class="al-stat-grid">
              <.stat_card
                title="Checks passing"
                value={"#{Enum.count(@readiness.checks, & &1.passed)}/#{length(@readiness.checks)}"}
              />
              <.stat_card
                title="Identity"
                value={@readiness.resolved_lifecycle_run_id || "pending"}
                hint="ERC-8004 launch key"
              />
            </div>

            <ul class="al-checklist">
              <li :for={check <- @readiness.checks} class={["al-check-item", check.passed && "is-passed"]}>
                <span>{if check.passed, do: "Passed", else: "Blocked"}</span>
                <div>
                  <strong>{check.key}</strong>
                  <p>{check.message}</p>
                </div>
              </li>
            </ul>
          <% else %>
            <p class="al-inline-note">
              The launch sidebar stays focused on one identity at a time so you always see the exact ERC-8004 blocker set.
            </p>
          <% end %>
        </aside>
      </section>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end

  defp assign_regent_scene(socket) do
    next_version = (socket.assigns[:regent_scene_version] || 0) + 1
    scene = RegentScenes.launch(socket.assigns)

    socket
    |> assign(:regent_scene_version, next_version)
    |> assign(:regent_scene, Map.put(scene, "sceneVersion", next_version))
    |> assign(:regent_selected_node_id, "launch:step:#{min(socket.assigns.step, 4)}")
  end

  defp launch_module do
    :autolaunch
    |> Application.get_env(:launch_live, [])
    |> Keyword.get(:launch_module, Launch)
  end

  defp reputation_action_cta(%{key: "ens", completed: true}), do: "Review ENS planner"
  defp reputation_action_cta(%{key: "ens"}), do: "Open ENS planner"
  defp reputation_action_cta(%{key: "world", completed: true}), do: "Review trust check"
  defp reputation_action_cta(%{key: "world"}), do: "Open trust check"
  defp reputation_action_cta(_action), do: "Open"

  defp launch_hero_command do
    """
    regent autolaunch prelaunch wizard \
      --agent 1:42 \
      --name "Atlas Coin" \
      --symbol ATLAS \
      --treasury-safe-address 0x1111111111111111111111111111111111111111 \
      --auction-proceeds-recipient 0x1111111111111111111111111111111111111111 \
      --ethereum-revenue-treasury 0x1111111111111111111111111111111111111111 \
      --image-file ./atlas.png
    """
    |> String.trim()
  end

  defp launch_hero_transcript do
    """
    > plan.saved = true
    > validation.launchable = true
    > next = regent autolaunch launch run --plan plan_alpha
    > after_launch = monitor -> finalize -> vesting status
    """
    |> String.trim()
  end
end
