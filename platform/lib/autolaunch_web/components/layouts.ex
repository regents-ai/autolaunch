defmodule AutolaunchWeb.Layouts do
  @moduledoc "Root document layout and the product shell."

  use AutolaunchWeb, :html

  import AutolaunchWeb.Components.Rail
  import AutolaunchWeb.Components.TopBar

  alias AutolaunchWeb.Read

  embed_templates("layouts/*")

  @doc """
  The one line every page of a Base-fork site carries: "Local Base fork …" on
  a lab, "Preview on a Base fork …" on a hosted fork preview.
  """
  def lab_notice(assigns) do
    assigns =
      assigns
      |> assign(:sign_in, sign_in_state())
      |> assign(:fork_label, Autolaunch.ChainMode.label())

    ~H"""
    <p :if={Autolaunch.Lab.test_chain?()} class="autolaunch-lab-warning" role="status">
      {@fork_label} · test assets · no mainnet value<span :if={!Autolaunch.Prelaunch.read_only?()}>
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
  The signed-in account, for the side panel's agents; nil signed out, and on a
  page served without LiveView, which cannot hold the list.
  """
  def agents_account(%Phoenix.LiveView.Socket{}, %{principal: {:human, account}}), do: account
  def agents_account(_socket, _access_context), do: nil

  @doc """
  The signed-in account, for the side panel's pairing box; nil signed out, on
  the Account page, which shows its own, and on a page served without LiveView,
  which cannot hold the box.
  """
  def pairing_account(%Phoenix.LiveView.Socket{view: AutolaunchWeb.AccountLive}, _access_context),
    do: nil

  def pairing_account(%Phoenix.LiveView.Socket{}, %{principal: {:human, account}}), do: account
  def pairing_account(_socket, _access_context), do: nil

  @doc """
  The footer of every page, the same on every Regent site: the social links,
  Buy $REGENT, the site's documents and its two plain-text guides for agents,
  which open in the browser's popover from "Agent guide". On a phone, whose top
  bar has no room for them, the footer starts with the `phone` slot: the tools
  agents see and the theme switch, where the template's bottom bar has them.
  """
  slot :phone, doc: "What a phone's footer shows first; a page without the shell leaves it out."
  attr :rest, :global

  def product_links(assigns) do
    ~H"""
    <footer class="regent-footer" {@rest}>
      <div :if={@phone != []} class="regent-footer__phone">{render_slot(@phone)}</div>
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
