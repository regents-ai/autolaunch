defmodule AutolaunchWeb.Layouts do
  @moduledoc "Root document layout and the product shell."

  use AutolaunchWeb, :html

  import AutolaunchWeb.Components.Rail
  import AutolaunchWeb.Components.TopBar

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
      |> assign(:preview?, Autolaunch.ChainMode.fork?())

    ~H"""
    <p :if={Autolaunch.Prelaunch.read_only?()} class="autolaunch-prelaunch-notice" role="status">
      Prelaunch · Read-only preview · Creation, accounts and wallet actions open after contract deployment.
    </p>
    <p :if={Autolaunch.Lab.enabled?()} class="autolaunch-lab-warning" role="status">
      {@fork_label} · test assets · no mainnet value<span :if={!Autolaunch.Prelaunch.read_only?()}><span :if={
        !@preview?
      }> · launches and bids only</span>
      · {@sign_in}</span>
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

  @doc "The minimal Regents Labs footer."
  def product_links(assigns) do
    ~H"""
    <footer class="regent-footer">
      <AutolaunchWeb.Components.RegentLinks.social_links />
      <p>© 2026 Regents Labs</p>
    </footer>
    """
  end
end
