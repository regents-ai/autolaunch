defmodule AutolaunchWeb.Components.RegentLinks do
  @moduledoc false
  use Phoenix.Component

  alias AutolaunchWeb.Components.TokenLinks

  def header_links(assigns) do
    assigns = assign(assigns, :local_lab?, Autolaunch.Lab.enabled?())

    ~H"""
    <div class="regent-header-links">
      <details id="header-regent-menu" class="regent-token-menu" data-regent-token-menu>
        <summary aria-label="$REGENT links"><.source_icon kind={:regent} /></summary>
        <div class="regent-token-menu__panel">
          <nav class="regent-token-menu__content" aria-label="$REGENT">
            <p>$REGENT</p>
            <a
              id="regent-buy"
              class="rg-button regent-token-menu__link"
              href={TokenLinks.buy()}
              target="_blank"
              rel="noopener noreferrer"
            >Buy on Uniswap</a>
            <a
              id="regent-chart"
              class="rg-button regent-token-menu__link"
              href={TokenLinks.chart()}
              target="_blank"
              rel="noopener noreferrer"
            >View Chart</a>
            <p :if={@local_lab?} class="regent-token-menu__note">
              Public Base mainnet, not this fork’s test REGENT.
            </p>
          </nav>
        </div>
      </details>
      <.social_links />
    </div>
    """
  end

  def social_links(assigns) do
    ~H"""
    <nav class="regent-social-links" aria-label="Regents social links">
      <a href="https://x.com/regents_sh" target="_blank" rel="noopener noreferrer" aria-label="Regents on X">
        <.source_icon kind={:x} />
      </a>
      <a href="https://github.com/regents-ai" target="_blank" rel="noopener noreferrer" aria-label="Regents on GitHub">
        <.source_icon kind={:github} />
      </a>
    </nav>
    """
  end

  # Same icon geometry as the Regents homepage.
  defp source_icon(%{kind: :regent} = assigns) do
    ~H"""
    <svg viewBox="31 46 178 106" fill="currentColor" aria-hidden="true">
      <rect :for={x <- [31, 103, 175]} x={x} y="46" width="34" height="34" />
      <rect :for={x <- [31, 67, 103, 139, 175]} x={x} y="82" width="34" height="34" />
      <rect :for={x <- [31, 67, 103, 139, 175]} x={x} y="118" width="34" height="34" />
    </svg>
    """
  end

  defp source_icon(%{kind: :x} = assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z" />
    </svg>
    """
  end

  defp source_icon(%{kind: :github} = assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12" />
    </svg>
    """
  end
end
