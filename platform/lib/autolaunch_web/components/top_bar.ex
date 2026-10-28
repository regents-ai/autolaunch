defmodule AutolaunchWeb.Components.TopBar do
  @moduledoc false
  use Phoenix.Component

  import AutolaunchWeb.Components.AccountControl

  alias AutolaunchWeb.Components.AgentTools
  alias Phoenix.LiveView.JS

  attr :account_control, Autolaunch.AccessContext.AccountControl, required: true
  attr :credits, :map, required: true, doc: "As for `AutolaunchWeb.Components.Credits.button/1`."

  def top_bar(assigns) do
    ~H"""
    <header class="shell-top home-top" id="home-top">
      <%!-- As in the template's shell, the bar starts with the mark and the site's
           name in the pixel face, beside search. On a phone it keeps only the mark,
           then Menu, which opens the rail folded into a drawer. --%>
      <a id="shell-brand" class="shell-brand" href="/" aria-label="Autolaunch home">
        <svg viewBox="0 0 512 512" aria-hidden="true">
          <rect width="512" height="512" fill="#000000" />
          <g fill="#FF5B19">
            <rect :for={{x, y} <- mark_blocks()} x={x} y={y} width="64" height="64" />
          </g>
        </svg>
        <span class="shell-brand__name">Autolaunch</span>
      </a>
      <Regent.Primitives.button
        variant="quiet"
        id="mobile-menu-button"
        class="mobile-menu-button"
        type="button"
        aria-controls="shell-drawer"
        aria-expanded="false"
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        Menu
      </Regent.Primitives.button>
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
        <span class="home-search__prompt">Search</span>
        <kbd class="home-search__shortcut" aria-hidden="true">⌘ K</kbd>
      </button>
      <AutolaunchWeb.Components.RegentLinks.header_links>
        <:trail><.theme_toggle id="theme-control" /></:trail>
      </AutolaunchWeb.Components.RegentLinks.header_links>
      <div class="home-top__actions">
        <.apps_menu />
        <AutolaunchWeb.Components.Credits.button id="shell-credits-button" credits={@credits} />
        <.account_control account_control={@account_control} />
        <AutolaunchWeb.Components.SidePanel.button account_control={@account_control} />
      </div>
    </header>
    """
  end

  @doc """
  The list of tools agents see in the browser: the template's `AgentTools`
  dialog, opening with a line on what WebMCP is and a prompt to copy for the
  person's agent. Its buttons are in the footer and on the developer guide;
  the browser opens and closes it (`assets/js/agent_tools.ts`), so it works
  on every page, LiveView or not.
  """
  def webmcp_tools(assigns) do
    assigns = assign(assigns, host: AutolaunchWeb.Endpoint.host(), prompt: agent_prompt())

    ~H"""
    <div class="shell-tools">
      <AgentTools.dialog id="shell-agent-tools">
        <:intro>
          <p class="code-card__note">
            WebMCP lets an AI agent in your browser use this site's tools directly: open {@host} in a browser that supports it, and your agent can read auctions and tokens for you, and your bids once it is paired with your account.
          </p>
          <section class="agent-tools__prompt" aria-labelledby="shell-agent-tools-prompt-title">
            <h3 id="shell-agent-tools-prompt-title">Prompt for your agent</h3>
            <p id="shell-agent-tools-prompt-text">{@prompt}</p>
            <Regent.Primitives.copy_button
              id="shell-agent-tools-prompt-copy"
              target="shell-agent-tools-prompt-text"
              variant="secondary"
            >
              Copy prompt
            </Regent.Primitives.copy_button>
          </section>
        </:intro>
      </AgentTools.dialog>
    </div>
    """
  end

  defp agent_prompt do
    "Read #{AutolaunchWeb.PublicDocuments.url("/skill.md")} and follow it. " <>
      "Use #{AutolaunchWeb.Endpoint.host()}'s WebMCP tools in my browser to research " <>
      "auctions and tokens and watch my bids; where they aren't available, use the " <>
      "Regents CLI instead. Never sign or send a transaction for me."
  end

  # The other Regents Products, each shown with the crown in its own pair of
  # brand colours, as the template's menu has them, less this site.
  @regents_apps [
    %{name: "Patchbay", url: "https://patchbay.help", tone: "patchbay"},
    %{name: "Keyfleet", url: "https://keyfleet.ai", tone: "keyfleet"},
    %{name: "Techtree", url: "https://techtree.sh", tone: "techtree"},
    %{name: "$REGENT Staking", url: "https://regents.sh/stake", tone: "protocol"}
  ]

  # The template's Regents Products menu. The browser opens and closes the panel
  # itself (`popover`), so it closes on Escape or a press anywhere else, and a
  # page update never shuts it.
  defp apps_menu(assigns) do
    assigns = assign(assigns, :apps, @regents_apps)

    ~H"""
    <button
      id="shell-apps-button"
      class="shell-tool"
      type="button"
      popovertarget="shell-apps"
      aria-label="Regents Products"
    >
      <svg class="shell-icon shell-icon--apps" viewBox="0 0 24 24" aria-hidden="true">
        <g fill="currentColor">
          <rect :for={{x, y} <- nine_dots()} x={x} y={y} width="4.5" height="4.5" />
        </g>
      </svg>
      <span class="shell-tool__tip" aria-hidden="true">Regents Products</span>
    </button>
    <nav id="shell-apps" class="shell-apps" popover aria-labelledby="shell-apps-title">
      <h2 id="shell-apps-title">Regents Products</h2>
      <ul>
        <li :for={app <- @apps}>
          <a href={app.url} target="_blank" rel="noopener">
            <span class="shell-apps__tile" data-tone={app.tone}><.crown /></span>
            <span>{app.name}</span>
          </a>
        </li>
      </ul>
    </nav>
    """
  end

  # The Regents crown: thirteen blocks, drawn in the current text colour.
  defp crown(assigns) do
    ~H"""
    <svg class="shell-apps__crown" viewBox="31 46 178 106" fill="currentColor" aria-hidden="true">
      <rect :for={{x, y} <- crown_blocks()} x={x} y={y} width="34" height="34" />
    </svg>
    """
  end

  defp nine_dots, do: for(y <- [1.5, 9.75, 18], x <- [1.5, 9.75, 18], do: {x, y})

  # The site's mark, drawn as its favicon is: the crown's thirteen blocks on black.
  defp mark_blocks do
    top = for x <- [76.8, 224, 371.2], do: {x, 150.4}
    rows = for y <- [224, 297.6], x <- [76.8, 150.4, 224, 297.6, 371.2], do: {x, y}
    top ++ rows
  end

  defp crown_blocks do
    top = for x <- [31, 103, 175], do: {x, 46}
    rows = for y <- [82, 118], x <- [31, 67, 103, 139, 175], do: {x, y}
    top ++ rows
  end

  attr :id, :string, required: true

  @doc """
  The colour theme switch: in the top bar, and on a phone in the footer. It
  names the theme showing by itself, from the page's theme or the device's
  setting, so the server passes no theme. The browser owns the press: it writes
  the theme cookie the server reads on the next render and restyles the page,
  so LiveView leaves the switch alone.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div id={@id} class="theme-control" phx-update="ignore">
      <Regent.ThemeToggle.button id={"#{@id}-button"} data-theme-toggle />
    </div>
    """
  end
end
