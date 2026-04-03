defmodule AutolaunchWeb.AuctionsLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.Launch
  alias AutolaunchWeb.LaunchComponents
  alias AutolaunchWeb.Live.Refreshable

  @poll_ms 15_000
  @default_filters %{"mode" => "biddable", "sort" => "newest"}

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> Refreshable.schedule(@poll_ms)
     |> assign(:page_title, "Tokens")
     |> assign(:active_view, "auctions")
     |> assign(:filters, @default_filters)
     |> assign_directory(@default_filters)}
  end

  def handle_event("filters_changed", %{"filters" => filters}, socket) do
    merged = Map.merge(socket.assigns.filters, filters)

    {:noreply,
     socket
     |> assign(:filters, merged)
     |> assign_directory(merged)}
  end

  def handle_info(:refresh, socket) do
    {:noreply, Refreshable.refresh(socket, @poll_ms, &reload_directory/1)}
  end

  def render(assigns) do
    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <section id="auctions-hero" class="al-hero al-panel al-directory-hero" phx-hook="MissionMotion">
        <div class="al-directory-copy">
          <p class="al-kicker">Active auctions</p>
          <h2>Use stablecoins to back agents with provable revenue.</h2>
          <p class="al-subcopy">
            Every biddable token here is in its live three-day auction window. The auction is
            designed to feel simple and fair: pick your budget, pick your max price, and let the
            order run over time instead of trying to win a timing game.
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

        <div class="al-stat-grid">
          <.stat_card title="Biddable" value={Integer.to_string(@biddable_count)} />
          <.stat_card title="Live" value={Integer.to_string(@live_count)} />
          <.stat_card title="Visible" value={Integer.to_string(length(@tokens))} />
        </div>
      </section>

      <section id="auctions-facts" class="al-panel al-directory-facts" phx-hook="MissionMotion">
        <div class="al-section-head">
          <div>
            <p class="al-kicker">What to know before you bid</p>
            <h3>The short, non-crypto-heavy version.</h3>
          </div>
        </div>

        <div class="al-directory-facts-grid">
          <article class="al-directory-fact-card">
            <span>Minimum raise</span>
            <strong>Every auction can set a USDC floor that it must reach to graduate.</strong>
            <p>If the auction ends below that mark, bidders can return their USDC instead of being forced into a weak launch.</p>
          </article>

          <article class="al-directory-fact-card">
            <span>How to start</span>
            <strong>Begin with your budget at the current displayed floor or clearing price.</strong>
            <p>You may need to update later if demand moves higher and your bid falls out of range.</p>
          </article>

          <article class="al-directory-fact-card">
            <span>Why it feels fair</span>
            <strong>Orders spread over the remaining blocks instead of rewarding one perfect click.</strong>
            <p>Everyone in the same block gets the same clearing price, which cuts down on sniping and bot timing edges.</p>
          </article>

          <article class="al-directory-fact-card">
            <span>Token split</span>
            <strong>10 billion tokens are auctioned, 5 billion are reserved for LP, and 85 billion vest for 1 year.</strong>
            <p>That is the current live launch split for the 100 billion token supply.</p>
          </article>

          <article class="al-directory-fact-card">
            <span>Where the money goes</span>
            <strong>Half of auction USDC goes to the Uniswap v4 pool, and half goes to the agent Safe.</strong>
            <p>The 5 billion LP tokens pair with the LP-side USDC, while the Safe-side USDC is for business operations.</p>
          </article>
        </div>
      </section>

      <section class="al-panel al-filter-panel al-directory-controls">
        <form phx-change="filters_changed" class="al-directory-form">
          <div class="al-segmented" role="group" aria-label="Token phase">
            <label class={["al-segmented-option", @filters["mode"] == "biddable" && "is-active"]}>
              <input type="radio" name="filters[mode]" value="biddable" checked={@filters["mode"] == "biddable"} />
              <span>Biddable</span>
            </label>
            <label class={["al-segmented-option", @filters["mode"] == "live" && "is-active"]}>
              <input type="radio" name="filters[mode]" value="live" checked={@filters["mode"] == "live"} />
              <span>Live</span>
            </label>
          </div>

          <label>
            <span>Sort</span>
            <select name="filters[sort]">
              <option value="newest" selected={@filters["sort"] == "newest"}>Newest first</option>
              <option value="oldest" selected={@filters["sort"] == "oldest"}>Oldest first</option>
              <option value="market_cap_desc" selected={@filters["sort"] == "market_cap_desc"}>Market cap high to low</option>
              <option value="market_cap_asc" selected={@filters["sort"] == "market_cap_asc"}>Market cap low to high</option>
            </select>
          </label>
        </form>
      </section>

      <%= if @tokens == [] do %>
        <.empty_state
          title="No tokens match this directory view yet."
          body="Switch between Biddable and Live or check back after the next launch finishes its three-day auction window."
        />
      <% else %>
        <section class="al-token-grid">
          <article :for={token <- @tokens} id={"auction-tile-#{token.id}"} class="al-panel al-token-card" phx-hook="MissionMotion">
            <div class="al-token-card-head">
              <div>
                <p class="al-kicker">{token.agent_id}</p>
                <h3>{token.agent_name}</h3>
                <p class="al-inline-note">{token.symbol} • {token.phase}</p>
              </div>
              <span class={["al-status-badge", if(token.phase == "biddable", do: "is-ready", else: "is-muted")]}>
                {String.capitalize(token.phase)}
              </span>
            </div>

            <div class="al-launch-tags">
              <span class="al-launch-tag">Price {display_value(token.current_price_usdc, "USDC")}</span>
              <span class="al-launch-tag">Market cap {display_value(token.implied_market_cap_usdc, "USDC")}</span>
              <span class="al-launch-tag">Started {format_date(token.started_at)}</span>
            </div>

            <div class="al-stat-grid">
              <.stat_card title="Price source" value={humanize_price_source(token.price_source)} />
              <.stat_card title="Auction" value={LaunchComponents.time_left_label(token.ends_at)} />
              <.stat_card title="Trust" value={trust_summary(token.trust)} />
            </div>

            <p class="al-inline-note">
              {directory_copy(token.phase)}
            </p>

            <div class="al-action-row">
              <.link navigate={token.detail_url} class="al-submit">
                {if token.phase == "biddable", do: "Open bid view", else: "Inspect launch"}
              </.link>
              <.link :if={token.subject_url} navigate={token.subject_url} class="al-ghost">
                Open token detail
              </.link>
              <a :if={token.uniswap_url} href={token.uniswap_url} class="al-ghost" target="_blank" rel="noreferrer">
                Uniswap
              </a>
            </div>
          </article>
        </section>
      <% end %>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end

  defp assign_directory(socket, filters) do
    directory =
      launch_module().list_auctions(
        %{"mode" => "all", "sort" => filters["sort"]},
        socket.assigns[:current_human]
      )

    visible_tokens =
      Enum.filter(directory, fn token ->
        token.phase == Map.get(filters, "mode", "biddable")
      end)

    socket
    |> assign(:directory, directory)
    |> assign(:tokens, visible_tokens)
    |> assign(:biddable_count, Enum.count(directory, &(&1.phase == "biddable")))
    |> assign(:live_count, Enum.count(directory, &(&1.phase == "live")))
  end

  defp reload_directory(socket), do: assign_directory(socket, socket.assigns.filters)

  defp display_value(nil, unit), do: "Unavailable #{unit}"
  defp display_value(value, unit), do: "#{value} #{unit}"

  defp format_date(nil), do: "Unknown"

  defp format_date(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> Calendar.strftime(datetime, "%b %-d")
      _ -> "Unknown"
    end
  end

  defp humanize_price_source("auction_clearing"), do: "Auction clearing"
  defp humanize_price_source("uniswap_spot"), do: "Uniswap spot"
  defp humanize_price_source("uniswap_spot_unavailable"), do: "Quote pending"
  defp humanize_price_source(_), do: "Unavailable"

  defp trust_summary(%{ens: %{connected: true, name: name}, world: %{connected: true}})
       when is_binary(name),
       do: "#{name} • World connected"

  defp trust_summary(%{ens: %{connected: true, name: name}}) when is_binary(name), do: name
  defp trust_summary(%{world: %{connected: true, launch_count: count}}), do: "World #{count}"
  defp trust_summary(_), do: "Optional links"

  defp directory_copy("biddable"),
    do:
      "This token is still in the active three-day auction window. The price and market cap reflect the current clearing level."

  defp directory_copy("live"),
    do:
      "This token has moved out of the auction phase. The price and market cap now follow the Uniswap market instead of the auction curve."

  defp launch_module do
    :autolaunch
    |> Application.get_env(:auctions_live, [])
    |> Keyword.get(:launch_module, Launch)
  end
end
