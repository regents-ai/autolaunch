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
    launched_tokens = assigns.snapshot.launched_tokens || []
    staked_tokens = assigns.snapshot.staked_tokens || []
    positions_count = profile_positions_count(launched_tokens, staked_tokens)
    total_value = profile_total_value(assigns.snapshot)
    trust_cards = profile_trust_cards()
    next_steps = profile_next_steps(assigns.snapshot)
    activity_rows = profile_activity_rows(assigns.snapshot)

    assigns =
      assigns
      |> assign(:launched_tokens, launched_tokens)
      |> assign(:staked_tokens, staked_tokens)
      |> assign(:positions_count, positions_count)
      |> assign(:total_value, total_value)
      |> assign(:trust_cards, trust_cards)
      |> assign(:next_steps, next_steps)
      |> assign(:activity_rows, activity_rows)

    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <.profile_styles />

      <section class="al-profile-page">
        <header class="al-profile-header">
          <div class="al-profile-header-copy">
            <p class="al-kicker">Profile</p>
            <h1>Identity and trust</h1>
            <p>
              Keep your wallet, launch history, and trust links in one place so the market pages stay easy to read.
            </p>
          </div>

          <div :if={!is_nil(@current_human)} class="al-profile-header-actions">
            <span class="al-profile-refresh-note">
              Updated {format_datetime(@snapshot.refreshed_at)}
            </span>
            <button
              type="button"
              class="al-submit"
              phx-click="refresh_profile"
              disabled={refresh_disabled?(@snapshot.next_manual_refresh_at)}
            >
              {refresh_label(@snapshot.next_manual_refresh_at)}
            </button>
          </div>
        </header>

        <%= if is_nil(@current_human) do %>
          <.empty_state
            title="Sign in to see your token portfolio."
            body="This workspace is built from the wallets linked to your account."
          />
        <% else %>
          <section id="profile-grid" class="al-profile-grid" phx-hook="MissionMotion">
            <div class="al-profile-main">
              <article class="al-panel al-profile-card al-profile-wallet-card">
                <div class="al-profile-card-head">
                  <div>
                    <p class="al-kicker">Wallet overview</p>
                    <h2>{profile_title(@current_human)}</h2>
                    <p class="al-profile-muted">
                      Joined {joined_label(@current_human)} with {wallet_label(@current_human)} as the primary wallet.
                    </p>
                  </div>
                  <span class="al-profile-chip">{snapshot_status_label(@snapshot.status)}</span>
                </div>

                <div class="al-profile-wallet-metrics">
                  <article>
                    <strong>{wallet_count(@current_human)}</strong>
                    <span>Linked wallets</span>
                  </article>
                  <article>
                    <strong>{display_money(@total_value)}</strong>
                    <span>Tracked value</span>
                  </article>
                  <article>
                    <strong>{@positions_count}</strong>
                    <span>Active positions</span>
                  </article>
                  <article>
                    <strong>{length(@launched_tokens)}</strong>
                    <span>Participated launches</span>
                  </article>
                </div>
              </article>

              <section class="al-profile-verification-grid">
                <article class="al-panel al-profile-card al-profile-verification-card">
                  <div class="al-profile-card-head">
                    <div>
                      <p class="al-kicker">Verification</p>
                      <h3>Keep your public trust details current.</h3>
                    </div>
                    <.link navigate={~p"/agentbook"} class="al-ghost">Open Agentbook</.link>
                  </div>

                  <div class="al-profile-inline-banner">
                    <strong>Profile trust lives here now.</strong>
                    <p>
                      Agentbook, ENS, and X are grouped under Profile so your public identity stays easy to review before launch or bids.
                    </p>
                  </div>

                  <div class="al-profile-mini-actions">
                    <.link navigate={~p"/positions"} class="al-ghost">Open positions</.link>
                    <.link navigate={~p"/auctions"} class="al-ghost">Open auctions</.link>
                  </div>
                </article>

                <article class="al-panel al-profile-card al-profile-signals-card">
                  <div class="al-profile-card-head">
                    <div>
                      <p class="al-kicker">Linked identities</p>
                      <h3>These pages shape what the market sees.</h3>
                    </div>
                  </div>

                  <div class="al-profile-identity-grid">
                    <article :for={card <- @trust_cards} class="al-profile-identity-card">
                      <div class="al-profile-identity-head">
                        <strong>{card.title}</strong>
                        <span class={["al-profile-status-pill", card.tone]}>{card.status}</span>
                      </div>
                      <p>{card.body}</p>
                      <.link navigate={card.href} class={card.primary && "al-submit" || "al-ghost"}>
                        {card.action}
                      </.link>
                    </article>
                  </div>
                </article>
              </section>

              <section class="al-panel al-profile-card al-profile-history-card">
                <div class="al-profile-card-head">
                  <div>
                    <p class="al-kicker">Launch history</p>
                    <h3>Tokens launched or still earning.</h3>
                  </div>
                  <.link navigate={~p"/auctions"} class="al-ghost">View auctions</.link>
                </div>

                <%= if @launched_tokens == [] and @staked_tokens == [] do %>
                  <.empty_state
                    title="No launch history yet."
                    body="Launch a token or stake a position, then come back here to keep the token pages and trust pages close."
                  />
                <% else %>
                  <div class="al-profile-history-shell">
                    <table class="al-profile-history-table">
                      <thead>
                        <tr>
                          <th>Agent / token</th>
                          <th>Status</th>
                          <th>Market cap</th>
                          <th>Token price</th>
                          <th>Action</th>
                        </tr>
                      </thead>
                      <tbody>
                        <tr :for={token <- profile_history_rows(@launched_tokens, @staked_tokens)}>
                          <td>
                            <div class="al-profile-table-token">
                              <strong>{token.agent_name}</strong>
                              <span>{token.symbol}</span>
                            </div>
                          </td>
                          <td><.status_badge status={token.phase} /></td>
                          <td>{display_money(token.implied_market_cap_usdc)}</td>
                          <td>{display_money(profile_price_value(token))}</td>
                          <td>
                            <.link navigate={token.detail_url} class={token.primary_button && "al-submit" || "al-ghost"}>
                              {token.action_label}
                            </.link>
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                <% end %>
              </section>
            </div>

            <aside class="al-profile-rail">
              <section class="al-panel al-profile-card al-profile-side-card">
                <div class="al-profile-card-head">
                  <div>
                    <p class="al-kicker">Next steps</p>
                    <h3>Keep the profile useful.</h3>
                  </div>
                </div>

                <div class="al-profile-next-step-list">
                  <.link
                    :for={step <- @next_steps}
                    navigate={step.href}
                    class="al-profile-next-step"
                  >
                    <div>
                      <strong>{step.title}</strong>
                      <p>{step.body}</p>
                    </div>
                    <span aria-hidden="true">›</span>
                  </.link>
                </div>
              </section>

              <section class="al-panel al-profile-card al-profile-side-card">
                <div class="al-profile-card-head">
                  <div>
                    <p class="al-kicker">Activity summary</p>
                    <h3>What this profile touches right now.</h3>
                  </div>
                </div>

                <dl class="al-profile-activity-list">
                  <div :for={row <- @activity_rows}>
                    <dt>{row.label}</dt>
                    <dd>{row.value}</dd>
                  </div>
                </dl>
              </section>
            </aside>
          </section>
        <% end %>
      </section>

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

  defp snapshot_status_label("running"), do: "Refreshing"
  defp snapshot_status_label("ready"), do: "Active"
  defp snapshot_status_label("error"), do: "Needs retry"
  defp snapshot_status_label(_), do: "Pending"

  defp profile_trust_cards do
    [
      %{
        title: "Agentbook",
        status: "Primary",
        body: "Use this page to verify the human behind an agent before the market sees it.",
        action: "Open Agentbook",
        href: ~p"/agentbook",
        primary: true,
        tone: "is-green"
      },
      %{
        title: "ENS",
        status: "Optional",
        body: "Attach a human-readable name so auction and token pages feel more trustworthy.",
        action: "Link ENS",
        href: ~p"/ens-link",
        primary: false,
        tone: "is-blue"
      },
      %{
        title: "X",
        status: "Optional",
        body:
          "Connect the matching social account so the public identity is easier to recognize.",
        action: "Connect X",
        href: ~p"/x-link",
        primary: false,
        tone: "is-amber"
      }
    ]
  end

  defp profile_next_steps(snapshot) do
    claimable_count =
      snapshot.staked_tokens
      |> List.wrap()
      |> Enum.count(&present_amount?(&1.claimable_usdc))

    base_steps = [
      %{
        title: "Link your ENS name",
        body: "Add a readable name to the profile before the next launch.",
        href: ~p"/ens-link"
      },
      %{
        title: "Connect your X account",
        body: "Add another public signal to the same identity.",
        href: ~p"/x-link"
      },
      %{
        title: "Open positions",
        body: "Review bids, claims, and returns from one desk.",
        href: ~p"/positions"
      }
    ]

    if claimable_count > 0 do
      [
        %{
          title: "Claim ready balances",
          body: "#{claimable_count} token positions have claimable USDC ready now.",
          href: ~p"/positions"
        }
        | base_steps
      ]
      |> Enum.take(3)
    else
      Enum.take(base_steps, 3)
    end
  end

  defp profile_activity_rows(snapshot) do
    launched_tokens = List.wrap(snapshot.launched_tokens)
    staked_tokens = List.wrap(snapshot.staked_tokens)

    [
      %{label: "Auctions joined", value: Integer.to_string(length(launched_tokens))},
      %{
        label: "Total bids",
        value: Integer.to_string(profile_positions_count(launched_tokens, staked_tokens))
      },
      %{label: "Tokens held", value: Integer.to_string(length(staked_tokens))},
      %{label: "Total value", value: display_money(profile_total_value(snapshot))}
    ]
  end

  defp profile_history_rows(launched_tokens, staked_tokens) do
    launched =
      Enum.map(launched_tokens, fn token ->
        Map.merge(token, %{action_label: "Open auction view", primary_button: false})
      end)

    staked =
      Enum.map(staked_tokens, fn token ->
        Map.merge(token, %{action_label: "Open token page", primary_button: true})
      end)

    launched ++ staked
  end

  defp profile_price_value(%{current_price_usdc: value}) when not is_nil(value), do: value
  defp profile_price_value(%{staked_usdc_value: value}) when not is_nil(value), do: value
  defp profile_price_value(_token), do: nil

  defp profile_positions_count(launched_tokens, staked_tokens) do
    Enum.count(launched_tokens) + Enum.count(staked_tokens)
  end

  defp profile_total_value(snapshot) do
    launched_value =
      snapshot.launched_tokens
      |> List.wrap()
      |> Enum.reduce(Decimal.new(0), fn token, acc ->
        add_decimal(acc, token.implied_market_cap_usdc)
      end)

    staked_value =
      snapshot.staked_tokens
      |> List.wrap()
      |> Enum.reduce(Decimal.new(0), fn token, acc ->
        acc
        |> add_decimal(token.staked_usdc_value)
        |> add_decimal(token.claimable_usdc)
      end)

    Decimal.add(launched_value, staked_value)
  end

  defp add_decimal(total, nil), do: total

  defp add_decimal(total, value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> Decimal.add(total, decimal)
      _ -> total
    end
  end

  defp add_decimal(total, value) when is_integer(value),
    do: Decimal.add(total, Decimal.new(value))

  defp add_decimal(total, _value), do: total

  defp present_amount?(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> Decimal.compare(decimal, Decimal.new(0)) == :gt
      _ -> false
    end
  end

  defp present_amount?(_value), do: false

  defp wallet_count(%{wallet_addresses: wallet_addresses}) when is_list(wallet_addresses),
    do: Enum.uniq(wallet_addresses) |> length()

  defp wallet_count(_), do: 1

  defp wallet_label(%{wallet_address: wallet_address}) when is_binary(wallet_address) do
    cond do
      String.length(wallet_address) <= 12 ->
        wallet_address

      true ->
        "#{String.slice(wallet_address, 0, 6)}...#{String.slice(wallet_address, -4, 4)}"
    end
  end

  defp wallet_label(_), do: "Connect wallet"

  defp joined_label(%{inserted_at: %NaiveDateTime{} = inserted_at}) do
    inserted_at
    |> NaiveDateTime.to_date()
    |> Calendar.strftime("%B %-d, %Y")
  end

  defp joined_label(_), do: "recently"

  defp profile_styles(assigns) do
    ~H"""
    <style>
      .al-profile-page {
        display: grid;
        gap: clamp(1rem, 2vw, 1.5rem);
      }

      .al-profile-header,
      .al-profile-card {
        border: 1px solid color-mix(in srgb, var(--al-border) 88%, white 12%);
        background: color-mix(in srgb, var(--al-panel-strong) 94%, white 6%);
        box-shadow: 0 20px 60px -48px rgba(17, 35, 64, 0.2);
      }

      .al-profile-header {
        border-radius: 1.5rem;
        padding: clamp(1.1rem, 2.4vw, 1.45rem);
        display: flex;
        justify-content: space-between;
        align-items: flex-start;
        gap: 1rem;
      }

      .al-profile-header-copy,
      .al-profile-header-actions,
      .al-profile-main,
      .al-profile-rail,
      .al-profile-card,
      .al-profile-next-step-list,
      .al-profile-identity-grid {
        display: grid;
        gap: 0.9rem;
      }

      .al-profile-header-copy h1,
      .al-profile-card h2,
      .al-profile-card h3 {
        margin: 0;
      }

      .al-profile-header-copy h1 {
        font-size: clamp(2rem, 4vw, 3rem);
        line-height: 0.95;
      }

      .al-profile-header-copy p:not(.al-kicker),
      .al-profile-muted,
      .al-profile-identity-card p,
      .al-profile-next-step p {
        margin: 0;
        color: var(--al-muted);
      }

      .al-profile-header-actions {
        justify-items: end;
      }

      .al-profile-refresh-note {
        color: var(--al-muted);
        font-size: 0.9rem;
      }

      .al-profile-grid {
        display: grid;
        gap: 1rem;
        grid-template-columns: minmax(0, 1.6fr) minmax(18rem, 0.7fr);
        align-items: start;
      }

      .al-profile-card {
        border-radius: 1.45rem;
        padding: 1rem 1.1rem;
      }

      .al-profile-card-head {
        display: flex;
        justify-content: space-between;
        align-items: flex-start;
        gap: 0.8rem;
      }

      .al-profile-chip,
      .al-profile-status-pill {
        display: inline-flex;
        align-items: center;
        min-height: 2rem;
        padding: 0.25rem 0.7rem;
        border-radius: 999px;
        font-size: 0.78rem;
        border: 1px solid color-mix(in srgb, var(--al-border) 82%, white 18%);
        background: color-mix(in srgb, var(--al-panel) 82%, white 18%);
      }

      .al-profile-status-pill.is-green {
        background: rgba(22, 163, 74, 0.08);
        color: #15803d;
      }

      .al-profile-status-pill.is-blue {
        background: rgba(37, 99, 235, 0.08);
        color: #1d4ed8;
      }

      .al-profile-status-pill.is-amber {
        background: rgba(217, 119, 6, 0.08);
        color: #b45309;
      }

      .al-profile-wallet-metrics {
        display: grid;
        gap: 0;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        border-top: 1px solid color-mix(in srgb, var(--al-border) 84%, white 16%);
      }

      .al-profile-wallet-metrics article {
        display: grid;
        gap: 0.25rem;
        padding: 1rem 0.6rem 0 0;
      }

      .al-profile-wallet-metrics strong {
        font-family: var(--al-font-display);
        font-size: clamp(1.2rem, 2vw, 1.7rem);
      }

      .al-profile-wallet-metrics span {
        color: var(--al-muted);
        font-size: 0.82rem;
      }

      .al-profile-verification-grid {
        display: grid;
        gap: 1rem;
        grid-template-columns: minmax(0, 1.15fr) minmax(0, 1fr);
      }

      .al-profile-inline-banner {
        border-radius: 1rem;
        padding: 0.95rem 1rem;
        border: 1px solid rgba(34, 197, 94, 0.24);
        background: linear-gradient(135deg, rgba(22, 163, 74, 0.08), rgba(255, 255, 255, 0.68));
        display: grid;
        gap: 0.25rem;
      }

      .al-profile-inline-banner p {
        margin: 0;
        color: var(--al-muted);
      }

      .al-profile-mini-actions {
        display: flex;
        gap: 0.7rem;
        flex-wrap: wrap;
      }

      .al-profile-identity-grid {
        grid-template-columns: repeat(3, minmax(0, 1fr));
      }

      .al-profile-identity-card {
        display: grid;
        gap: 0.7rem;
        padding: 1rem;
        border-radius: 1.15rem;
        border: 1px solid color-mix(in srgb, var(--al-border) 84%, white 16%);
        background: color-mix(in srgb, white 82%, var(--al-panel) 18%);
      }

      .al-profile-identity-head {
        display: flex;
        justify-content: space-between;
        align-items: center;
        gap: 0.5rem;
      }

      .al-profile-history-shell {
        overflow-x: auto;
      }

      .al-profile-history-table {
        width: 100%;
        border-collapse: collapse;
      }

      .al-profile-history-table th,
      .al-profile-history-table td {
        padding: 0.85rem 0.5rem;
        text-align: left;
        border-top: 1px solid color-mix(in srgb, var(--al-border) 82%, white 18%);
      }

      .al-profile-history-table thead th {
        color: var(--al-muted);
        font-size: 0.78rem;
        border-top: none;
      }

      .al-profile-table-token {
        display: grid;
        gap: 0.14rem;
      }

      .al-profile-table-token span {
        color: var(--al-muted);
        font-size: 0.8rem;
      }

      .al-profile-next-step {
        display: flex;
        justify-content: space-between;
        align-items: flex-start;
        gap: 0.8rem;
        padding: 0.95rem 1rem;
        border-radius: 1rem;
        border: 1px solid color-mix(in srgb, var(--al-border) 84%, white 16%);
        text-decoration: none;
        color: var(--al-text);
        background: color-mix(in srgb, white 82%, var(--al-panel) 18%);
      }

      .al-profile-next-step strong {
        display: block;
        margin-bottom: 0.2rem;
      }

      .al-profile-activity-list {
        display: grid;
        gap: 0.8rem;
      }

      .al-profile-activity-list div {
        display: flex;
        justify-content: space-between;
        gap: 1rem;
        padding-bottom: 0.8rem;
        border-bottom: 1px solid color-mix(in srgb, var(--al-border) 82%, white 18%);
      }

      .al-profile-activity-list div:last-child {
        border-bottom: none;
        padding-bottom: 0;
      }

      .al-profile-activity-list dt {
        color: var(--al-muted);
      }

      .al-profile-activity-list dd {
        margin: 0;
      }

      @media (max-width: 1100px) {
        .al-profile-grid,
        .al-profile-verification-grid {
          grid-template-columns: 1fr;
        }

        .al-profile-header {
          flex-direction: column;
        }

        .al-profile-header-actions {
          justify-items: start;
        }
      }

      @media (max-width: 760px) {
        .al-profile-wallet-metrics,
        .al-profile-identity-grid {
          grid-template-columns: 1fr;
        }
      }
    </style>
    """
  end

  defp profile_title(%{display_name: display_name})
       when is_binary(display_name) and display_name != "",
       do: display_name

  defp profile_title(%{wallet_address: wallet_address}) when is_binary(wallet_address),
    do: short_wallet(wallet_address)

  defp profile_title(_), do: "Autolaunch operator"

  defp short_wallet(wallet_address) do
    "#{String.slice(wallet_address, 0, 6)}...#{String.slice(wallet_address, -4, 4)}"
  end

  defp poll_seconds, do: div(@poll_ms, 1_000)

  defp display_money(nil), do: "Unavailable"

  defp display_money(%Decimal{} = value),
    do: "#{Decimal.round(value, 2) |> Decimal.to_string(:normal)} USDC"

  defp display_money(value), do: "#{value} USDC"

  defp portfolio_module do
    :autolaunch
    |> Application.get_env(:profile_live, [])
    |> Keyword.get(:portfolio_module, Portfolio)
  end
end
