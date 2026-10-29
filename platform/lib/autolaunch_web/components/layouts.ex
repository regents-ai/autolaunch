defmodule AutolaunchWeb.Layouts do
  @moduledoc "Root document layout and the product shell."

  use AutolaunchWeb, :html

  import AutolaunchWeb.Components.Rail
  import AutolaunchWeb.Components.TopBar

  alias AutolaunchWeb.Read

  embed_templates("layouts/*")

  @doc """
  The one line every page of a lab site carries, "Local Base fork · test assets
  · no mainnet value", at the top of the screen above the header.
  """
  def lab_notice(assigns) do
    assigns = assign(assigns, sign_in: sign_in_state(), open: !Autolaunch.Prelaunch.read_only?())

    ~H"""
    <p :if={Autolaunch.Lab.test_chain?()} class="autolaunch-lab-warning" role="status">
      {Autolaunch.Lab.label()} · test assets · no mainnet value<span :if={@open}>
        · {@sign_in}
      </span>
    </p>
    """
  end

  # Only the production verifier admits a real Privy sign-in; the fixture
  # verifier has no interactive login at all.
  defp sign_in_state do
    if Application.get_env(:autolaunch, :privy_verifier, Autolaunch.Privy) == Autolaunch.Privy,
      do: "sign in with Privy",
      else: "sign-in unavailable"
  end

  attr :href, :string, required: true, doc: "the page's own address with its query"

  @doc """
  What a page shows while the database could not be reached to read the
  person's sign-in: a short line and a link that loads the same page again.
  The person stays signed in.
  """
  def sign_in_unread(assigns) do
    ~H"""
    <section id="sign-in-unread" class="autolaunch-empty" role="alert">
      <p>Something didn’t load.</p>
      <a href={@href} class="rg-button rg-button--primary">
        <span class="rg-button__label">Try again</span>
      </a>
    </section>
    """
  end

  @doc """
  The signed-in account and its Credits reading, for the header's Credits button
  and the Buy Credits window; nil signed out, and on a page served without
  LiveView, which has no window to open.
  """
  def credits(%Phoenix.LiveView.Socket{}, %{principal: {:human, account}}, %Read{} = read),
    do: %{account: account, read: read}

  def credits(_socket, _access_context, _read), do: nil

  @doc """
  The signed-in account, for the account menu's agents: a LiveView page's access
  context, or the account a page served without LiveView was drawn for
  (`AutolaunchWeb.Plugs.PageShell`); nil signed out.
  """
  def menu_account(%{access_context: %{principal: {:human, account}}}), do: account
  def menu_account(%{current_human_account: %{} = account}), do: account
  def menu_account(_assigns), do: nil

  @doc """
  The footer of every page, the same on every Regent site: the social links,
  Buy $REGENT, the site's documents and its two plain-text guides for agents,
  which open in the browser's popover from "Agent guide", after the `tools`
  slot: the button for the tools agents see, at every width. On a phone, whose
  top bar has no room for it, the footer starts with the `phone` slot: the
  theme switch, where the template's bottom bar has it.
  """
  slot :tools, doc: "The tools agents see; a page without the shell leaves it out."
  slot :phone, doc: "What a phone's footer shows first; a page without the shell leaves it out."
  attr :rest, :global

  def product_links(assigns) do
    ~H"""
    <footer class="regent-footer" {@rest}>
      <div :if={@phone != []} class="regent-footer__phone">{render_slot(@phone)}</div>
      <div :if={@tools != []} class="regent-footer__tools">{render_slot(@tools)}</div>
      <AutolaunchWeb.Components.RegentLinks.social_links />
      <nav class="regent-footer__links" aria-label="About Autolaunch">
        <a
          href={AutolaunchWeb.Components.TokenLinks.buy()}
          target="_blank"
          rel="noopener noreferrer"
        >Buy $REGENT</a>
        <a href={~p"/about"}>About</a>
        <a href={~p"/docs"}>Developer docs</a>
        <span class="rg-tip">
          <button type="button" class="regent-footer__guide" popovertarget="footer-agent-guide">
            Agent guide
          </button>
          <div id="footer-agent-guide" class="rg-tip-body regent-footer__guide-body" popover>
            <p>Give your agent one of these.</p>
            <a href={~p"/agents.md"}>What agents can do here</a>
            <a href={~p"/llms.txt"}>The whole site in brief</a>
          </div>
        </span>
        <a href={~p"/contact"}>Contact</a>
        <span class="regent-footer__legal">
          <a href={~p"/privacy"}>Privacy policy</a>
          <a href={~p"/terms"}>Terms of use</a>
        </span>
      </nav>
      <p>© 2026 Regents Labs</p>
    </footer>
    """
  end
end
