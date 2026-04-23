defmodule AutolaunchWeb.AuctionsLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.Launch
  alias AutolaunchWeb.LaunchComponents
  alias AutolaunchWeb.Live.Refreshable
  alias Decimal, as: D

  @poll_ms 15_000
  @auctions_css_path Path.expand("../../../assets/css/auctions-live.css", __DIR__)
  @external_resource @auctions_css_path
  @auctions_css File.read!(@auctions_css_path)
  @default_filters %{"mode" => "biddable", "network" => "all", "search" => "", "sort" => "newest"}
  @allowed_modes ~w(biddable live)
  @allowed_sorts ~w(newest oldest market_cap_desc market_cap_asc)

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> Refreshable.schedule(@poll_ms)
     |> Refreshable.subscribe([:market, :system])
     |> assign(:page_title, "Auctions")
     |> assign(:active_view, "auctions")}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, assign_directory(socket, Map.merge(@default_filters, params))}
  end

  def handle_event("filters_changed", %{"filters" => filters}, socket) do
    merged = Map.merge(socket.assigns.filters, filters)

    {:noreply, push_patch(socket, to: ~p"/auctions?#{filter_query(merged)}")}
  end

  def handle_info(:refresh, socket) do
    {:noreply, Refreshable.refresh(socket, @poll_ms, &reload_directory/1)}
  end

  def handle_info({:autolaunch_live_update, :changed}, socket) do
    {:noreply, reload_directory(socket)}
  end

  def render(assigns) do
    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <style id="auctions-live-css">
        <%= raw(route_css()) %>
      </style>

      <div class="al-auctions-route">
        <section id="auctions-page-head" class="al-auctions-page-head" phx-hook="MissionMotion">
          <div>
            <h1>Auctions</h1>
          </div>

          <nav class="tabs tabs-boxed al-auctions-page-tabs" aria-label="Auction pages">
            <.link navigate={~p"/auctions"} class="tab tab-active">Open markets</.link>
            <.link navigate={~p"/auction-returns"} class="tab">Auction returns</.link>
          </nav>
        </section>

        <section
          id="auctions-market"
          class="al-panel al-auctions-market-shell"
          phx-hook="AuctionsMarketMotion"
        >
          <div class="al-auctions-market-topline" data-market-reveal>
            <div>
              <p class="al-kicker">Market workspace</p>
              <p class="al-subcopy">Compare open launches, check the leaderboard, and move into a bid page without losing the market read.</p>
            </div>
          </div>

          <div class="al-auctions-market-strip">
          <article class="al-auctions-market-stat" data-market-reveal>
            <div class="al-auctions-market-stat-head">
              <span class="al-auctions-market-dot is-open"></span>
              <span>Total market cap</span>
            </div>
            <strong
              data-market-counter={@market_totals.total_market_cap_raw || "0"}
              data-market-prefix="$"
              data-market-suffix=""
              data-market-decimals="0"
            >
              {@market_totals.total_market_cap}
            </strong>
            <p>Across this view</p>
          </article>
          <article class="al-auctions-market-stat" data-market-reveal>
            <div class="al-auctions-market-stat-head">
              <span class="al-auctions-market-dot is-volume"></span>
              <span>Total bid volume</span>
            </div>
            <strong
              data-market-counter={@market_totals.visible_bid_volume_raw || "0"}
              data-market-prefix="$"
              data-market-suffix=""
              data-market-decimals="0"
            >
              {@market_totals.visible_bid_volume}
            </strong>
            <p>Visible auctions</p>
          </article>
          <article class="al-auctions-market-stat" data-market-reveal>
            <div class="al-auctions-market-stat-head">
              <span class="al-auctions-market-dot is-shown"></span>
              <span>Active auctions</span>
            </div>
            <strong
              data-market-counter={Integer.to_string(@market_totals.open_count)}
              data-market-decimals="0"
            >
              {@market_totals.open_count}
            </strong>
            <p>Live now</p>
          </article>
          <article class="al-auctions-market-stat" data-market-reveal>
            <div class="al-auctions-market-stat-head">
              <span class="al-auctions-market-dot is-finished"></span>
              <span>Ending soon</span>
            </div>
            <strong
              data-market-counter={Integer.to_string(@market_totals.ending_soon_count)}
              data-market-decimals="0"
            >
              {@market_totals.ending_soon_count}
            </strong>
            <p>Less than 2h</p>
          </article>
          <article class="al-auctions-market-stat" data-market-reveal>
            <div class="al-auctions-market-stat-head">
              <span class="al-auctions-market-dot is-volume"></span>
              <span>Returns ready</span>
            </div>
            <strong
              data-market-counter={Integer.to_string(@market_totals.returns_ready_count)}
              data-market-decimals="0"
            >
              {@market_totals.returns_ready_count}
            </strong>
            <p>Ready to claim</p>
          </article>
        </div>

        <div class="al-auctions-market-grid">
          <article class="al-auctions-feature" data-market-reveal>
            <%= if @featured_auction do %>
              <div class="al-auctions-feature-toprow">
                <div class="al-auctions-feature-id">
                  <div class="al-auctions-feature-mark">{agent_monogram(@featured_auction.agent_name)}</div>
                  <div class="al-auctions-feature-name">
                    <p class="al-kicker">Featured market</p>
                    <h2>{@featured_auction.agent_name}</h2>
                    <div class="al-auctions-feature-badges">
                      <span class={["al-status-badge", status_badge_class(@featured_auction)]}>
                        {row_status_label(@featured_auction)}
                      </span>
                      <span class="al-network-badge">{network_label(@featured_auction)}</span>
                    </div>
                  </div>
                </div>

                <div class="al-auctions-feature-endcap">
                  <span>{time_label(@featured_auction)}</span>
                  <strong>{LaunchComponents.time_left_label(@featured_auction.ends_at)}</strong>
                  <span class="al-auctions-feature-live-dot"></span>
                </div>
              </div>

              <div class="al-auctions-feature-stats">
                <article>
                  <span>Current price</span>
                  <strong>{format_price(@featured_auction.current_price_usdc)}</strong>
                </article>
                <article>
                  <span>Market cap</span>
                  <strong>{format_large_currency(@featured_auction.implied_market_cap_usdc)}</strong>
                </article>
                <article>
                  <span>Total bids</span>
                  <strong>{format_volume(@featured_auction.total_bid_volume)}</strong>
                </article>
                <article>
                  <span>Time left</span>
                  <strong>{LaunchComponents.time_left_label(@featured_auction.ends_at)}</strong>
                </article>
              </div>

              <div class="al-auctions-feature-meter">
                <div class="al-auctions-feature-meter-copy">
                  <span>Minimum raise progress</span>
                  <strong>{progress_label(@featured_auction.minimum_raise_progress_percent)}</strong>
                </div>
                <div class="al-auctions-feature-meter-track">
                  <div
                    class="al-auctions-feature-meter-fill"
                    data-market-progress={progress_value(@featured_auction.minimum_raise_progress_percent)}
                  >
                    <span data-market-pulse></span>
                  </div>
                </div>
              </div>

              <div class="al-auctions-feature-footer">
                <div class="al-hero-actions">
                  <.link navigate={primary_action_href(@featured_auction)} class="al-submit">
                    {primary_action_label(@featured_auction)}
                  </.link>
                  <.link
                    :if={secondary_subject_href(@featured_auction)}
                    navigate={secondary_subject_href(@featured_auction)}
                    class="al-ghost"
                  >
                    Open token page
                  </.link>
                  <a
                    :if={@featured_auction.uniswap_url}
                    href={@featured_auction.uniswap_url}
                    class="al-ghost"
                    target="_blank"
                    rel="noreferrer"
                  >
                    Uniswap
                  </a>
                </div>

                <div class="al-auctions-feature-trust">
                  <span class="al-auctions-feature-chip">{@featured_auction.symbol}</span>
                  <span class="al-auctions-feature-chip">
                    {humanize_price_source(@featured_auction.price_source)}
                  </span>
                  <span class="al-auctions-feature-chip">{trust_summary(@featured_auction.trust)}</span>
                </div>
              </div>
            <% else %>
              <div class="al-auctions-feature-empty">
                <p class="al-kicker">Featured market</p>
                <h2>No auction is live right now.</h2>
                <p class="al-subcopy">
                  Check back after the next launch opens, or use the guide to review how the market works.
                </p>
                <div class="al-hero-actions">
                  <.link navigate={~p"/how-auctions-work"} class="al-cta-link">
                    How auctions work
                  </.link>
                  <.link navigate={~p"/auction-returns"} class="al-ghost">
                    Auction returns
                  </.link>
                </div>
              </div>
            <% end %>
          </article>

          <aside class="al-auctions-leaderboard" data-market-reveal>
            <div class="al-auctions-leaderboard-head">
              <div>
                <p class="al-kicker">Leaderboard</p>
                <h3>Top markets</h3>
              </div>
              <a href="#auctions-list" class="al-auctions-inline-link">View all</a>
            </div>

            <div class="al-auctions-leaderboard-list">
              <%= if @leaderboard_items == [] do %>
                <p class="al-inline-note">No auctions match this view yet.</p>
              <% else %>
                <.link
                  :for={{auction, index} <- Enum.with_index(@leaderboard_items, 1)}
                  navigate={auction.detail_url}
                  class="al-auctions-leaderboard-row"
                >
                  <span class="al-auctions-leaderboard-rank">{index}</span>
                  <div class="al-auctions-leaderboard-main">
                    <div class="al-auctions-leaderboard-mark">{agent_monogram(auction.agent_name)}</div>
                    <div class="al-auctions-leaderboard-copy">
                      <strong>{auction.agent_name}</strong>
                      <span>{auction.symbol}</span>
                    </div>
                  </div>
                  <div class="al-auctions-leaderboard-value">
                    <strong>{format_large_currency(auction.implied_market_cap_usdc)}</strong>
                    <span class={["al-status-badge", status_badge_class(auction)]}>
                      {row_status_label(auction)}
                    </span>
                  </div>
                </.link>
              <% end %>
            </div>

            <div class="al-auctions-leaderboard-foot">Market cap</div>
          </aside>
        </div>
        </section>

        <section
          id="auctions-controls"
          class="al-panel al-directory-controls"
          phx-hook="MissionMotion"
        >
          <form phx-change="filters_changed" class="al-auctions-control-form">
            <div class="al-auctions-toolbar">
              <div class="al-auctions-control-field">
                <span class="al-auctions-control-label">View</span>
            <div class="al-segmented" role="group" aria-label="Auction phase">
              <label class={["al-segmented-option", @filters["mode"] == "biddable" && "is-active"]}>
                <input type="radio" name="filters[mode]" value="biddable" checked={@filters["mode"] == "biddable"} />
                <span>Biddable</span>
              </label>
              <label class={["al-segmented-option", @filters["mode"] == "live" && "is-active"]}>
                <input type="radio" name="filters[mode]" value="live" checked={@filters["mode"] == "live"} />
                <span>Live</span>
              </label>
            </div>
              </div>

              <label class="al-auctions-search">
                <span class="al-auctions-control-label">Search</span>
                <input
                  type="search"
                  name="filters[search]"
                  value={@filters["search"]}
                  placeholder="Search by name, symbol, agent ID, or ENS"
                />
              </label>

              <label :if={@show_network_filter} class="al-auctions-filter-field">
                <span class="al-auctions-control-label">Network</span>
                <select name="filters[network]">
                  <option value="all" selected={@filters["network"] == "all"}>All networks</option>
                  <option
                    :for={option <- @network_options}
                    value={option.value}
                    selected={@filters["network"] == option.value}
                  >
                    {option.label}
                  </option>
                </select>
              </label>

              <label class="al-auctions-filter-field">
                <span class="al-auctions-control-label">Sort</span>
                <select name="filters[sort]">
                  <option value="newest" selected={@filters["sort"] == "newest"}>
                    Newest first
                  </option>
                  <option value="oldest" selected={@filters["sort"] == "oldest"}>
                    Oldest first
                  </option>
                  <option
                    value="market_cap_desc"
                    selected={@filters["sort"] == "market_cap_desc"}
                  >
                    Market cap high to low
                  </option>
                  <option value="market_cap_asc" selected={@filters["sort"] == "market_cap_asc"}>
                    Market cap low to high
                  </option>
                </select>
              </label>
            </div>
          </form>
        </section>

        <section
          id="auctions-list"
          class="al-panel al-auctions-list-shell"
          phx-hook="MissionMotion"
        >
          <div class="al-auctions-list-head">
            <div>
              <p class="al-kicker">Market list</p>
              <h3>Compare price, size, trust, and timing at a glance.</h3>
            </div>
            <p class="al-subcopy">
              Showing {@market_totals.shown_count} of {length(@directory)} auctions in this view.
            </p>
          </div>

          <%= if @visible_rows == [] do %>
            <div class="al-auctions-empty-state">
              <h3>No auctions match this view yet.</h3>
              <p>
                Try a different search, switch between Biddable and Live, or clear the network
                filter.
              </p>
            </div>
          <% else %>
            <div class="al-table-shell al-auctions-table-shell">
              <table class="al-table al-auctions-table">
                <thead>
                  <tr>
                    <th>Auction</th>
                    <th>Network</th>
                    <th>Status</th>
                    <th>Price</th>
                    <th>Market cap</th>
                    <th>Bid volume</th>
                    <th>Time left</th>
                    <th>Progress</th>
                    <th>Action</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={token <- @visible_rows} id={"auction-row-#{token.id}"}>
                    <td>
                      <div class="al-auctions-token-cell">
                        <div class="al-auctions-token-mark">{agent_monogram(token.agent_name)}</div>
                        <div class="al-auctions-token-meta">
                          <div class="al-auctions-token-line">
                            <strong class="al-auctions-token-name">{token.agent_name}</strong>
                            <span class="al-auctions-token-symbol">{token.symbol}</span>
                          </div>
                          <p class="al-auctions-table-meta">
                            {token.agent_id} • {trust_compact(token.trust)}
                          </p>
                        </div>
                      </div>
                    </td>
                    <td>
                      {network_label(token)}
                    </td>
                    <td>
                      <span class={["al-status-badge", status_badge_class(token)]}>
                        {row_status_label(token)}
                      </span>
                    </td>
                    <td>
                      <div class="al-auctions-value-cell">
                        <strong>{format_price(token.current_price_usdc)}</strong>
                        <p class="al-auctions-table-note">
                          {humanize_price_source(token.price_source)}
                        </p>
                      </div>
                    </td>
                    <td>{format_large_currency(token.implied_market_cap_usdc)}</td>
                    <td>{format_volume(token.total_bid_volume)}</td>
                    <td class="al-auctions-time">{time_cell_copy(token)}</td>
                    <td>
                      <div class="al-auctions-progress-cell">
                        <span>{progress_label(token.minimum_raise_progress_percent)}</span>
                        <div class="al-auctions-progress-track">
                          <div
                            class="al-auctions-progress-fill"
                            style={"width: #{progress_value(token.minimum_raise_progress_percent)}%"}
                          >
                          </div>
                        </div>
                      </div>
                    </td>
                    <td>
                      <.link navigate={primary_action_href(token)} class="al-auctions-row-action">
                        {primary_action_label(token)}
                      </.link>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      </div>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end

  defp assign_directory(socket, filters) do
    sort = sanitize_value(Map.get(filters, "sort"), @allowed_sorts, @default_filters["sort"])

    directory =
      launch_module().list_auctions(
        %{"mode" => "all", "sort" => sort},
        socket.assigns[:current_human]
      )

    network_options = network_options(directory)
    sanitized_filters = sanitize_filters(filters, network_options)
    visible_rows = visible_rows(directory, sanitized_filters)

    socket
    |> assign(:filters, sanitized_filters)
    |> assign(:directory, directory)
    |> assign(:visible_rows, visible_rows)
    |> assign(:tokens, visible_rows)
    |> assign(:featured_auction, featured_auction(directory, visible_rows, sanitized_filters))
    |> assign(:leaderboard_items, leaderboard_items(visible_rows))
    |> assign(:network_options, network_options)
    |> assign(:show_network_filter, length(network_options) > 1)
    |> assign(:market_totals, market_totals(directory, visible_rows))
  end

  defp reload_directory(socket), do: assign_directory(socket, socket.assigns.filters)

  defp filter_query(filters) do
    filters
    |> Enum.reject(fn {key, value} ->
      Map.get(@default_filters, key) == value or value in [nil, ""]
    end)
    |> Map.new()
  end

  defp sanitize_filters(filters, network_options) do
    network_values = Enum.map(network_options, & &1.value)

    network =
      filters
      |> Map.get("network", "all")
      |> then(fn value -> if value in network_values, do: value, else: "all" end)

    %{
      "mode" =>
        sanitize_value(Map.get(filters, "mode"), @allowed_modes, @default_filters["mode"]),
      "network" => network,
      "search" => filters |> Map.get("search", "") |> to_string() |> String.trim(),
      "sort" => sanitize_value(Map.get(filters, "sort"), @allowed_sorts, @default_filters["sort"])
    }
  end

  defp sanitize_value(value, allowed, default) do
    if value in allowed, do: value, else: default
  end

  defp visible_rows(directory, filters) do
    directory
    |> Enum.filter(&(&1.phase == filters["mode"]))
    |> maybe_filter_search(filters["search"])
    |> maybe_filter_network(filters["network"])
  end

  defp maybe_filter_search(rows, ""), do: rows

  defp maybe_filter_search(rows, query) do
    needle = String.downcase(query)

    Enum.filter(rows, fn row ->
      row
      |> search_blob()
      |> String.contains?(needle)
    end)
  end

  defp maybe_filter_network(rows, "all"), do: rows
  defp maybe_filter_network(rows, network), do: Enum.filter(rows, &(&1.network == network))

  defp search_blob(row) do
    [
      row.agent_name,
      row.symbol,
      row.agent_id,
      ens_name(row.trust)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map_join(" ", &String.downcase/1)
  end

  defp ens_name(%{ens: %{connected: true, name: name}}) when is_binary(name), do: name
  defp ens_name(_trust), do: nil

  defp featured_auction(directory, visible_rows, filters) do
    case featured_row(visible_rows) do
      nil ->
        if filters["search"] == "" and filters["network"] == "all" do
          featured_row(directory)
        else
          nil
        end

      row ->
        row
    end
  end

  defp featured_row(rows) do
    Enum.find(rows, &(&1.phase == "biddable")) || Enum.find(rows, &(&1.phase == "live"))
  end

  defp leaderboard_items(rows) do
    rows
    |> Enum.sort(&market_cap_desc?/2)
    |> Enum.take(5)
  end

  defp network_options(directory) do
    directory
    |> Enum.reduce(%{}, fn row, acc ->
      Map.put(acc, row.network, %{value: row.network, label: network_label(row)})
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.label)
  end

  defp market_totals(directory, visible_rows) do
    visible_bid_volume_raw =
      visible_rows
      |> Enum.map(&parse_decimal(&1.total_bid_volume))
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        [first | rest] -> Enum.reduce(rest, first, &D.add/2)
      end

    total_market_cap_raw =
      visible_rows
      |> Enum.map(&parse_decimal(&1.implied_market_cap_usdc))
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        [first | rest] -> Enum.reduce(rest, first, &D.add/2)
      end

    %{
      open_count: Enum.count(directory, &(&1.phase == "biddable")),
      shown_count: length(visible_rows),
      ending_soon_count: Enum.count(visible_rows, &ending_soon?/1),
      returns_ready_count: Enum.count(directory, &truthy?(Map.get(&1, :returns_enabled))),
      total_market_cap_raw:
        if(total_market_cap_raw, do: D.to_string(total_market_cap_raw, :normal), else: nil),
      total_market_cap:
        format_large_currency(
          if(total_market_cap_raw, do: D.to_string(total_market_cap_raw, :normal), else: "0")
        ),
      visible_bid_volume_raw:
        if(visible_bid_volume_raw, do: D.to_string(visible_bid_volume_raw, :normal), else: nil),
      visible_bid_volume:
        format_large_currency(
          if(visible_bid_volume_raw, do: D.to_string(visible_bid_volume_raw, :normal), else: "0")
        )
    }
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(""), do: nil

  defp parse_decimal(value) when is_binary(value) do
    case D.parse(value) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  defp parse_decimal(value) when is_integer(value), do: D.new(value)
  defp parse_decimal(_value), do: nil

  defp format_price(value), do: format_currency(value, 4)
  defp format_large_currency(value), do: format_currency(value, 0)
  defp format_volume(value), do: format_currency(value, 2)

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

  defp decimal_to_string(decimal, 0), do: D.to_string(decimal, :normal)

  defp decimal_to_string(decimal, places) do
    base = D.to_string(decimal, :normal)

    case String.split(base, ".", parts: 2) do
      [integer, fraction] ->
        integer <> "." <> String.pad_trailing(String.slice(fraction, 0, places), places, "0")

      [integer] ->
        integer <> "." <> String.duplicate("0", places)
    end
  end

  defp add_delimiters(value) do
    {sign, digits} =
      case String.starts_with?(value, "-") do
        true -> {"-", String.trim_leading(value, "-")}
        false -> {"", value}
      end

    case String.split(digits, ".", parts: 2) do
      [integer, fraction] -> sign <> add_integer_delimiters(integer) <> "." <> fraction
      [integer] -> sign <> add_integer_delimiters(integer)
    end
  end

  defp add_integer_delimiters(integer) do
    integer
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp primary_action_label(%{phase: "biddable"}), do: "Open bid page"

  defp primary_action_label(%{phase: "live", subject_url: subject_url})
       when is_binary(subject_url), do: "Open token page"

  defp primary_action_label(_row), do: "Inspect launch"

  defp primary_action_href(%{phase: "biddable"} = row), do: row.detail_url

  defp primary_action_href(%{phase: "live", subject_url: subject_url})
       when is_binary(subject_url), do: subject_url

  defp primary_action_href(row), do: row.detail_url

  defp row_status_label(row) do
    cond do
      truthy?(Map.get(row, :returns_enabled)) -> "Returns ready"
      row.phase == "biddable" and ending_soon?(row) -> "Ending soon"
      row.phase == "biddable" -> "Live"
      row.phase == "live" -> "Market live"
      true -> phase_label(row.phase)
    end
  end

  defp status_badge_class(row) do
    cond do
      truthy?(Map.get(row, :returns_enabled)) -> "is-muted"
      row.phase == "biddable" and ending_soon?(row) -> "is-warn"
      row.phase == "biddable" -> "is-live"
      row.phase == "live" -> "is-muted"
      true -> phase_badge_class(row.phase)
    end
  end

  defp time_cell_copy(row) do
    cond do
      truthy?(Map.get(row, :returns_enabled)) -> "Returns ready"
      row.phase == "live" -> "Ended"
      true -> LaunchComponents.time_left_label(row.ends_at)
    end
  end

  defp secondary_subject_href(%{subject_url: subject_url} = row) when is_binary(subject_url) do
    if primary_action_href(row) == subject_url, do: nil, else: subject_url
  end

  defp secondary_subject_href(_row), do: nil

  defp time_label(%{phase: "biddable"}), do: "Ends in"
  defp time_label(%{phase: "live"}), do: "Ended"
  defp time_label(_row), do: "Time"

  defp phase_label(phase) do
    phase
    |> to_string()
    |> String.capitalize()
  end

  defp phase_badge_class("biddable"), do: "is-warn"
  defp phase_badge_class("live"), do: "is-muted"
  defp phase_badge_class(_phase), do: "is-muted"

  defp progress_label(nil), do: "Unavailable"
  defp progress_label(value), do: "#{trunc(value)}%"

  defp progress_value(nil), do: "0"

  defp progress_value(value) when is_number(value),
    do: value |> min(100) |> max(0) |> trunc() |> Integer.to_string()

  defp progress_value(_value), do: "0"

  defp humanize_price_source("auction_clearing"), do: "Auction clearing"
  defp humanize_price_source("uniswap_spot"), do: "Uniswap spot"
  defp humanize_price_source("uniswap_spot_unavailable"), do: "Quote pending"
  defp humanize_price_source(_), do: "Unavailable"

  defp trust_compact(%{ens: %{connected: true}, world: %{connected: true}}), do: "ENS + World"
  defp trust_compact(%{ens: %{connected: true}}), do: "ENS linked"
  defp trust_compact(%{world: %{connected: true}}), do: "World linked"
  defp trust_compact(_), do: "Optional links"

  defp agent_monogram(name) when is_binary(name) do
    name
    |> String.split(~r/[\s-]+/, trim: true)
    |> Enum.map(&String.first/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(2)
    |> Enum.join()
    |> String.upcase()
  end

  defp agent_monogram(_name), do: "AL"

  defp trust_summary(%{ens: %{connected: true, name: name}, world: %{connected: true}})
       when is_binary(name),
       do: "#{name} • World connected"

  defp trust_summary(%{ens: %{connected: true, name: name}}) when is_binary(name), do: name
  defp trust_summary(%{world: %{connected: true, launch_count: count}}), do: "World #{count}"
  defp trust_summary(_), do: "Optional links"

  defp network_label(%{chain: chain}) when is_binary(chain) and chain != "", do: chain
  defp network_label(%{network: network}) when is_binary(network) and network != "", do: network
  defp network_label(_row), do: "Unknown"

  defp ending_soon?(%{ends_at: ends_at}), do: ending_soon?(ends_at)

  defp ending_soon?(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> DateTime.diff(datetime, DateTime.utc_now(), :second) in 1..7_200
      _ -> false
    end
  end

  defp ending_soon?(_value), do: false

  defp truthy?(value), do: value in [true, "true", 1, "1"]

  defp market_cap_desc?(left, right) do
    compare_market_caps(left.implied_market_cap_usdc, right.implied_market_cap_usdc) in [:gt, :eq]
  end

  defp compare_market_caps(left, right) do
    case {parse_decimal(left), parse_decimal(right)} do
      {nil, nil} -> :eq
      {nil, _} -> :lt
      {_, nil} -> :gt
      {left_decimal, right_decimal} -> D.compare(left_decimal, right_decimal)
    end
  end

  defp launch_module do
    :autolaunch
    |> Application.get_env(:auctions_live, [])
    |> Keyword.get(:launch_module, Launch)
  end

  defp route_css, do: @auctions_css
end
