defmodule AutolaunchWeb.HomeLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.Launch
  alias AutolaunchWeb.LaunchComponents
  alias AutolaunchWeb.Live.Refreshable
  alias Decimal, as: D

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
     |> assign(:page_title, "Autolaunch")
     |> assign(:active_view, "home")
     |> assign(:launch_steps, @launch_steps)
     |> assign_home_market()}
  end

  def handle_info(:refresh, socket) do
    {:noreply, Refreshable.refresh(socket, @poll_ms, &reload_home/1)}
  end

  def render(assigns) do
    ~H"""
    <style><%= Phoenix.HTML.raw(home_live_css()) %></style>
    <.shell current_human={@current_human} active_view={@active_view}>
      <div id="autolaunch-home-dashboard">
        <section
          id="home-dashboard-hero"
          class="al-panel al-home-dashboard-hero"
          phx-hook="HomeHeroMotion"
        >
          <div class="al-home-dashboard-copy">
            <p class="al-kicker">Home</p>
            <h2>Launch and grow agent economies</h2>
            <p class="al-subcopy">
              Autolaunch helps operators launch, fund, and grow agent economies on Base with one
              reviewed path from setup to live market.
            </p>

            <div class="al-home-dashboard-actions">
              <.link navigate={~p"/launch"} class="al-submit">Go to Launch</.link>
              <.link navigate={~p"/auctions"} class="al-ghost">Explore auctions</.link>
            </div>
          </div>

          <div class="al-home-dashboard-visual" aria-hidden="true">
            <div class="al-home-dashboard-orbit">
              <img src={~p"/images/autolaunch-logo-large.png"} alt="" />
            </div>
            <span class="al-home-dashboard-chip is-top">Auctions</span>
            <span class="al-home-dashboard-chip is-right">Growth</span>
            <span class="al-home-dashboard-chip is-bottom">Trust</span>
          </div>
        </section>

        <section id="home-dashboard-grid" class="al-home-dashboard-grid" phx-hook="MissionMotion">
          <article class="al-panel al-home-dashboard-card">
            <div class="al-home-card-head">
              <h3>Market snapshot</h3>
            </div>

            <div class="al-home-market-primary">
              <div>
                <span>Tracked market cap</span>
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

            <div class="al-home-card-footer">
              <.link navigate={~p"/auctions"}>View all markets →</.link>
            </div>
          </article>

          <article class="al-panel al-home-dashboard-card">
            <div class="al-home-card-head">
              <h3>Featured auctions</h3>
              <.link navigate={~p"/auctions"}>View all →</.link>
            </div>

            <div class="al-home-auction-list">
              <article :for={token <- @featured_tokens} class="al-home-auction-row">
                <div class="al-home-auction-avatar" aria-hidden="true">
                  {String.first(token.symbol || token.agent_name || "?")}
                </div>
                <div class="al-home-auction-copy">
                  <strong>{token.agent_name}</strong>
                  <p>${token.symbol}</p>
                </div>
                <div class="al-home-auction-meta">
                  <strong>{format_currency(token.implied_market_cap_usdc, 0)}</strong>
                  <span class={["al-home-status-pill", featured_status_class(token)]}>
                    {featured_status_label(token)}
                  </span>
                </div>
              </article>
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
              <.link navigate={~p"/launch"} class="al-submit">Go to Launch</.link>
            </div>
          </article>
        </section>

        <section
          id="home-dashboard-bottom"
          class="al-home-dashboard-bottom"
          phx-hook="MissionMotion"
        >
          <article class="al-panel al-home-metric-strip">
            <div :for={item <- @metric_items} class="al-home-metric-item">
              <span>{item.label}</span>
              <strong>{item.value}</strong>
              <p>{item.note}</p>
            </div>
          </article>

          <article class="al-panel al-home-activity-card">
            <div class="al-home-card-head">
              <h3>Latest activity</h3>
              <.link navigate={~p"/auctions"}>View all →</.link>
            </div>

            <div class="al-home-activity-list">
              <article :for={item <- @activity_items} class="al-home-activity-row">
                <div class="al-home-activity-dot" data-phase={item.phase}></div>
                <div class="al-home-activity-copy">
                  <strong>{item.title}</strong>
                  <p>{item.note}</p>
                </div>
                <span>{item.value}</span>
              </article>
            </div>
          </article>
        </section>
      </div>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end

  defp reload_home(socket), do: assign_home_market(socket)

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
    |> assign(
      :metric_items,
      metric_items(tracked_market_cap, biddable_count, live_count, listed_agents)
    )
    |> assign(:activity_items, activity_items(featured_tokens))
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
      %{label: "Tracked market cap", value: tracked_market_cap, note: "Across listed markets"},
      %{label: "Open auctions", value: biddable_count, note: "Right now"},
      %{label: "Tokens live", value: live_count, note: "After auction close"},
      %{label: "Listed agents", value: listed_agents, note: "Across the market"}
    ]
  end

  defp activity_items([]) do
    [
      %{
        title: "No market activity yet",
        note: "Open the launch path to prepare the first market.",
        value: "Waiting",
        phase: "idle"
      }
    ]
  end

  defp activity_items(tokens) do
    Enum.map(tokens, fn token ->
      %{
        title: activity_title(token),
        note: activity_note(token),
        value: format_currency(token.current_price_usdc, 4),
        phase: token.phase
      }
    end)
  end

  defp activity_title(%{phase: "biddable", agent_name: name}), do: "Open auction for #{name}"
  defp activity_title(%{phase: "live", agent_name: name}), do: "#{name} is live"
  defp activity_title(%{agent_name: name}), do: "Watch #{name}"

  defp activity_note(token), do: market_timing_label(token)

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

  defp market_timing_label(%{phase: "biddable", ends_at: ends_at}),
    do: LaunchComponents.time_left_label(ends_at)

  defp market_timing_label(%{phase: "live"}), do: "Auction closed"
  defp market_timing_label(_token), do: "Check token page"

  defp tracked_market_cap(directory) do
    directory
    |> Enum.map(&parse_decimal(&1.implied_market_cap_usdc))
    |> Enum.reject(&is_nil/1)
    |> sum_decimals()
    |> case do
      nil -> "Unavailable"
      decimal -> format_currency(decimal, 0)
    end
  end

  defp spotlight_token(directory) do
    Enum.find(directory, &(&1.phase == "biddable")) || Enum.find(directory, &(&1.phase == "live"))
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(""), do: nil

  defp parse_decimal(value) when is_binary(value) do
    try do
      D.new(value)
    rescue
      _ -> nil
    end
  end

  defp parse_decimal(value) when is_integer(value), do: D.new(value)
  defp parse_decimal(%D{} = value), do: value
  defp parse_decimal(_value), do: nil

  defp sum_decimals([]), do: nil
  defp sum_decimals([first | rest]), do: Enum.reduce(rest, first, &D.add/2)

  defp format_currency(nil, _places), do: "Unavailable"

  defp format_currency(value, places) do
    case parse_decimal(value) do
      nil ->
        "Unavailable"

      decimal ->
        "$" <>
          (decimal
           |> D.round(places)
           |> decimal_to_string(places)
           |> add_delimiters())
    end
  end

  defp decimal_to_string(decimal, places) do
    string = D.to_string(decimal, :normal)

    case String.split(string, ".", parts: 2) do
      [whole, fraction] ->
        padded =
          fraction
          |> String.pad_trailing(places, "0")
          |> String.slice(0, places)

        if places == 0, do: whole, else: whole <> "." <> padded

      [whole] ->
        if places == 0, do: whole, else: whole <> "." <> String.duplicate("0", places)
    end
  end

  defp add_delimiters("-" <> rest), do: "-" <> add_delimiters(rest)

  defp add_delimiters(value) do
    case String.split(value, ".", parts: 2) do
      [whole, fraction] -> add_delimiters_to_whole(whole) <> "." <> fraction
      [whole] -> add_delimiters_to_whole(whole)
    end
  end

  defp add_delimiters_to_whole(whole) do
    whole
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.join/1)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp home_live_css, do: @home_live_css

  defp launch_module do
    :autolaunch
    |> Application.get_env(:home_live, [])
    |> Keyword.get(:launch_module, Launch)
  end
end
