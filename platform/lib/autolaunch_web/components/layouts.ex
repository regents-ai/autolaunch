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

  @doc """
  The signed-in account and its Credits reading, for the header's Credits button
  and the Buy Credits window; nil signed out, and on a page served without
  LiveView, which has no window to open.
  """
  def credits(%Phoenix.LiveView.Socket{}, %{principal: {:human, account}}, %Read{} = read),
    do: %{account: account, read: read}

  def credits(_socket, _access_context, _read), do: nil

  @doc """
  The signed-in account, for the side panel's pairing box; nil signed out, on
  the Account page, which shows its own, and on a page served without LiveView,
  which cannot hold the box.
  """
  def pairing_account(%Phoenix.LiveView.Socket{view: AutolaunchWeb.AccountLive}, _access_context),
    do: nil

  def pairing_account(%Phoenix.LiveView.Socket{}, %{principal: {:human, account}}), do: account
  def pairing_account(_socket, _access_context), do: nil

  @doc "The minimal Regents Labs footer."
  def product_links(assigns) do
    ~H"""
    <footer class="regent-footer">
      <AutolaunchWeb.Components.RegentLinks.social_links />
      <nav class="regent-footer__links" aria-label="About Autolaunch">
        <a
          href={AutolaunchWeb.Components.TokenLinks.buy()}
          target="_blank"
          rel="noopener noreferrer"
        >Buy $REGENT</a>
        <a href="/docs">Docs</a>
        <a href="/about">About</a>
        <a href="/contact">Contact</a>
        <a href="/privacy">Privacy</a>
        <a href="/terms">Terms</a>
      </nav>
      <p>© 2026 Regents Labs</p>
    </footer>
    """
  end
end
