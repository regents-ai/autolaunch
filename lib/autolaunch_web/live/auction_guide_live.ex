defmodule AutolaunchWeb.AuctionGuideLive do
  use AutolaunchWeb, :live_view

  alias AutolaunchWeb.RegentScenes

  @route_css_path Path.expand("../../../priv/static/launch-docs-live.css", __DIR__)
  @external_resource @route_css_path
  @route_css File.read!(@route_css_path)

  @timeline_steps [
    %{
      order: 0,
      index: "01",
      eyebrow: "Why this model exists",
      title:
        "The auction is built for quality teams to bootstrap liquidity with real price discovery.",
      body:
        "We put a lot of thought into an auction model that avoids launch-day timing games and gives buyers one clear way to express conviction. The goal is healthier market behavior, not a race to exploit mechanics.",
      note: "The design is about fair access and honest bidding, not speed tricks.",
      stat: "Healthy market behavior"
    },
    %{
      order: 1,
      index: "02",
      eyebrow: "What is being sold",
      title: "Each auction sells 10% of a fixed 100 billion token supply.",
      body:
        "The agent keeps the other 90% from the start, so the auction is only discovering the market price for the public 10% slice. Every bid is still placed in USDC on Base Sepolia or Base mainnet.",
      note:
        "The sale discovers the public launch price, not the value of the whole supply at once.",
      stat: "10% sold, 100B total"
    },
    %{
      order: 2,
      index: "03",
      eyebrow: "How you enter",
      title: "You set a total budget and a max price.",
      body:
        "That is the whole mental model for a buyer. You say how much you want to spend in total and the highest price you are willing to pay for a token, then the system handles the block-by-block execution.",
      note: "One bid expresses both your size and your discipline.",
      stat: "Budget + ceiling"
    },
    %{
      order: 3,
      index: "04",
      eyebrow: "How your order runs",
      title: "Your order is spread across the remaining blocks like a TWAP.",
      body:
        "Instead of landing all at once, your budget is distributed over the remaining auction duration. Bidding earlier means you participate in more blocks, while waiting shortens your TWAP and usually worsens your average entry.",
      note: "The model rewards showing up honestly early, not trying to time one perfect block.",
      stat: "TWAP across blocks"
    },
    %{
      order: 4,
      index: "05",
      eyebrow: "How the market clears",
      title:
        "The auction starts at a floor price and clears higher only when demand requires it.",
      body:
        "Each block clears at the highest price where that block's demand exceeds that block's supply. Everyone who clears the same block gets the same clearing price, and nobody pays their own max price if the market clears lower.",
      note: "The clearing price moves with real demand instead of rewarding sniping.",
      stat: "Floor to clearing"
    },
    %{
      order: 5,
      index: "06",
      eyebrow: "What the game theory says",
      title: "Bid early with your real budget and your real max price.",
      body:
        "Each block where the clearing price stays below your max price buys tokens for a slice of your budget. Once the clearing price moves above your cap, the remaining portion of your TWAP stops instead of forcing you to overpay.",
      note:
        "Your max price protects you, and waiting only gives you fewer blocks at usually worse prices.",
      stat: "Honest early bidding"
    },
    %{
      order: 6,
      index: "07",
      eyebrow: "What happens after",
      title:
        "When the auction ends, you claim the filled tokens, then stake if you want revenue exposure.",
      body:
        "The page should make the outcome obvious: what filled, what was refunded, and what still needs to be claimed. After claim, tokens must be staked before they participate in recognized USDC revenue on Base, and that revenue only counts once it reaches the subject splitter.",
      note: "The sale ends at claim. Earning starts only after staking.",
      stat: "Claim, then stake"
    }
  ]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "How auctions work")
     |> assign(:active_view, "guide")
     |> assign(:timeline_steps, @timeline_steps)
     |> assign(:selected_step_index, 0)
     |> assign_regent_scene()}
  end

  def handle_event("regent:node_select", %{"meta" => %{"stepIndex" => step_index}}, socket) do
    {:noreply,
     socket
     |> assign(:selected_step_index, normalize_step_index(step_index))
     |> assign_regent_scene()}
  end

  def handle_event("regent:node_select", _params, socket), do: {:noreply, socket}

  def handle_event("scene-back", _params, socket) do
    {:noreply, socket |> assign(:selected_step_index, 0) |> assign_regent_scene()}
  end

  def handle_event("regent:node_hover", _params, socket), do: {:noreply, socket}
  def handle_event("regent:surface_ready", _params, socket), do: {:noreply, socket}

  def handle_event("regent:surface_error", _params, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "The autolaunch guide surface could not render in this browser session."
     )}
  end

  def render(assigns) do
    selected_step =
      Enum.find(assigns.timeline_steps, &(&1.order == assigns.selected_step_index)) ||
        List.first(assigns.timeline_steps)

    assigns = assign(assigns, :selected_step, selected_step)

    ~H"""
    <style><%= Phoenix.HTML.raw(route_css()) %></style>
    <.shell current_human={@current_human} active_view={@active_view}>
      <div id="al-docs-page" data-docs-page="guide">
        <AutolaunchWeb.DocsFamilyComponents.header
          active="guide"
          title="Everything you need to understand and operate on Autolaunch."
          body="Guides, contract references, and legal pages stay close so operators can move from reading to action without guessing."
        />

        <section class="al-regent-shell al-docs-surface-shell">
          <.surface
            id="auction-guide-surface"
            class="rg-regent-theme-autolaunch al-terrain-surface"
            scene={@regent_scene}
            scene_version={@regent_scene_version}
            selected_target_id={@regent_selected_target_id}
            theme="autolaunch"
            camera_distance={24}
          >
            <:header_strip>
              <div class="al-terrain-strip">
                <div class="al-terrain-strip-copy">
                  <p class="al-kicker">Guide strip</p>
                  <div>
                    <h2>Understand the sale before touching the controls.</h2>
                    <p class="al-subcopy">
                      The symbolic path stays short on purpose. The plain-English guide below explains
                      why the auction exists, how it clears, and what honest bidding looks like.
                    </p>
                  </div>
                </div>

                <div class="al-terrain-strip-controls">
                  <button
                    :if={@selected_step_index > 0}
                    type="button"
                    phx-click="scene-back"
                    class="rg-surface-back"
                  >
                    <span class="rg-surface-back-icon" aria-hidden="true">←</span>
                    Back to overview
                  </button>
                  <span class="al-network-badge">Steps {length(@timeline_steps)}</span>
                  <span class="al-network-badge">Current {@selected_step_index + 1}</span>
                  <.link navigate={~p"/auctions"} class="al-ghost">Open auctions</.link>
                </div>
              </div>
            </:header_strip>

            <:chamber>
              <.chamber
                id="auction-guide-chamber"
                title={@selected_step.title}
                subtitle={@selected_step.eyebrow}
                summary={@selected_step.body}
              >
                <div class="al-launch-tags" aria-label="Selected guide step">
                  <span class="al-launch-tag">{@selected_step.stat}</span>
                  <span class="al-launch-tag">{@selected_step.note}</span>
                </div>
              </.chamber>
            </:chamber>

            <:ledger>
              <.ledger
                id="auction-guide-ledger"
                title="Operator summary"
                subtitle="Keep the sale model close while you decide whether to bid or launch."
              >
                <table class="rg-table">
                  <tbody>
                    <tr>
                      <th scope="row">Sale size</th>
                      <td>10% public sale</td>
                    </tr>
                    <tr>
                      <th scope="row">Currency</th>
                      <td>USDC on Base Sepolia or Base mainnet</td>
                    </tr>
                    <tr>
                      <th scope="row">Revenue</th>
                      <td>Stake after claim to earn</td>
                    </tr>
                  </tbody>
                </table>
              </.ledger>
            </:ledger>
          </.surface>
        </section>

        <div id="auction-guide-page">
        <section id="auction-guide-hero" class="al-panel al-guide-hero">
          <div class="al-guide-hero-copy">
            <p class="al-kicker">Guide</p>
            <h2>Pick the job you came here for, then leave this page quickly.</h2>
            <p class="al-subcopy">
              This page should orient you quickly. If you want to back an agent, open the active
              auctions. If you want to launch one, start in the CLI and use the site for review,
              bidding, and token-holder actions after the sale is live.
            </p>

            <div class="al-choice-grid">
              <article class="al-choice-card" data-guide-choice>
                <p class="al-kicker">Bid path</p>
                <h3>Back an active auction with USDC.</h3>
                <p>
                  Open the live bid view, choose your budget and max price, and update later only if
                  the market moves out of range.
                </p>

                <div class="al-launch-tags" aria-label="Bid path facts">
                  <span class="al-launch-tag">3-day sale window</span>
                  <span class="al-launch-tag">USDC on Base</span>
                  <span class="al-launch-tag">Stake after claim to earn revenue</span>
                </div>

                <p class="al-inline-note">
                  Recommended first move: start with your real budget at the current displayed price.
                </p>

                <div class="al-choice-actions">
                  <.link navigate={~p"/auctions"} class="al-submit">Open active auctions</.link>
                  <.link navigate={~p"/auction-returns"} class="al-ghost">Auction returns</.link>
                </div>
              </article>

              <article class="al-choice-card" data-guide-choice>
                <p class="al-kicker">Launch path</p>
                <h3>Launch through the CLI, then return here for the live market.</h3>
                <p>
                  Save the plan, validate it, publish it, run the launch, monitor the auction, then
                  finalize from the same CLI path.
                </p>

                <pre class="al-choice-command"><code>regent autolaunch prelaunch wizard</code></pre>

                <div class="al-choice-actions">
                  <button
                    type="button"
                    class="al-submit"
                    data-copy-value="regent autolaunch prelaunch wizard"
                  >
                    Copy CLI command
                  </button>
                  <.link navigate={~p"/launch-via-agent"} class="al-ghost">How to use agents</.link>
                </div>
              </article>
            </div>
          </div>

          <aside class="al-guide-summary">
            <div class="al-section-head">
              <div>
                <p class="al-kicker">Quick mental model</p>
                <h3>What matters before you click</h3>
              </div>
            </div>

            <div class="al-note-grid">
              <article class="al-note-card">
                <span>How to bid</span>
                <strong>Budget plus max price</strong>
                <p>Your bid keeps buying only while the market stays below your cap.</p>
              </article>
              <article class="al-note-card">
                <span>How it settles</span>
                <strong>Claim first, stake after</strong>
                <p>Revenue exposure starts only after claimed tokens are staked.</p>
              </article>
              <article class="al-note-card">
                <span>Why it feels fair</span>
                <strong>Same block, same price</strong>
                <p>The auction is built to reduce timing edge and reward honest early bidding.</p>
              </article>
            </div>

            <div class="al-inline-banner al-guide-banner">
              <strong>Simple bidding rule.</strong>
              <p>
                If you are new to this, think in two numbers only: how much USDC you want to spend
                and the highest token price you are willing to accept.
              </p>
            </div>
          </aside>
        </section>

        <section class="al-guide-disclosures">
          <details class="al-panel al-disclosure">
            <summary class="al-disclosure-summary">
              <div>
                <p class="al-kicker">Auction walkthrough</p>
                <h3>The sale in plain English</h3>
              </div>
              <span class="al-network-badge">7 steps</span>
            </summary>

            <div class="al-guide-steps">
              <article
                :for={step <- @timeline_steps}
                class="al-panel al-guide-step"
                data-guide-step
                data-guide-index={step.order}
              >
                <div class="al-guide-step-index">{step.index}</div>

                <div class="al-guide-step-copy">
                  <p class="al-kicker">{step.eyebrow}</p>
                  <h3>{step.title}</h3>
                  <p class="al-guide-step-body">{step.body}</p>
                </div>

                <div class="al-guide-step-callout">
                  <span>Why it matters</span>
                  <strong>{step.note}</strong>
                </div>
              </article>
            </div>
          </details>

          <details class="al-panel al-disclosure">
            <summary class="al-disclosure-summary">
              <div>
                <p class="al-kicker">Current launch economics</p>
                <h3>The live token split</h3>
              </div>
              <span class="al-network-badge">Today</span>
            </summary>

            <div class="al-guide-summary-grid al-guide-facts-grid">
              <.stat_card title="Auction sale" value="10%" hint="10 billion of the 100 billion token supply are sold in the auction." />
              <.stat_card title="LP reserve" value="5%" hint="5 billion tokens are held back for the Uniswap v4 pool." />
              <.stat_card title="USDC to LP" value="50%" hint="Half of the auction USDC pairs with the 5 billion LP tokens." />
              <.stat_card title="USDC to agent Safe" value="50%" hint="The other half is swept to the agent Safe for business operations." />
              <.stat_card title="Vesting" value="85%" hint="The remaining 85 billion tokens vest to the agent treasury over 1 year." />
              <.stat_card title="Auction style" value="Simple + fair" hint="Budget plus max price, same block price for everyone, less timing edge." />
            </div>
          </details>
        </section>

        <section class="al-panel al-guide-finish">
          <div class="al-section-head">
            <div>
              <p class="al-kicker">Why it is built this way</p>
              <h3>Less timing game, more honest price discovery.</h3>
            </div>
          </div>

          <div class="al-guide-outcomes">
            <article class="al-guide-outcome">
              <span>1</span>
              <strong>Everyone gets the same block price.</strong>
              <p>There is less room for sniping, bundling, or sandwiching your way into a better fill.</p>
            </article>

            <article class="al-guide-outcome">
              <span>2</span>
              <strong>Advanced users do not get a special timing edge.</strong>
              <p>With sane auction parameters, buyers are competing on price conviction, not on who can play block games better.</p>
            </article>

            <article class="al-guide-outcome">
              <span>3</span>
              <strong>Claim first, stake second, earn third.</strong>
              <p>Settlement stays simple: claim the result, then stake if you want ongoing revenue exposure.</p>
            </article>
          </div>
        </section>

        </div>
      </div>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end

  defp assign_regent_scene(socket) do
    next_version = (socket.assigns[:regent_scene_version] || 0) + 1
    scene = RegentScenes.guide(socket.assigns.timeline_steps, socket.assigns.selected_step_index)

    socket
    |> assign(:regent_scene_version, next_version)
    |> assign(:regent_scene, Map.put(scene, "sceneVersion", next_version))
    |> assign(:regent_selected_target_id, "guide:step:#{socket.assigns.selected_step_index}")
  end

  defp normalize_step_index(value) when is_integer(value), do: value

  defp normalize_step_index(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> 0
    end
  end

  defp normalize_step_index(_value), do: 0

  defp route_css, do: @route_css
end
