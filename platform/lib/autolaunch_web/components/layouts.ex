defmodule AutolaunchWeb.Layouts do
  @moduledoc "Root document layout and the product shell."

  use AutolaunchWeb, :html

  import AutolaunchWeb.Components.Rail
  import AutolaunchWeb.Components.TopBar

  embed_templates("layouts/*")

  @doc "The one line every page of a local Base-fork site carries."
  def lab_notice(assigns) do
    assigns = assign(assigns, :sign_in, sign_in_state())

    ~H"""
    <p :if={Autolaunch.Prelaunch.read_only?()} class="autolaunch-prelaunch-notice" role="status">
      Prelaunch · Read-only preview · Creation, accounts and wallet actions open after contract deployment.
    </p>
    <p :if={Autolaunch.Lab.enabled?()} class="autolaunch-lab-warning" role="status">
      Local Base fork · test assets · no mainnet value<span :if={!Autolaunch.Prelaunch.read_only?()}> · launches and bids only · {@sign_in}</span>
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

  @doc "Product and source discovery without loading a browser integration."
  def product_links(assigns) do
    ~H"""
    <footer aria-label="Project links" class="product-links">
      <a href="https://github.com/regents-ai/autolaunch" rel="noopener noreferrer">Star on GitHub</a>
      <a href="/llms.txt">For agents</a>
      <Regent.Primitives.disclosure id="product-related-links" summary="Regents Labs">
        <nav aria-label="Related products" class="product-links__related">
          <a href="https://regents.sh">Regents</a>
          <a href="https://patchbay.help">Patchbay</a>
          <a href="https://techtree.sh">Techtree</a>
        </nav>
      </Regent.Primitives.disclosure>
    </footer>
    """
  end
end
