defmodule AutolaunchWeb.AuctionGuideLive do
  use AutolaunchWeb, :live_view

  @timeline_steps [
    %{
      order: 0,
      index: "01",
      eyebrow: "What is being sold",
      title: "Each auction sells 10% of an agent's revenue token supply.",
      body:
        "The token launch supply is fixed at 100 billion units. The agent keeps the other 90% from the start, so the auction only sets the price for the public 10% slice.",
      note: "The sale is a discovery mechanism, not the whole token supply.",
      stat: "10% sold, 100B total"
    },
    %{
      order: 1,
      index: "02",
      eyebrow: "Where the money lives",
      title: "All auctions are denominated in USDC on Ethereum Sepolia.",
      body:
        "Bids do not hop across networks. Every auction uses USDC on Ethereum Sepolia, which keeps the settlement path predictable and the user-facing price math simple.",
      note: "No network chooser, no conversion detours.",
      stat: "USDC only"
    },
    %{
      order: 2,
      index: "03",
      eyebrow: "How you enter",
      title: "You set a total budget and a max price.",
      body:
        "The amount is split across the remaining auction blocks instead of landing all at once. That gives you a limit-order style position that can stay active over time without manual babysitting.",
      note: "The same bid can participate in many blocks.",
      stat: "Budget + ceiling"
    },
    %{
      order: 3,
      index: "04",
      eyebrow: "How the market clears",
      title: "Clearing prices rise as the auction progresses.",
      body:
        "If your max price stays above the live clearing price, you remain in range. If the price moves above your ceiling, the remaining portion is no longer active and the page should show that clearly.",
      note: "Early blocks are usually cheaper than later blocks.",
      stat: "In range / out of range"
    },
    %{
      order: 4,
      index: "05",
      eyebrow: "What happens at the end",
      title: "When the auction ends, you claim the filled tokens and refunds.",
      body:
        "The user should be able to see what filled, what was returned, and what still needs to be claimed. The point is to make the outcome obvious, not to hide the accounting behind the contract.",
      note: "Claiming is the finish line for the sale itself.",
      stat: "Claim allocation"
    },
    %{
      order: 5,
      index: "06",
      eyebrow: "What makes the token earn",
      title: "The acquired tokens must be staked to earn revenue.",
      body:
        "Buying the token is not enough. To earn revenue, the tokens have to be staked, and revenue only counts after Sepolia USDC reaches the revenue share splitter and is finalized from onchain state.",
      note:
        "Stake turns ownership into a revenue claim once recognized USDC reaches the revenue share splitter.",
      stat: "Stake required"
    }
  ]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "How auctions work")
     |> assign(:active_view, "guide")
     |> assign(:timeline_steps, @timeline_steps)}
  end

  def render(assigns) do
    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <div id="auction-guide-page" phx-hook="AuctionGuideMotion">
        <section id="auction-guide-hero" class="al-panel al-guide-hero">
          <div class="al-guide-hero-copy">
            <p class="al-kicker">Auction guide</p>
            <h2>How autolaunch auctions work.</h2>
            <p class="al-subcopy">
              The auction sets the price for the public 10% of an agent's revenue token supply.
              Bidders pay in USDC on Ethereum Sepolia, then stake the tokens they win if they want
              to earn after recognized Sepolia USDC reaches the revenue share splitter.
            </p>

            <div class="al-hero-actions">
              <.link navigate={~p"/auctions"} class="al-submit">Open live auctions</.link>
              <.link navigate={~p"/launch"} class="al-ghost">Launch an agent</.link>
            </div>

            <div class="al-launch-tags" aria-label="Auction facts">
              <span class="al-launch-tag">10% sold at launch</span>
              <span class="al-launch-tag">USDC on Ethereum Sepolia</span>
              <span class="al-launch-tag">Stake required for revenue</span>
            </div>
          </div>

          <aside class="al-guide-summary">
            <div class="al-section-head">
              <div>
                <p class="al-kicker">At a glance</p>
                <h3>Three things to remember</h3>
              </div>
            </div>

            <div class="al-guide-summary-grid">
              <.stat_card title="Sale size" value="10%" hint="The agent keeps the other 90%." />
              <.stat_card title="Supply" value="100B" hint="AgentLaunchToken supply is fixed." />
              <.stat_card title="Currency" value="USDC" hint="All auctions settle on Ethereum Sepolia." />
              <.stat_card title="Revenue" value="Stake first" hint="Tokens must be staked after recognized Sepolia USDC reaches the revenue share splitter." />
              <.stat_card
                title="Fee share"
                value="Included"
                hint="Staked tokens also receive the token fee revenue share."
              />
            </div>

            <div class="al-inline-banner al-guide-banner">
              <strong>Plain version.</strong>
              <p>
                Buy the public 10%, claim what you win, then stake it if you want recognized
                Sepolia USDC revenue to start accruing.
              </p>
            </div>
          </aside>
        </section>

        <section class="al-guide-layout">
          <aside class="al-panel al-guide-rail">
            <div class="al-section-head">
              <div>
                <p class="al-kicker">Timeline</p>
                <h3>The auction in order</h3>
              </div>
            </div>

            <div class="al-guide-rail-copy">
              <p>
                Follow the sale from price discovery to claiming and staking. Each step mirrors the
                live auction flow instead of hiding it behind jargon.
              </p>

              <div class="al-guide-rail-progress" aria-hidden="true">
                <span class="al-guide-rail-track">
                  <span class="al-guide-rail-fill" data-guide-progress-fill></span>
                </span>
              </div>

              <ul class="al-guide-rail-list">
                <li :for={step <- @timeline_steps}>
                  <span>{step.index}</span>
                  <div>
                    <strong>{step.eyebrow}</strong>
                    <p>{step.stat}</p>
                  </div>
                </li>
              </ul>
            </div>
          </aside>

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
        </section>

        <section class="al-panel al-guide-finish">
          <div class="al-section-head">
            <div>
              <p class="al-kicker">After the sale</p>
              <h3>Claim first, stake second, earn third.</h3>
            </div>
          </div>

          <div class="al-guide-outcomes">
            <article class="al-guide-outcome">
              <span>1</span>
              <strong>Claim the tokens you won.</strong>
              <p>The auction ends with a concrete allocation and any applicable refund.</p>
            </article>

            <article class="al-guide-outcome">
              <span>2</span>
              <strong>Stake the tokens to become revenue-eligible.</strong>
              <p>Staking is what turns ownership into a share of the agent's revenue stream.</p>
            </article>

            <article class="al-guide-outcome">
              <span>3</span>
              <strong>Collect revenue, including token fee share.</strong>
              <p>The staked position participates in the agent's income and the token fee split.</p>
            </article>
          </div>
        </section>
      </div>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end
end
