defmodule AutolaunchWeb.Components.TopBar do
  @moduledoc false
  use Phoenix.Component

  import AutolaunchWeb.Components.AccountControl

  alias Phoenix.LiveView.JS

  attr :account_control, Autolaunch.AccessContext.AccountControl, required: true
  attr :credits, :map, required: true, doc: "As for `AutolaunchWeb.Components.Credits.button/1`."

  def top_bar(assigns) do
    ~H"""
    <header class="shell-top home-top" id="home-top">
      <%!-- Hidden until opening: before then there is nothing to search. --%>
      <button
        :if={!Autolaunch.Prelaunch.read_only?()}
        type="button"
        id="home-search"
        class="home-search"
        data-open-search
        aria-haspopup="dialog"
        aria-controls="search-dialog"
      >
        <svg
          viewBox="0 0 24 24"
          width="20"
          height="20"
          fill="none"
          stroke="currentColor"
          stroke-width="1.5"
          aria-hidden="true"
        ><circle cx="10.5" cy="10.5" r="6.5" /><path d="m16 16 5 5" /></svg>
        <span class="home-search__prompt">Search coins, stocks, creators and addresses…</span>
        <kbd class="home-search__shortcut" aria-hidden="true">⌘ K</kbd>
      </button>
      <AutolaunchWeb.Components.RegentLinks.header_links>
        <:trail><.theme_toggle /></:trail>
      </AutolaunchWeb.Components.RegentLinks.header_links>
      <div class="home-top__actions">
        <AutolaunchWeb.Components.Credits.button credits={@credits} />
        <.account_control account_control={@account_control} />
        <AutolaunchWeb.Components.SidePanel.button account_control={@account_control} />
      </div>
    </header>
    """
  end

  @doc """
  The badge naming how many tools the site offers agents in the browser. It
  opens a window listing them, with a line on what WebMCP is and a prompt to
  copy for the person's agent. The browser opens the window
  (`assets/js/shell_panels.ts`), so it works on every page, LiveView or not.
  """
  def webmcp_badge(assigns) do
    tools =
      Enum.filter(AutolaunchWeb.PublicDocuments.capabilities()["tools"], &(&1["scope"] == "site"))

    assigns =
      assign(assigns,
        tools: tools,
        host: AutolaunchWeb.Endpoint.host(),
        prompt: agent_prompt()
      )

    ~H"""
    <div class="shell-tools">
      <Regent.HolographicCard.card
        id="shell-webmcp-badge"
        class="shell-tools__badge"
        phx-hook="HolographicCard"
        data-webmcp-badge
        data-holo-crown="false"
        data-holo-tilt="0"
      >
        <button
          id="shell-webmcp-button"
          class="shell-tools__open"
          type="button"
          aria-haspopup="dialog"
          aria-controls="shell-webmcp"
        >
          {length(@tools)} WebMCP Tools Available
        </button>
      </Regent.HolographicCard.card>
      <dialog
        id="shell-webmcp"
        class="shell-webmcp"
        aria-labelledby="shell-webmcp-title"
        phx-mounted={JS.ignore_attributes(["open"])}
      >
        <header class="shell-webmcp__head">
          <h2 id="shell-webmcp-title">{@host} : {length(@tools)} WebMCP Tools</h2>
          <a href="/agents.md" class="shell-webmcp__link" target="_blank" rel="noopener noreferrer">
            Open agents.md
            <span aria-hidden="true">↗</span><span class="visually-hidden">, opens in a new tab</span>
          </a>
          <form method="dialog">
            <button type="submit" class="shell-webmcp__close" aria-label="Close">
              <svg viewBox="0 0 16 16" aria-hidden="true">
                <path d="M3 3l10 10M13 3L3 13" fill="none" stroke="currentColor" stroke-width="1.5" />
              </svg>
            </button>
          </form>
        </header>
        <div class="shell-webmcp__body">
          <p class="shell-webmcp__about">
            WebMCP lets an AI agent in your browser use this site's tools directly: open {@host} in a browser that supports it, and your agent can read auctions and tokens for you, and your bids once it is paired with your account.
          </p>
          <section class="shell-webmcp__prompt" aria-labelledby="shell-webmcp-prompt-title">
            <h3 id="shell-webmcp-prompt-title">Prompt for your agent</h3>
            <p id="shell-webmcp-prompt-text">{@prompt}</p>
            <Regent.Primitives.copy_button
              id="shell-webmcp-copy"
              target="shell-webmcp-prompt-text"
              variant="secondary"
            >
              Copy prompt
            </Regent.Primitives.copy_button>
          </section>
          <ol class="shell-webmcp__list" aria-label="Tools">
            <li :for={tool <- @tools} class="shell-webmcp__tool">
              <h3>{tool["title"]}</h3>
              <code>{tool["name"]}</code>
            </li>
          </ol>
        </div>
      </dialog>
    </div>
    """
  end

  defp agent_prompt do
    "Read #{AutolaunchWeb.PublicDocuments.url("/skill.md")} and follow it. " <>
      "Use #{AutolaunchWeb.Endpoint.host()}'s WebMCP tools in my browser to research " <>
      "auctions and tokens and watch my bids; where they aren't available, use the " <>
      "Regents CLI instead. Never sign or send a transaction for me."
  end

  # The switch names the theme showing by itself, from the page's theme or the
  # device's setting, so the server passes no theme. The browser owns the press:
  # it writes the theme cookie the server reads on the next render and restyles
  # the page, so LiveView leaves the switch alone.
  defp theme_toggle(assigns) do
    ~H"""
    <div id="theme-control" class="theme-control" phx-update="ignore">
      <Regent.ThemeToggle.button id="theme-control-button" data-theme-toggle />
    </div>
    """
  end
end
