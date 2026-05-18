defmodule AutolaunchWeb.HomeLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.Launch
  alias Autolaunch.PublicChat
  alias AutolaunchWeb.LaunchComponents
  alias AutolaunchWeb.Live.Refreshable
  alias Decimal, as: D
  alias Xmtp.RoomPanel
  import AutolaunchWeb.PublicChatComponents

  @home_live_css_path Path.expand("../../../priv/static/home-live.css", __DIR__)
  @external_resource @home_live_css_path
  @home_live_css File.read!(@home_live_css_path)

  @poll_ms 15_000

  @launch_steps [
    %{
      index: "1",
      title: "Plan",
      body: "Define your agent, economics, and launch parameters."
    },
    %{
      index: "2",
      title: "Deploy",
      body: "Deploy the launch setup and configure the market on Base."
    },
    %{
      index: "3",
      title: "Fund and activate",
      body: "Fund the strategy and open the auction."
    },
    %{
      index: "4",
      title: "Launch and grow",
      body: "Distribute tokens and move into claims, staking, and revenue."
    }
  ]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> Refreshable.schedule(@poll_ms)
     |> Refreshable.subscribe([:market, :system])
     |> assign(:page_title, "Autolaunch")
     |> assign(:active_view, "home")
     |> assign(:launch_steps, @launch_steps)
     |> reset_public_chat_form()
     |> assign_public_chat()
     |> subscribe_public_chat()
     |> assign_home_market()}
  end

  def handle_info(:refresh, socket) do
    {:noreply, Refreshable.refresh(socket, @poll_ms, &reload_home/1)}
  end

  def handle_info({:autolaunch_live_update, :changed}, socket) do
    {:noreply, reload_home(socket)}
  end

  def handle_info({:public_site_event, %{event: event}}, socket)
      when event in [:xmtp_room_message, :xmtp_room_membership] do
    {:noreply, assign_public_chat(socket)}
  end

  def handle_event("public_chat_join", _params, socket) do
    case PublicChat.request_join(socket.assigns.current_human) do
      {:ok, panel} ->
        {:noreply, assign_public_chat_panel(socket, panel)}

      {:error, reason} ->
        {:noreply, put_public_chat_status(socket, PublicChat.reason_message(reason))}
    end
  end

  def handle_event("public_chat_send", %{"public_chat" => %{"body" => body}}, socket) do
    case PublicChat.send_message(socket.assigns.current_human, body) do
      {:ok, panel} ->
        {:noreply,
         socket
         |> assign_public_chat_panel(panel)
         |> reset_public_chat_form()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_public_chat_status(PublicChat.reason_message(reason))
         |> assign_public_chat_form(body)}
    end
  end

  def handle_event("public_chat_heartbeat", _params, socket) do
    :ok = PublicChat.heartbeat(socket.assigns.current_human)
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <style><%= Phoenix.HTML.raw(home_live_css()) %></style>
    <.shell current_human={@current_human} active_view={@active_view}>
      <div id="autolaunch-home-dashboard">
        <div class="al-home-dashboard-layout">
          <main class="al-home-main-column">
            <section
              id="home-dashboard-hero"
              class="al-panel al-home-dashboard-hero"
              phx-hook="HomeHeroMotion"
            >
              <div class="al-home-dashboard-copy">
                <p class="al-kicker">Home</p>
                <h1>Launch and grow agent economies</h1>
                <p class="al-subcopy">
                  Autolaunch helps operators launch, fund, and grow agent economies on Base with one
                  reviewed path from setup to live market.
                </p>

                <div class="al-home-dashboard-actions">
                  <.link navigate={~p"/launch"} class="al-submit">Go to Launch</.link>
                  <.link navigate={~p"/auctions"} class="al-ghost">Explore auctions</.link>
                </div>
              </div>

            </section>

            <article
              id="home-dashboard-metrics"
              class="al-panel al-home-metric-strip"
              phx-hook="MissionMotion"
            >
              <div :for={item <- @metric_items} class="al-home-metric-item">
                <span>{item.label}</span>
                <strong>{item.value}</strong>
                <p>{item.note}</p>
              </div>
            </article>

            <section id="home-dashboard-grid" class="al-home-dashboard-grid" phx-hook="MissionMotion">
              <article class="al-panel al-home-dashboard-card">
                <div class="al-home-card-head">
                  <h3>Market snapshot</h3>
                  <.link navigate={~p"/auctions"} aria-label="Open market snapshot">›</.link>
                </div>

                <div class="al-home-market-primary">
                  <div>
                    <span>Market cap</span>
                    <strong>{@tracked_market_cap}</strong>
                  </div>
                  <p>{market_snapshot_copy(@spotlight_token)}</p>
                </div>

                <div class="al-home-market-mini-grid">
                  <article :for={item <- @snapshot_items}>
                    <span>{item.label}</span>
                    <strong>{item.value}</strong>
                  </article>
                </div>
              </article>

              <article class="al-panel al-home-dashboard-card">
                <div class="al-home-card-head">
                  <h3>Featured auctions</h3>
                  <.link navigate={~p"/auctions"}>View all →</.link>
                </div>

                <div class="al-home-auction-list">
                  <%= if @featured_tokens == [] do %>
                    <div class="al-home-card-empty">
                      <strong>No live auctions yet</strong>
                      <p>New markets will appear here as soon as launches open.</p>
                    </div>
                  <% else %>
                    <article :for={token <- @featured_tokens} class="al-home-auction-row">
                      <div class="al-home-auction-avatar" aria-hidden="true">
                        {String.first(token.symbol || token.agent_name || "?")}
                      </div>
                      <div class="al-home-auction-copy">
                        <strong>{token.agent_name}</strong>
                        <p>${token.symbol}</p>
                      </div>
                      <div class="al-home-auction-meta">
                        <strong>{AutolaunchWeb.Format.format_currency(token.implied_market_cap_quote, 0)}</strong>
                        <span class={["al-home-status-pill", featured_status_class(token)]}>
                          {featured_status_label(token)}
                        </span>
                      </div>
                    </article>
                  <% end %>
                </div>

                <div class="al-home-card-footer">
                  <.link navigate={~p"/auctions"}>Browse all auctions →</.link>
                </div>
              </article>

              <article class="al-panel al-home-dashboard-card">
                <div class="al-home-card-head">
                  <h3>Launch path</h3>
                </div>

                <div class="al-home-launch-steps">
                  <article :for={step <- @launch_steps} class="al-home-launch-step">
                    <span>{step.index}</span>
                    <div>
                      <strong>{step.title}</strong>
                      <p>{step.body}</p>
                    </div>
                  </article>
                </div>

                <div class="al-home-card-footer">
                  <.link navigate={~p"/docs"}>View full guide →</.link>
                </div>
              </article>

              <article id="home-litepaper-card" class="al-panel al-home-dashboard-card">
                <div class="al-home-card-head">
                  <h3>Read Litepaper</h3>
                </div>

                <div class="al-home-card-empty">
                  <strong>Autolaunch paper</strong>
                  <p>Read the launch and market paper as a PDF or markdown.</p>
                </div>

                <div class="al-home-dashboard-actions">
                  <.link href={~p"/litepaper"} class="al-submit">PDF</.link>
                  <.link href={~p"/litepaper.md"} class="al-ghost">Markdown</.link>
                </div>
              </article>
            </section>
          </main>

          <aside id="home-action-rail" class="al-home-action-rail" phx-hook="MissionMotion">
            <article class="al-panel al-home-launch-panel">
              <div class="al-home-rail-head">
                <h2>autolaunch your agent ownership token</h2>
                <.link navigate={~p"/docs"}>How it works</.link>
              </div>

              <.link navigate={~p"/launch"} class="al-submit al-home-review-action">
                Review launch
              </.link>
            </article>

            <article class="al-panel al-home-quick-actions">
              <p class="al-kicker">Quick actions</p>
              <.link :for={action <- @quick_actions} navigate={action.href} class="al-home-quick-action">
                <span class="al-home-quick-mark" aria-hidden="true">{action.mark}</span>
                <span>
                  <strong>{action.title}</strong>
                  <small>{action.note}</small>
                </span>
                <span aria-hidden="true">›</span>
              </.link>
            </article>
          </aside>
        </div>

        <section id="home-chat-dock" class="al-home-chat-dock" phx-hook="MissionMotion">
          <.public_chat_panel room={@public_chat} form={@public_chat_form} />
        </section>
      </div>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end

  defp reload_home(socket), do: assign_home_market(socket)

  defp subscribe_public_chat(socket) do
    if Phoenix.LiveView.connected?(socket), do: :ok = PublicChat.subscribe()
    socket
  end

  defp assign_public_chat(socket) do
    assign(socket, :public_chat, PublicChat.room_panel(socket.assigns[:current_human]))
  end

  defp assign_public_chat_panel(socket, panel) do
    assign(socket, :public_chat, panel)
  end

  defp put_public_chat_status(socket, message) do
    assign(socket, :public_chat, put_public_chat_copy(socket.assigns.public_chat, message))
  end

  defp put_public_chat_copy(%RoomPanel{} = panel, message) when is_binary(message),
    do: %{panel | user_copy: RoomPanel.copy(message)}

  defp put_public_chat_copy(panel, _message), do: panel

  defp reset_public_chat_form(socket), do: assign_public_chat_form(socket, "")

  defp assign_public_chat_form(socket, body) do
    assign(socket, :public_chat_form, to_form(%{"body" => body}, as: :public_chat))
  end

  defp assign_home_market(socket) do
    directory =
      launch_module().list_auctions(
        %{"mode" => "all", "sort" => "newest"},
        socket.assigns[:current_human]
      )

    biddable_count = Enum.count(directory, &(&1.phase == "biddable"))
    live_count = Enum.count(directory, &(&1.phase == "live"))
    featured_tokens = featured_tokens(directory)
    listed_agents = directory |> Enum.uniq_by(& &1.agent_id) |> Enum.count()
    tracked_market_cap = tracked_market_cap(directory)
    spotlight_token = spotlight_token(directory)

    socket
    |> assign(:directory, directory)
    |> assign(:featured_tokens, featured_tokens)
    |> assign(:biddable_count, biddable_count)
    |> assign(:live_count, live_count)
    |> assign(:listed_agents, listed_agents)
    |> assign(:tracked_market_cap, tracked_market_cap)
    |> assign(:spotlight_token, spotlight_token)
    |> assign(:snapshot_items, snapshot_items(biddable_count, live_count, listed_agents))
    |> assign(:revenue_lane_count, 0)
    |> assign(:trust_score, trust_score(directory))
    |> assign(:quick_actions, quick_actions())
    |> assign(
      :metric_items,
      metric_items(tracked_market_cap, biddable_count, live_count, listed_agents)
    )
  end

  defp featured_tokens(directory) do
    directory
    |> Enum.sort_by(&featured_rank/1)
    |> Enum.take(4)
  end

  defp featured_rank(%{phase: "biddable"}), do: 0
  defp featured_rank(%{phase: "live"}), do: 1
  defp featured_rank(_token), do: 2

  defp snapshot_items(biddable_count, live_count, listed_agents) do
    [
      %{label: "Open auctions", value: biddable_count},
      %{label: "Tokens live", value: live_count},
      %{label: "Listed agents", value: listed_agents}
    ]
  end

  defp metric_items(tracked_market_cap, biddable_count, live_count, listed_agents) do
    [
      %{label: "Tracked markets", value: listed_agents, note: "Agent economies"},
      %{label: "Open auctions", value: biddable_count, note: "Ready for bids"},
      %{label: "Tokens live", value: live_count, note: "After auction close"},
      %{label: "Volume (24h)", value: "0 USDC", note: "USDC on Base"},
      %{label: "Market cap", value: tracked_market_cap, note: "Across listed markets"}
    ]
  end

  defp quick_actions do
    [
      %{
        mark: "⌁",
        title: "Explore auctions",
        note: "Browse live and upcoming auctions",
        href: "/auctions"
      },
      %{mark: "↗", title: "Create launch", note: "Start a new agent launch", href: "/launch"},
      %{mark: "◎", title: "Verify trust", note: "Review launch trust status", href: "/agentbook"},
      %{mark: "$", title: "View staking", note: "Manage $REGENT staking", href: "/regent-staking"}
    ]
  end

  defp trust_score([]), do: "98.7%"

  defp trust_score(directory) do
    verified = Enum.count(directory, &verified_launch?/1)
    score = 92 + min(6.7, verified * 1.7)
    "#{:erlang.float_to_binary(score, decimals: 1)}%"
  end

  defp verified_launch?(%{trust: %{ens: %{connected: true}, world: %{connected: true}}}), do: true
  defp verified_launch?(_token), do: false

  defp market_snapshot_copy(nil),
    do: "Open auctions to watch the next market as soon as it appears."

  defp market_snapshot_copy(token) do
    "#{token.agent_name} is the clearest next stop if you want to open the market and act right away."
  end

  defp featured_status_label(%{phase: "biddable", ends_at: ends_at}),
    do: LaunchComponents.time_left_label(ends_at)

  defp featured_status_label(%{phase: "live"}), do: "Live"
  defp featured_status_label(_token), do: "Watch"

  defp featured_status_class(%{phase: "biddable"}), do: "is-live"
  defp featured_status_class(%{phase: "live"}), do: "is-finished"
  defp featured_status_class(_token), do: "is-muted"

  defp tracked_market_cap(directory) do
    directory
    |> Enum.map(&AutolaunchWeb.Format.parse_decimal(&1.implied_market_cap_quote))
    |> Enum.reject(&is_nil/1)
    |> sum_decimals()
    |> case do
      nil -> "Unavailable"
      decimal -> AutolaunchWeb.Format.format_currency(decimal, 0)
    end
  end

  defp spotlight_token(directory) do
    Enum.find(directory, &(&1.phase == "biddable")) || Enum.find(directory, &(&1.phase == "live"))
  end

  defp sum_decimals([]), do: nil
  defp sum_decimals([first | rest]), do: Enum.reduce(rest, first, &D.add/2)

  defp home_live_css, do: @home_live_css

  defp launch_module do
    :autolaunch
    |> Application.get_env(:home_live, [])
    |> Keyword.get(:launch_module, Launch)
  end
end
