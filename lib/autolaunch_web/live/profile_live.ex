defmodule AutolaunchWeb.ProfileLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.Portfolio
  alias AutolaunchWeb.Live.Refreshable

  @poll_ms 15_000

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> Refreshable.schedule(@poll_ms)
     |> assign(:page_title, "Profile")
     |> assign(:active_view, "profile")
     |> assign(:snapshot, load_snapshot(socket.assigns[:current_human]))}
  end

  def handle_event("refresh_profile", _params, socket) do
    case socket.assigns.current_human &&
           portfolio_module().request_manual_refresh(socket.assigns.current_human) do
      {:ok, snapshot} ->
        {:noreply,
         socket |> assign(:snapshot, snapshot) |> put_flash(:info, "Profile refresh started.")}

      {:error, {:cooldown, seconds}} ->
        {:noreply,
         put_flash(socket, :error, "Wait #{seconds} more seconds before refreshing again.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Profile refresh could not start.")}
    end
  end

  def handle_info(:refresh, socket) do
    {:noreply, Refreshable.refresh(socket, @poll_ms, &reload_snapshot/1)}
  end

  def render(assigns) do
    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <section id="profile-hero" class="al-hero al-panel al-profile-hero" phx-hook="MissionMotion">
        <div>
          <p class="al-kicker">Profile</p>
          <h2>Your launches above, your staked token exposure below.</h2>
          <p class="al-subcopy">
            This page is a cached portfolio snapshot. It rebuilds when you log in, and you can force a new lookup from here without waiting on every page render.
          </p>
        </div>

        <div class="al-stat-grid">
          <.stat_card title="Launched" value={Integer.to_string(length(@snapshot.launched_tokens || []))} />
          <.stat_card title="Staked" value={Integer.to_string(length(@snapshot.staked_tokens || []))} />
          <.stat_card title="Status" value={String.capitalize(@snapshot.status || "pending")} />
        </div>
      </section>

      <%= if is_nil(@current_human) do %>
        <.empty_state
          title="Sign in to see your token portfolio."
          body="The profile snapshot is built from the wallets linked to your Privy session."
        />
      <% else %>
        <section class="al-panel al-profile-toolbar">
          <div>
            <p class="al-kicker">Snapshot</p>
            <h3>Last refreshed {format_datetime(@snapshot.refreshed_at)}</h3>
            <p class="al-inline-note">
              {snapshot_copy(@snapshot.status)}
            </p>
          </div>

          <button
            type="button"
            class="al-submit"
            phx-click="refresh_profile"
            disabled={refresh_disabled?(@snapshot.next_manual_refresh_at)}
          >
            {refresh_label(@snapshot.next_manual_refresh_at)}
          </button>
        </section>

        <section :if={(@snapshot.launched_tokens || []) != []} id="profile-launched" class="al-panel al-profile-section" phx-hook="MissionMotion">
          <div class="al-section-head">
            <div>
              <p class="al-kicker">Launched Tokens</p>
              <h3>Tokens launched from your linked wallets.</h3>
            </div>
          </div>

          <div class="al-table-shell">
            <table class="al-table">
              <thead>
                <tr>
                  <th>Token</th>
                  <th>Phase</th>
                  <th>Price</th>
                  <th>Market cap</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={token <- @snapshot.launched_tokens}>
                  <td>
                    <strong>{token.agent_name}</strong>
                    <p class="al-inline-note">{token.symbol}</p>
                  </td>
                  <td>{String.capitalize(token.phase)}</td>
                  <td>{display_money(token.current_price_usdc)}</td>
                  <td>{display_money(token.implied_market_cap_usdc)}</td>
                  <td><.link navigate={token.detail_url} class="al-ghost">Open</.link></td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section id="profile-staked" class="al-panel al-profile-section" phx-hook="MissionMotion">
          <div class="al-section-head">
            <div>
              <p class="al-kicker">Staked Tokens</p>
              <h3>Your active revenue positions.</h3>
            </div>
          </div>

          <%= if (@snapshot.staked_tokens || []) == [] do %>
            <.empty_state
              title="No staked token positions yet."
              body="Stake from a token detail page after launch if you want your portfolio to show ongoing token exposure and claimable USDC."
            />
          <% else %>
            <div class="al-table-shell">
              <table class="al-table">
                <thead>
                  <tr>
                    <th>Token</th>
                    <th>Staked tokens</th>
                    <th>Stake value</th>
                    <th>Claimable USDC</th>
                    <th>Market cap</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={token <- @snapshot.staked_tokens}>
                    <td>
                      <strong>{token.agent_name}</strong>
                      <p class="al-inline-note">{token.symbol} • {String.capitalize(token.phase)}</p>
                    </td>
                    <td>{token.staked_token_amount}</td>
                    <td>{display_money(token.staked_usdc_value)}</td>
                    <td>{display_money(token.claimable_usdc)}</td>
                    <td>{display_money(token.implied_market_cap_usdc)}</td>
                    <td><.link navigate={token.detail_url} class="al-submit">Manage</.link></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end

  defp load_snapshot(nil),
    do: %{
      status: "pending",
      launched_tokens: [],
      staked_tokens: [],
      refreshed_at: nil,
      next_manual_refresh_at: nil
    }

  defp load_snapshot(current_human) do
    case portfolio_module().get_snapshot(current_human) do
      {:ok, snapshot} ->
        snapshot

      _ ->
        %{
          status: "error",
          launched_tokens: [],
          staked_tokens: [],
          refreshed_at: nil,
          next_manual_refresh_at: nil
        }
    end
  end

  defp reload_snapshot(socket) do
    assign(socket, :snapshot, load_snapshot(socket.assigns.current_human))
  end

  defp refresh_disabled?(nil), do: false

  defp refresh_disabled?(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> DateTime.compare(datetime, DateTime.utc_now()) == :gt
      _ -> false
    end
  end

  defp refresh_label(nil), do: "Refresh portfolio"

  defp refresh_label(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} ->
        remaining = max(DateTime.diff(datetime, DateTime.utc_now(), :second), 0)
        if remaining > 0, do: "Refresh in #{remaining}s", else: "Refresh portfolio"

      _ ->
        "Refresh portfolio"
    end
  end

  defp format_datetime(nil), do: "not yet"

  defp format_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> Calendar.strftime(datetime, "%b %-d, %H:%M:%S UTC")
      _ -> "not yet"
    end
  end

  defp snapshot_copy("running"), do: "The snapshot is rebuilding in the background."
  defp snapshot_copy("ready"), do: "The cached snapshot is ready to browse."
  defp snapshot_copy("error"), do: "The last snapshot failed. Use refresh to try again."

  defp snapshot_copy(_),
    do: "The first snapshot will appear as soon as the background rebuild finishes."

  defp display_money(nil), do: "Unavailable"
  defp display_money(value), do: "#{value} USDC"

  defp portfolio_module do
    :autolaunch
    |> Application.get_env(:profile_live, [])
    |> Keyword.get(:portfolio_module, Portfolio)
  end
end
