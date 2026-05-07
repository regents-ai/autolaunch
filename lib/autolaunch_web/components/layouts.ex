defmodule AutolaunchWeb.Layouts do
  @moduledoc false
  use AutolaunchWeb, :html

  embed_templates "layouts/*"

  alias AutolaunchWeb.Format
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
      |> assign(:wallet_bridge_config, wallet_bridge_config())
      |> assign(:regent_status, RegentStatus.snapshot(assigns.current_human))
      |> assign(:notification_count, 0)
      |> assign(:command_entries, command_entries())
      |> assign(:docs_href, ~p"/docs")
      |> assign(:terms_href, ~p"/terms")
      |> assign(:privacy_href, ~p"/privacy")

    ~H"""
    <div id="autolaunch-root-shell" class="al-shell-root rg-regent-theme-autolaunch" phx-hook="ShellChrome">
      <div
        id="autolaunch-privy-bridge"
        phx-hook="AutolaunchPrivyBridge"
        phx-update="ignore"
        data-autolaunch-config={@wallet_bridge_config}
      >
      </div>

      <LaunchComponents.welcome_modal />
      <LaunchComponents.wallet_switch_modal wallet_switch={@wallet_switch} />

      <div class="al-shell-frame">
        <aside class="al-shell-sidebar">
          <div class="al-shell-brand-block">
            <.link navigate={~p"/"} class="al-shell-brand">
              <span class="al-shell-brand-logo" aria-hidden="true">
                <img src={~p"/images/autolaunchgreen.png"} alt="" width="58" height="58" />
              </span>
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
              data-nav-section={item.id}
              aria-current={@active_section == item.id && "page"}
            >
              <.shell_icon name={item.icon} class="al-shell-nav-icon" />
              <span>{item.label}</span>
            </.link>
          </nav>
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
                  class="btn btn-ghost btn-circle al-shell-icon-button al-shell-notification-button"
                  aria-label="Notifications"
                  title="Notifications"
                >
                  <span class="indicator">
                    <.shell_icon name="bell" />
                    <span
                      :if={@notification_count > 0}
                      class="indicator-item badge badge-primary badge-xs al-shell-notice-dot"
                    >
                    </span>
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
                id="autolaunch-wallet"
                class="al-shell-wallet"
                phx-hook="AutolaunchWallet"
                data-autolaunch-config={@wallet_bridge_config}
                data-wallet-signed-in={if @current_human, do: "true", else: "false"}
                data-wallet-address={@wallet_address}
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
                      <strong data-wallet-label>{@wallet_label}</strong>
                      <.shell_icon name="chevron-down" class="al-shell-wallet-caret" />
                    </button>

                    <div
                      tabindex="0"
                      class="dropdown-content al-shell-popover menu mt-3 w-80 rounded-box border border-base-300 bg-base-100 p-3 shadow-xl"
                    >
                      <div class="al-shell-wallet-summary">
                        <span class="al-shell-wallet-avatar is-large"></span>
                        <div>
                          <strong data-wallet-label>{@wallet_label}</strong>
                          <p>{@wallet_address}</p>
                        </div>
                      </div>

                      <p
                        class="al-shell-wallet-notice"
                        data-wallet-notice
                        hidden
                      >
                      </p>

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
                          <button type="button" class="text-error" data-wallet-disconnect>
                            <.shell_icon name="logout" class="al-shell-menu-icon" />
                            Disconnect
                          </button>
                        </li>
                      </ul>
                    </div>
                  </div>
                <% else %>
                  <div class="al-shell-wallet-connect">
                    <span class="sr-only" data-wallet-label>Wallet</span>
                    <button type="button" class="btn al-shell-connect-button" data-wallet-connect>
                      Connect wallet
                    </button>
                    <p class="al-shell-wallet-notice" data-wallet-notice hidden></p>
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
                  src={~p"/images/autolaunchgreen.png"}
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
              <.footer_social_links />
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
        <% "staking" -> %>
          <path d="M5 7h14" />
          <path d="M7 7v10a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2V7" />
          <path d="M9 7a3 3 0 0 1 6 0" />
          <path d="M9.5 13h5" />
          <path d="M12 10.5v5" />
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
      %{id: "regent-staking", label: "$REGENT", href: ~p"/regent-staking", icon: "staking"},
      %{id: "profile", label: "Profile", href: ~p"/profile", icon: "profile"},
      %{id: "launch", label: "Launch", href: ~p"/launch", icon: "launch"},
      %{id: "docs", label: "Docs", href: ~p"/docs", icon: "docs"}
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
        label: "$REGENT staking",
        note: "Stake, claim, and review protocol stables",
        href: ~p"/regent-staking",
        mark: "RG",
        search: "regent staking rewards usdc claim emissions"
      },
      %{
        label: "Launch an agent",
        note: "Start with the Regent CLI",
        href: ~p"/launch",
        mark: "LA",
        search: "launch agent regent cli prelaunch"
      },
      %{
        label: "Docs",
        note: "Continuous clearing mechanics and follow-up",
        href: ~p"/docs",
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
        search: "status health readiness cache siwa xmtp database"
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
       when active_view in [
              "home",
              "auctions",
              "positions",
              "regent-staking",
              "profile",
              "launch",
              "docs"
            ] do
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
      "$REGENT Staking" -> "regent-staking"
      "Profile" -> "profile"
      "Launch" -> "launch"
      "Docs" -> "docs"
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
      _ -> Format.short_wallet(Map.get(current_human, :wallet_address)) || "Connected wallet"
    end
  end

  defp wallet_address(nil), do: nil
  defp wallet_address(%{} = current_human), do: Map.get(current_human, :wallet_address)

  defp wallet_explorer_href(%{wallet_address: "0x" <> _ = wallet_address}),
    do: "https://basescan.org/address/#{wallet_address}"

  defp wallet_explorer_href(_current_human), do: nil

  defp privy_app_id do
    Application.get_env(:autolaunch, :privy, [])
    |> Keyword.get(:app_id, "")
  end

  defp wallet_bridge_config do
    Jason.encode!(%{
      privyAppId: privy_app_id(),
      privySession: ~p"/v1/auth/privy/session"
    })
  end

  defp footer_social_links(assigns) do
    ~H"""
    <a
      href="https://x.com/autolaunch_sh"
      target="_blank"
      rel="noreferrer"
      class="al-shell-footer-social-link"
      aria-label="Autolaunch on X"
      title="Autolaunch on X"
    >
      <.x_mark class="al-shell-social-mark" />
    </a>
    <a
      href="https://farcaster.xyz/regent"
      target="_blank"
      rel="noreferrer"
      class="al-shell-footer-social-link"
      aria-label="Regent on Farcaster"
      title="Regent on Farcaster"
    >
      <img src={~p"/images/farcastericon.png"} alt="" class="al-shell-footer-icon-image" />
    </a>
    <a
      href="https://discord.gg/regents"
      target="_blank"
      rel="noreferrer"
      class="al-shell-footer-social-link"
      aria-label="Regents on Discord"
      title="Regents on Discord"
    >
      <.discord_mark class="al-shell-social-mark" />
    </a>
    <a
      href="https://github.com/orgs/regents-ai/repositories"
      target="_blank"
      rel="noreferrer"
      class="al-shell-footer-social-link"
      aria-label="Regents Labs GitHub"
      title="Regents Labs GitHub"
    >
      <.github_mark class="al-shell-social-mark" />
    </a>
    <a
      href="https://www.geckoterminal.com/base/pools/0x4ed3b69ac263ad86482f609b2c2105f64bcfd3a7e02e8e078ec9fec1f0324bed"
      target="_blank"
      rel="noreferrer"
      class="al-shell-footer-social-link"
      aria-label="View $REGENT on GeckoTerminal"
      title="View $REGENT on GeckoTerminal"
    >
      <img src={~p"/images/geckoterminallogo.png"} alt="" class="al-shell-footer-icon-image" />
    </a>
    """
  end

  attr :class, :string, default: nil

  defp x_mark(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true" class={@class}>
      <path d="M18.244 2.25h3.308l-7.227 8.26L23 21.75h-6.828l-5.347-6.79l-5.94 6.79H1.577l7.73-8.835L1 2.25h7.002l4.833 6.133zM17.083 19.77h1.833L7.084 4.126H5.117z" />
    </svg>
    """
  end

  attr :class, :string, default: nil

  defp discord_mark(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true" class={@class}>
      <path d="M20.317 4.37A19.79 19.79 0 0 0 15.43 2.855a13.79 13.79 0 0 0-.66 1.357a18.27 18.27 0 0 0-5.538 0a13.68 13.68 0 0 0-.67-1.357A19.74 19.74 0 0 0 3.678 4.37C.534 9.09-.32 13.693.099 18.23a19.9 19.9 0 0 0 6.06 3.078a14.9 14.9 0 0 0 1.298-2.11a12.92 12.92 0 0 1-2.04-.98c.172-.128.341-.262.505-.4a14.1 14.1 0 0 0 12.163 0c.165.138.334.272.505.4a12.9 12.9 0 0 1-2.042.981a14.2 14.2 0 0 0 1.299 2.109a19.86 19.86 0 0 0 6.061-3.078c.492-5.261-.84-9.821-3.59-13.86ZM8.02 15.33c-1.183 0-2.157-1.085-2.157-2.419s.948-2.419 2.157-2.419c1.219 0 2.175 1.095 2.157 2.419c0 1.334-.948 2.419-2.157 2.419Zm7.974 0c-1.183 0-2.157-1.085-2.157-2.419s.948-2.419 2.157-2.419c1.219 0 2.175 1.095 2.157 2.419c0 1.334-.938 2.419-2.157 2.419Z" />
    </svg>
    """
  end

  attr :class, :string, default: nil

  defp github_mark(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true" class={@class}>
      <path d="M12 2C6.48 2 2 6.58 2 12.22c0 4.5 2.87 8.31 6.84 9.66c.5.1.68-.22.68-.49c0-.24-.01-1.05-.01-1.91c-2.78.62-3.37-1.21-3.37-1.21c-.45-1.19-1.11-1.5-1.11-1.5c-.91-.64.07-.63.07-.63c1 .08 1.53 1.06 1.53 1.06c.9 1.56 2.35 1.11 2.92.85c.09-.67.35-1.11.63-1.37c-2.22-.26-4.56-1.14-4.56-5.08c0-1.12.39-2.04 1.03-2.76c-.1-.26-.45-1.31.1-2.73c0 0 .84-.28 2.75 1.05A9.35 9.35 0 0 1 12 6.84c.85 0 1.71.12 2.51.35c1.91-1.33 2.75-1.05 2.75-1.05c.55 1.42.2 2.47.1 2.73c.64.72 1.03 1.64 1.03 2.76c0 3.95-2.34 4.81-4.58 5.07c.36.32.68.95.68 1.91c0 1.38-.01 2.49-.01 2.83c0 .27.18.59.69.49A10.24 10.24 0 0 0 22 12.22C22 6.58 17.52 2 12 2Z" />
    </svg>
    """
  end
end
