defmodule AutolaunchWeb.Components.RegentLinks do
  @moduledoc false
  use Phoenix.Component

  import AutolaunchWeb.Components.LinkIcon

  alias AutolaunchWeb.Components.TokenLinks

  slot :lead, doc: "what comes first in the row, before Buy $REGENT"

  def header_links(assigns) do
    assigns = assign(assigns, :local_lab?, Autolaunch.Lab.test_chain?())

    ~H"""
    <div class="regent-header-links">
      {render_slot(@lead)}
      <a
        class="rg-button rg-button--primary regent-header-cta"
        href={TokenLinks.buy()}
        target="_blank"
        rel="noopener noreferrer"
      >Buy $REGENT</a>
      <a
        class="rg-button regent-header-cta regent-header-cta--soft"
        href="https://x.com/regents_sh"
        target="_blank"
        rel="noopener noreferrer"
        aria-label="Follow on X"
      ><span class="rg-button__label">Follow on <.link_icon kind={:x} /></span></a>
      <details id="header-regent-menu" class="regent-token-menu" data-regent-token-menu>
        <summary aria-label="$REGENT links"><.source_icon kind={:regent} /></summary>
        <div class="regent-token-menu__panel">
          <nav class="regent-token-menu__content" aria-label="$REGENT">
            <button
              type="button"
              class="regent-token-menu__copy"
              data-regent-copy
              data-copy-address={TokenLinks.address()}
              aria-label="Copy $REGENT contract address"
            >
              <span class="regent-token-menu__copy-label">$REGENT</span>
              <span class="regent-token-menu__copy-icon" aria-hidden="true">
                <span class="regent-token-menu__glyph" data-copy-glyph>
                  <.source_icon kind={:copy} />
                </span>
                <span
                  class="regent-token-menu__glyph regent-token-menu__glyph--check"
                  data-check-glyph
                  hidden
                >
                  <.source_icon kind={:check} />
                </span>
              </span>
              <span class="regent-token-menu__toast" data-copy-toast role="status" aria-live="polite"></span>
            </button>
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
            <a
              id="regent-follow-x"
              class="rg-button regent-token-menu__link regent-token-menu__link--phone"
              href="https://x.com/regents_sh"
              target="_blank"
              rel="noopener noreferrer"
            ><span class="rg-button__label">Follow on <.link_icon kind={:x} /></span></a>
            <p :if={@local_lab?} class="regent-token-menu__note">
              Public Base mainnet, not this fork’s test REGENT.
            </p>
          </nav>
        </div>
      </details>
      <nav class="regent-social-links" aria-label="Regents on GitHub">
        <.github_link />
      </nav>
    </div>
    """
  end

  def social_links(assigns) do
    ~H"""
    <nav class="regent-social-links" aria-label="Regents social links">
      <a
        href="https://x.com/regents_sh"
        target="_blank"
        rel="noopener noreferrer"
        aria-label="Regents on X"
      >
        <.link_icon kind={:x} />
      </a>
      <.github_link />
    </nav>
    """
  end

  defp github_link(assigns) do
    ~H"""
    <a
      href="https://github.com/regents-ai"
      target="_blank"
      rel="noopener noreferrer"
      aria-label="Regents on GitHub"
    >
      <.link_icon kind={:github} />
    </a>
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

  defp source_icon(%{kind: :copy} = assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M16 1H4a2 2 0 0 0-2 2v12h2V3h12V1zm3 4H8a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h11a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2zm0 16H8V7h11v14z" />
    </svg>
    """
  end

  defp source_icon(%{kind: :check} = assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M9 16.17 4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" />
    </svg>
    """
  end
end
