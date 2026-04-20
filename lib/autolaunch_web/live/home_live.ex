defmodule AutolaunchWeb.HomeLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.Launch
  alias AutolaunchWeb.LaunchComponents
  alias AutolaunchWeb.Live.Refreshable

  @poll_ms 15_000

  @anchor_nav [
    %{label: "Markets", href: "#home-markets"},
    %{label: "How it works", href: "#home-how-it-works"},
    %{label: "About", href: "#home-about"}
  ]

  @agent_badges [
    %{label: "Hermes", mark: "HM", href: "/launch-via-agent"},
    %{label: "OpenClaw", mark: "OC", href: "/launch-via-agent"},
    %{label: "IronClaw", mark: "IC", href: "/launch"},
    %{label: "Codex", mark: "CX", href: "/launch"},
    %{label: "Claude", mark: "CL", href: "/launch"}
  ]

  @hero_panels [
    %{
      label: "Launch path",
      title: "Start from one reviewed plan",
      body:
        "Save the plan, check it, publish it, and run the launch from the same working thread."
    },
    %{
      label: "After the sale",
      title: "Keep follow-up work in reach",
      body:
        "Once the auction closes, people come back here for claims, staking, and revenue actions."
    }
  ]

  @story_bands [
    %{
      title: "Start with one launch path",
      body:
        "Autolaunch keeps the launch work in one reviewed path instead of scattering it across separate tools and pages."
    },
    %{
      title: "Bid with a budget and a price cap",
      body:
        "Each buyer chooses a total budget and the highest price they will pay, then the sale keeps clearing block by block."
    },
    %{
      title: "Come back after the auction",
      body:
        "The same product keeps the next steps close at hand when people need to claim, stake, or manage revenue."
    }
  ]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> Refreshable.schedule(@poll_ms)
     |> assign(:page_title, "Autolaunch")
     |> assign(:active_view, "home")
     |> assign(:anchor_nav, @anchor_nav)
     |> assign(:agent_badges, @agent_badges)
     |> assign(:hero_panels, @hero_panels)
     |> assign(:story_bands, @story_bands)
     |> assign_home_market()}
  end

  def handle_info(:refresh, socket) do
    {:noreply, Refreshable.refresh(socket, @poll_ms, &reload_home/1)}
  end

  def render(assigns) do
    ~H"""
    <div
      id="autolaunch-homepage"
      class="al-homepage-shell rg-app-shell rg-regent-theme-autolaunch"
      phx-hook="ShellChrome"
    >
      <div class="al-homepage-noise" aria-hidden="true"></div>
      <div class="al-homepage-beam al-homepage-beam--left" aria-hidden="true"></div>
      <div class="al-homepage-beam al-homepage-beam--right" aria-hidden="true"></div>

      <header class="al-homepage-header">
        <.link navigate={~p"/"} class="al-homepage-brand">
          <img src={~p"/images/autolaunch-logo-large.png"} alt="Autolaunch" width="48" height="48" />
          <div>
            <p>Autolaunch</p>
            <span>Agent markets</span>
          </div>
        </.link>

        <nav class="al-homepage-nav" aria-label="Homepage">
          <a :for={item <- @anchor_nav} href={item.href}>{item.label}</a>
        </nav>

        <.link navigate={~p"/auctions"} class="al-homepage-cta">Open auctions</.link>
      </header>

      <main class="al-homepage-main">
        <section id="home-hero" class="al-homepage-hero" phx-hook="HomeHeroMotion">
          <div class="al-homepage-hero-stage">
            <div class="al-homepage-hero-copy" data-home-hero-reveal>
              <p class="al-homepage-kicker">Operator-first launch path</p>
              <h1>Start the launch, follow the sale, and return for what comes next.</h1>
              <p class="al-homepage-subcopy">
                Use one reviewed plan to start an agent token sale. Then keep the live auction,
                claims, staking, and revenue follow-up in one calm working surface.
              </p>

              <div class="al-homepage-hero-actions">
                <.link navigate={~p"/auctions"} class="al-homepage-cta">Open auctions</.link>
                <.link navigate={~p"/launch"} class="al-homepage-about-secondary">
                  Open launch path
                </.link>
                <.link navigate={~p"/how-auctions-work"} class="al-homepage-text-link">
                  How auctions work
                </.link>
              </div>

              <div class="al-homepage-command-block" data-home-hero-reveal>
                <p class="al-homepage-command-label">Start here</p>
                <div class="al-homepage-command-bar">
                  <code>regent autolaunch prelaunch wizard</code>
                  <button
                    type="button"
                    class="al-homepage-command-copy"
                    data-copy-value={wizard_command()}
                  >
                    Copy
                  </button>
                </div>
              </div>

              <p class="al-homepage-install-copy" data-home-hero-reveal>
                Works with the operator surfaces below
              </p>

              <div
                class="al-homepage-badge-row"
                aria-label="Agent entry points"
                data-home-hero-reveal
              >
                <.link
                  :for={badge <- @agent_badges}
                  navigate={badge.href}
                  class="al-homepage-badge"
                >
                  <span class="al-homepage-badge-mark">{badge.mark}</span>
                  <span>{badge.label}</span>
                </.link>
              </div>
            </div>

            <div class="al-homepage-hero-side">
              <div class="al-homepage-visual" aria-hidden="true" data-home-hero-reveal>
                <div class="al-homepage-orbit"></div>
                <div class="al-homepage-orbit al-homepage-orbit--inner"></div>
                <div class="al-homepage-sigil-halo"></div>
                <img
                  class="al-homepage-sigil"
                  src={~p"/images/autolaunch-logo-large.png"}
                  alt=""
                  width="900"
                  height="900"
                />
              </div>

              <aside class="al-homepage-market-panel" data-home-hero-reveal>
                <div class="al-homepage-market-panel-head">
                  <p class="al-homepage-kicker">Live market</p>
                  <h2>Know where to go next.</h2>
                  <p>
                    Open the auction page when you want the live estimator and bid controls. Open
                    the token page when the sale is over and it is time to claim or stake.
                  </p>
                </div>

                <div class="al-homepage-stat-row" aria-label="Market counts">
                  <span>Biddable {@biddable_count}</span>
                  <span>Live {@live_count}</span>
                </div>

                <div class="al-homepage-hero-panel-grid">
                  <article :for={panel <- @hero_panels} class="al-homepage-hero-panel">
                    <p class="al-homepage-kicker">{panel.label}</p>
                    <h3>{panel.title}</h3>
                    <p>{panel.body}</p>
                  </article>
                </div>
              </aside>
            </div>
          </div>
        </section>

        <section id="home-markets" class="al-homepage-section" phx-hook="MissionMotion">
          <div class="al-homepage-section-head">
            <div>
              <p class="al-homepage-kicker">Markets</p>
              <h2>See what is live now and open the right page right away.</h2>
            </div>
          </div>

          <.market_table
            title="Open auctions"
            tokens={@active_tokens}
            empty_message="No auctions are open right now."
          />

          <.market_table
            title="Post-auction tokens"
            tokens={@past_tokens}
            empty_message="No past tokens are available yet."
          />
        </section>

        <section id="home-how-it-works" class="al-homepage-section" phx-hook="MissionMotion">
          <div class="al-homepage-section-head">
            <div>
              <p class="al-homepage-kicker">How it works</p>
              <h2>Three stages, without extra page hunting.</h2>
            </div>
          </div>

          <div class="al-homepage-story-grid">
            <article :for={band <- @story_bands} class="al-homepage-story-card">
              <h3>{band.title}</h3>
              <p>{band.body}</p>
            </article>
          </div>
        </section>

        <section id="home-about" class="al-homepage-section" phx-hook="MissionMotion">
          <div class="al-homepage-about-card">
            <p class="al-homepage-kicker">About</p>
            <h2>One launch path, one live market, and one return point after the sale.</h2>
            <p>
              Start the launch from one reviewed path. Use the market page to find active sales.
              Then come back to the token page for claims, staking, and revenue actions after the
              sale closes.
            </p>

            <div class="al-homepage-about-actions">
              <.link navigate={~p"/auctions"} class="al-homepage-about-primary">Open markets</.link>
              <.link navigate={~p"/launch-via-agent"} class="al-homepage-about-secondary">
                Use an agent
              </.link>
            </div>
          </div>
        </section>
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :tokens, :list, required: true
  attr :empty_message, :string, required: true

  defp market_table(assigns) do
    ~H"""
    <section class="al-homepage-table-card">
      <div class="al-homepage-table-head">
        <h3>{@title}</h3>
        <span>{length(@tokens)} shown</span>
      </div>

      <div class="al-homepage-table-wrap">
        <table class="al-homepage-table">
          <thead>
            <tr>
              <th scope="col">Token</th>
              <th scope="col">Symbol</th>
              <th scope="col">Current price</th>
              <th scope="col">Implied market cap</th>
              <th scope="col">Timing</th>
              <th scope="col">Trust</th>
              <th scope="col">Action</th>
            </tr>
          </thead>
          <tbody>
            <%= if @tokens == [] do %>
              <tr>
                <td colspan="7" class="al-homepage-table-empty">{@empty_message}</td>
              </tr>
            <% else %>
              <tr :for={token <- @tokens}>
                <td>
                  <div class="al-homepage-token-cell">
                    <strong>{token.agent_name}</strong>
                    <span>{token.agent_id}</span>
                  </div>
                </td>
                <td>{token.symbol}</td>
                <td>{display_value(token.current_price_usdc, "USDC")}</td>
                <td>{display_value(token.implied_market_cap_usdc, "USDC")}</td>
                <td>{market_timing_label(token)}</td>
                <td>{trust_summary(token.trust)}</td>
                <td>
                  <.link navigate={primary_action_href(token)} class="al-homepage-table-link">
                    {primary_action_label(token)}
                  </.link>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  defp reload_home(socket), do: assign_home_market(socket)

  defp assign_home_market(socket) do
    directory =
      launch_module().list_auctions(
        %{"mode" => "all", "sort" => "newest"},
        socket.assigns[:current_human]
      )

    socket
    |> assign(:directory, directory)
    |> assign(:active_tokens, Enum.filter(directory, &(&1.phase == "biddable")))
    |> assign(:past_tokens, Enum.filter(directory, &(&1.phase == "live")))
    |> assign(:biddable_count, Enum.count(directory, &(&1.phase == "biddable")))
    |> assign(:live_count, Enum.count(directory, &(&1.phase == "live")))
  end

  defp wizard_command, do: "regent autolaunch prelaunch wizard"

  defp display_value(nil, unit), do: "Unavailable #{unit}"
  defp display_value(value, unit), do: "#{value} #{unit}"

  defp market_timing_label(%{phase: "biddable", ends_at: ends_at}),
    do: LaunchComponents.time_left_label(ends_at)

  defp market_timing_label(%{phase: "live"}), do: "Auction closed"
  defp market_timing_label(_token), do: "Check token page"

  defp primary_action_href(%{phase: "live", subject_url: subject_url, detail_url: _detail_url})
       when is_binary(subject_url),
       do: subject_url

  defp primary_action_href(%{detail_url: detail_url}), do: detail_url

  defp primary_action_label(%{phase: "biddable"}), do: "Open bid view"

  defp primary_action_label(%{phase: "live", subject_url: subject_url})
       when is_binary(subject_url), do: "Open token page"

  defp primary_action_label(%{phase: "live"}), do: "Inspect launch"
  defp primary_action_label(_token), do: "Open"

  defp trust_summary(%{ens: %{connected: true, name: name}, world: %{connected: true}})
       when is_binary(name),
       do: "#{name} • World connected"

  defp trust_summary(%{ens: %{connected: true, name: name}}) when is_binary(name), do: name
  defp trust_summary(%{world: %{connected: true, launch_count: count}}), do: "World #{count}"
  defp trust_summary(_), do: "Optional links"

  defp launch_module do
    :autolaunch
    |> Application.get_env(:home_live, [])
    |> Keyword.get(:launch_module, Launch)
  end
end
