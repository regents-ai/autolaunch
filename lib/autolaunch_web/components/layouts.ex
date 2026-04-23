defmodule AutolaunchWeb.Layouts do
  @moduledoc false
  use AutolaunchWeb, :html

  embed_templates "layouts/*"

  alias AutolaunchWeb.LaunchComponents
  alias AutolaunchWeb.RegentStatus

  attr :current_human, :map, default: nil
  attr :active_view, :string, default: nil
  attr :page_title, :string, default: nil
  attr :wallet_switch, :map, default: nil
  slot :inner_block, required: true

  def app_shell(assigns) do
    assigns =
      assigns
      |> assign(:active_section, active_section(assigns.active_view, assigns.page_title))
      |> assign(:nav_items, nav_items())
      |> assign(:wallet_label, wallet_label(assigns.current_human))
      |> assign(:wallet_address, wallet_address(assigns.current_human))
      |> assign(:wallet_explorer_href, wallet_explorer_href(assigns.current_human))
      |> assign(:regent_status, RegentStatus.snapshot(assigns.current_human))
      |> assign(:command_entries, command_entries())
      |> assign(:docs_href, ~p"/how-auctions-work")
      |> assign(:terms_href, ~p"/terms")
      |> assign(:privacy_href, ~p"/privacy")

    ~H"""
    <div id="autolaunch-root-shell" class="al-shell-root rg-regent-theme-autolaunch" phx-hook="ShellChrome">
      <LaunchComponents.welcome_modal />
      <LaunchComponents.wallet_switch_modal wallet_switch={@wallet_switch} />

      <div class="al-shell-frame">
        <aside class="al-shell-sidebar">
          <div class="al-shell-brand-block">
            <.link navigate={~p"/"} class="al-shell-brand">
              <img
                src="/regent/regent-sigil-preview.svg"
                alt=""
                aria-hidden="true"
                width="44"
                height="44"
              />
              <div class="al-shell-brand-copy">
                <span class="al-shell-brand-name">Autolaunch</span>
                <span class="al-shell-brand-note">Agent markets</span>
              </div>
            </.link>
          </div>

          <nav aria-label="Primary" class="al-shell-nav">
            <.link
              :for={item <- @nav_items}
              navigate={item.href}
              class={["al-shell-nav-link", @active_section == item.id && "is-active"]}
            >
              <.shell_icon name={item.icon} class="al-shell-nav-icon" />
              <span>{item.label}</span>
            </.link>
          </nav>

          <div class="al-shell-sidebar-foot">
            <div class="al-shell-network-card">
              <div class="al-shell-network-head">
                <span class="al-shell-network-kicker">Network</span>
                <.shell_icon name="chevron-down" class="al-shell-network-caret" />
              </div>
              <div class="al-shell-network-row">
                <span class="al-shell-network-dot"></span>
                <div>
                  <strong>Base mainnet</strong>
                  <p>All launch actions stay on Base.</p>
                </div>
              </div>
            </div>
          </div>
        </aside>

        <div class="al-shell-main">
          <header class="al-shell-header">
            <form class="al-shell-search" role="search" method="get" action={~p"/auctions"} data-command-open>
              <label for="autolaunch-global-search" class="sr-only">Search</label>
              <span class="al-shell-search-icon" aria-hidden="true">
                <.shell_icon name="search" />
              </span>
              <input
                id="autolaunch-global-search"
                name="search"
                type="search"
                placeholder="Search tokens, auctions, docs..."
                autocomplete="off"
                aria-keyshortcuts="Meta+K Control+K"
                readonly
                data-command-open
              />
              <span class="al-shell-search-shortcut" aria-hidden="true">
                <kbd class="kbd kbd-sm">⌘</kbd>
                <kbd class="kbd kbd-sm">K</kbd>
              </span>
            </form>

            <div class="al-shell-header-actions">
              <div
                class={["al-shell-regent-pill", "is-#{@regent_status.tone}"]}
                aria-label="Regent staking status"
              >
                <strong>{@regent_status.headline}</strong>
                <p>{@regent_status.detail}</p>
              </div>

              <button
                type="button"
                class="btn btn-ghost btn-circle al-shell-icon-button"
                data-theme-action="toggle"
                aria-label="Toggle light and dark mode"
                title="Toggle light and dark mode"
              >
                <.shell_icon name="theme" />
              </button>

              <div class="dropdown dropdown-end">
                <button
                  type="button"
                  tabindex="0"
                  class="btn btn-ghost btn-circle al-shell-icon-button"
                  aria-label="Notifications"
                  title="Notifications"
                >
                  <span class="indicator">
                    <.shell_icon name="bell" />
                    <span class="indicator-item badge badge-primary badge-xs al-shell-notice-dot"></span>
                  </span>
                </button>
                <div
                  tabindex="0"
                  class="dropdown-content al-shell-popover menu menu-sm mt-3 w-72 rounded-box border border-base-300 bg-base-100 p-3 shadow-xl"
                >
                  <span class="menu-title px-0 text-xs uppercase tracking-[0.18em]">Notifications</span>
                  <div class="al-shell-popover-note">
                    <strong>Nothing needs your attention right now.</strong>
                    <p>New launch, bid, and claim updates will show up here.</p>
                  </div>
                </div>
              </div>

              <div
                id="privy-auth"
                class="al-shell-wallet"
                phx-hook="PrivyAuth"
                data-privy-app-id={privy_app_id()}
                data-session-state={if @current_human, do: "present", else: "missing"}
              >
                <%= if @current_human do %>
                  <div class="dropdown dropdown-end">
                    <button
                      type="button"
                      tabindex="0"
                      class="btn al-shell-wallet-trigger"
                      aria-label="Wallet menu"
                    >
                      <span class="al-shell-wallet-avatar"></span>
                      <strong data-privy-state>{@wallet_label}</strong>
                      <.shell_icon name="chevron-down" class="al-shell-wallet-caret" />
                    </button>

                    <div
                      tabindex="0"
                      class="dropdown-content al-shell-popover menu mt-3 w-80 rounded-box border border-base-300 bg-base-100 p-3 shadow-xl"
                    >
                      <div class="al-shell-wallet-summary">
                        <span class="al-shell-wallet-avatar is-large"></span>
                        <div>
                          <strong>{@wallet_label}</strong>
                          <p>{@wallet_address}</p>
                        </div>
                      </div>

                      <ul class="menu menu-sm gap-1 px-0">
                        <li :if={@wallet_explorer_href}>
                          <a href={@wallet_explorer_href} target="_blank" rel="noreferrer">
                            <.shell_icon name="arrow-up-right" class="al-shell-menu-icon" />
                            View on explorer
                          </a>
                        </li>
                        <li :if={@wallet_address}>
                          <button
                            type="button"
                            data-copy-value={@wallet_address}
                            data-copy-label="Copy address"
                          >
                            <.shell_icon name="copy" class="al-shell-menu-icon" />
                            Copy address
                          </button>
                        </li>
                        <li>
                          <.link navigate={~p"/profile"}>
                            <.shell_icon name="profile" class="al-shell-menu-icon" />
                            Profile
                          </.link>
                        </li>
                        <li>
                          <.link navigate={~p"/positions"}>
                            <.shell_icon name="positions" class="al-shell-menu-icon" />
                            Positions
                          </.link>
                        </li>
                        <li class="mt-2 border-t border-base-300 pt-2">
                          <button type="button" class="text-error" data-privy-action="toggle">
                            <.shell_icon name="logout" class="al-shell-menu-icon" />
                            Disconnect
                          </button>
                        </li>
                      </ul>
                    </div>
                  </div>
                <% else %>
                  <div class="al-shell-wallet-connect">
                    <span class="sr-only" data-privy-state>guest</span>
                    <button type="button" class="btn al-shell-connect-button" data-privy-action="toggle">
                      Connect wallet
                    </button>
                  </div>
                <% end %>
              </div>
            </div>
          </header>

          <main class="al-shell-content">
            <div class="al-shell-route-host">
              {render_slot(@inner_block)}
            </div>
          </main>

          <footer class="al-shell-footer">
            <div class="al-shell-footer-brand">
              <.link navigate={~p"/"} class="al-shell-footer-logo">
                <img
                  src="/regent/regent-sigil-preview.svg"
                  alt=""
                  aria-hidden="true"
                  width="38"
                  height="38"
                />
                <strong>Autolaunch</strong>
              </.link>
              <p>The launchpad for tokenized AI agents and onchain economies.</p>
            </div>

            <nav class="al-shell-footer-links" aria-label="Footer">
              <.link navigate={@docs_href}>Docs</.link>
              <.link navigate={@terms_href}>Terms</.link>
              <.link navigate={@privacy_href}>Privacy</.link>
            </nav>

            <nav class="al-shell-footer-social" aria-label="Social">
              <a href="https://x.com/regents_sh" target="_blank" rel="noreferrer">X</a>
              <a href="https://discord.gg/regents" target="_blank" rel="noreferrer">Discord</a>
              <a href="https://github.com/regents-ai/autolaunch" target="_blank" rel="noreferrer">
                GitHub
              </a>
            </nav>
          </footer>
        </div>
      </div>

      <div
        id="autolaunch-command-palette"
        class="al-command-palette"
        data-command-palette
        hidden
      >
        <button type="button" class="al-command-scrim" data-command-close aria-label="Close search">
        </button>
        <section class="al-command-dialog" role="dialog" aria-modal="true" aria-label="Search Autolaunch">
          <div class="al-command-search-row">
            <.shell_icon name="search" class="al-command-search-icon" />
            <input
              id="autolaunch-command-input"
              type="search"
              placeholder="Find auctions, positions, docs, and account actions"
              autocomplete="off"
              data-command-input
            />
            <button type="button" data-command-close>Close</button>
          </div>

          <div class="al-command-list" data-command-list>
            <a
              :for={entry <- @command_entries}
              href={entry.href}
              class="al-command-item"
              data-command-item
              data-command-search={entry.search}
            >
              <span class="al-command-mark">{entry.mark}</span>
              <span>
                <strong>{entry.label}</strong>
                <small>{entry.note}</small>
              </span>
            </a>

            <a
              href={~p"/auctions"}
              class="al-command-item"
              data-command-query-action
              data-command-query-template={~p"/auctions?#{%{search: "__QUERY__"}}"}
              hidden
            >
              <span class="al-command-mark">AU</span>
              <span>
                <strong data-command-query-label="Search auctions"></strong>
                <small>Match token, agent, symbol, or ENS</small>
              </span>
            </a>

            <a
              href={~p"/positions"}
              class="al-command-item"
              data-command-query-action
              data-command-query-template={~p"/positions?#{%{search: "__QUERY__"}}"}
              hidden
            >
              <span class="al-command-mark">PO</span>
              <span>
                <strong data-command-query-label="Search positions"></strong>
                <small>Filter bids and claimable balances</small>
              </span>
            </a>

            <p class="al-command-empty" data-command-empty hidden>No matching commands.</p>
          </div>
        </section>
      </div>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :class, :string, default: nil

  def shell_icon(assigns) do
    ~H"""
    <svg
      class={@class}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <%= case @name do %>
        <% "home" -> %>
          <path d="M3 10.5L12 3l9 7.5" />
          <path d="M5.5 9.5V21h13V9.5" />
        <% "auctions" -> %>
          <path d="M4 7h10" />
          <path d="M10 7l6 6" />
          <path d="M7 10l7 7" />
          <path d="M13.5 13.5l6.5-6.5" />
          <circle cx="6.5" cy="6.5" r="2.5" />
          <circle cx="17.5" cy="17.5" r="2.5" />
        <% "positions" -> %>
          <path d="M5 4v16" />
          <path d="M5 12h14" />
          <path d="M12 12a7 7 0 0 1 7-7" />
        <% "profile" -> %>
          <circle cx="12" cy="8" r="3.5" />
          <path d="M5 20a7 7 0 0 1 14 0" />
        <% "launch" -> %>
          <path d="M5 19c2.5-1.2 4.2-2.9 5-5.2" />
          <path d="M14 10l5-5" />
          <path d="M14 5l5 5" />
          <path d="M9 15l-4 4" />
          <path d="M9 8.5c1.5-3.7 5.2-5.7 10-5.5c.2 4.8-1.8 8.5-5.5 10" />
        <% "docs" -> %>
          <path d="M6 4.5h12a2 2 0 0 1 2 2V19.5H8a2 2 0 0 0-2 2" />
          <path d="M6 4.5v17" />
        <% "search" -> %>
          <circle cx="11" cy="11" r="6.5" />
          <path d="M16 16l4.5 4.5" />
        <% "theme" -> %>
          <circle cx="12" cy="12" r="4.25" />
          <path d="M12 2.5v2.25" />
          <path d="M12 19.25v2.25" />
          <path d="M21.5 12h-2.25" />
          <path d="M4.75 12H2.5" />
          <path d="M18.72 5.28l-1.59 1.59" />
          <path d="M6.87 17.13l-1.59 1.59" />
          <path d="M18.72 18.72l-1.59-1.59" />
          <path d="M6.87 6.87L5.28 5.28" />
        <% "bell" -> %>
          <path d="M15 18H9" />
          <path d="M18 16H6l1.3-1.8V10a4.7 4.7 0 1 1 9.4 0v4.2Z" />
        <% "chevron-down" -> %>
          <path d="M6.5 9.5L12 15l5.5-5.5" />
        <% "copy" -> %>
          <rect x="9" y="9" width="9" height="11" rx="2" />
          <path d="M6 15V6a2 2 0 0 1 2-2h7" />
        <% "arrow-up-right" -> %>
          <path d="M8 16L16 8" />
          <path d="M10 8h6v6" />
        <% "logout" -> %>
          <path d="M10 6H7a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h3" />
          <path d="M13 16l4-4-4-4" />
          <path d="M17 12H9" />
        <% _ -> %>
          <circle cx="12" cy="12" r="8" />
      <% end %>
    </svg>
    """
  end

  defp nav_items do
    [
      %{id: "home", label: "Home", href: ~p"/", icon: "home"},
      %{id: "auctions", label: "Auctions", href: ~p"/auctions", icon: "auctions"},
      %{id: "positions", label: "Positions", href: ~p"/positions", icon: "positions"},
      %{id: "profile", label: "Profile", href: ~p"/profile", icon: "profile"},
      %{id: "launch", label: "Launch", href: ~p"/launch", icon: "launch"},
      %{id: "docs", label: "Docs", href: ~p"/how-auctions-work", icon: "docs"}
    ]
  end

  defp command_entries do
    [
      %{
        label: "Open auctions",
        note: "Compare live raises and market pages",
        href: ~p"/auctions",
        mark: "AU",
        search: "auctions markets bids tokens agent symbol ens"
      },
      %{
        label: "Open positions",
        note: "Review bids, claims, and returns",
        href: ~p"/positions",
        mark: "PO",
        search: "positions portfolio bids claims returns wallet"
      },
      %{
        label: "Launch an agent",
        note: "Start with the Regent CLI",
        href: ~p"/launch",
        mark: "LA",
        search: "launch agent regent cli prelaunch"
      },
      %{
        label: "How auctions work",
        note: "Continuous clearing mechanics and follow-up",
        href: ~p"/how-auctions-work",
        mark: "DO",
        search: "docs guide auction continuous clearing mechanics"
      },
      %{
        label: "Open contracts",
        note: "Review deployment and revenue contracts",
        href: ~p"/contracts",
        mark: "CO",
        search: "contracts addresses deployment revenue staking"
      },
      %{
        label: "System status",
        note: "Check launch, cache, auth, and service readiness",
        href: ~p"/status",
        mark: "ST",
        search: "status health readiness cache dragonfly siwa xmtp database"
      },
      %{
        label: "Profile and identity",
        note: "Wallet, ENS, X, and AgentBook links",
        href: ~p"/profile",
        mark: "ID",
        search: "profile identity wallet ens x agentbook"
      }
    ]
  end

  defp active_section(active_view, _page_title)
       when active_view in ["home", "auctions", "positions", "profile", "launch", "docs"] do
    active_view
  end

  defp active_section(active_view, _page_title)
       when active_view in ["agentbook", "ens", "x-link"],
       do: "profile"

  defp active_section(active_view, _page_title)
       when active_view in ["guide", "contracts", "terms", "privacy"],
       do: "docs"

  defp active_section(active_view, _page_title)
       when active_view in ["returns", "auction-detail"],
       do: "auctions"

  defp active_section(_active_view, page_title) when is_binary(page_title) do
    case page_title do
      "Autolaunch" -> "home"
      "Auctions" -> "auctions"
      "Positions" -> "positions"
      "Profile" -> "profile"
      "Launch" -> "launch"
      "How auctions work" -> "docs"
      "Contracts" -> "docs"
      "Terms & Conditions" -> "docs"
      "Privacy Policy" -> "docs"
      "Auction Returns" -> "auctions"
      "Auction Detail" -> "auctions"
      "Trust Check" -> "profile"
      "ENS Link" -> "profile"
      "X Link" -> "profile"
      "Launch Via Agent" -> "launch"
      _ -> nil
    end
  end

  defp active_section(_active_view, _page_title), do: nil

  defp wallet_label(nil), do: "Wallet"

  defp wallet_label(%{} = current_human) do
    case Map.get(current_human, :display_name) do
      value when is_binary(value) and value != "" -> value
      _ -> short_wallet(Map.get(current_human, :wallet_address)) || "Connected wallet"
    end
  end

  defp wallet_address(nil), do: nil
  defp wallet_address(%{} = current_human), do: Map.get(current_human, :wallet_address)

  defp wallet_explorer_href(%{wallet_address: "0x" <> _ = wallet_address}),
    do: "https://basescan.org/address/#{wallet_address}"

  defp wallet_explorer_href(_current_human), do: nil

  defp short_wallet(nil), do: nil

  defp short_wallet("0x" <> rest = wallet) when byte_size(rest) > 10 do
    wallet
    |> String.slice(0, 6)
    |> Kernel.<>("..." <> String.slice(wallet, -4, 4))
  end

  defp short_wallet(wallet), do: wallet

  defp privy_app_id do
    Application.get_env(:autolaunch, :privy, [])
    |> Keyword.get(:app_id, "")
  end
end
