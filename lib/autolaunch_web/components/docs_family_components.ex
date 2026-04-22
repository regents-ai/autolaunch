defmodule AutolaunchWeb.DocsFamilyComponents do
  @moduledoc false

  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: AutolaunchWeb.Endpoint,
    router: AutolaunchWeb.Router,
    statics: AutolaunchWeb.static_paths()

  @cards [
    %{
      key: "guide",
      title: "How auctions work",
      body:
        "Learn the auction lifecycle, bids, settlement, and what happens after a successful sale.",
      href: "/how-auctions-work",
      link_label: "Read guide"
    },
    %{
      key: "contracts",
      title: "Contracts",
      body:
        "Review launch contracts, subject controls, and the actions that still need approval.",
      href: "/contracts",
      link_label: "Read reference"
    },
    %{
      key: "terms",
      title: "Terms",
      body: "Read the terms that govern Autolaunch and how the product may be used.",
      href: "/terms",
      link_label: "Read terms"
    },
    %{
      key: "privacy",
      title: "Privacy",
      body:
        "Understand what information we collect, how we use it, and what stays public onchain.",
      href: "/privacy",
      link_label: "Read policy"
    }
  ]

  attr :active, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, required: true
  attr :eyebrow, :string, default: "Docs"

  def header(assigns) do
    assigns =
      assign(assigns, :cards, Enum.map(@cards, &Map.put(&1, :active, &1.key == assigns.active)))

    ~H"""
    <section class="al-panel al-docs-masthead">
      <div class="al-docs-masthead-copy">
        <p class="al-kicker">{@eyebrow}</p>
        <h2>{@title}</h2>
        <p class="al-subcopy">{@body}</p>
      </div>

      <div class="al-docs-masthead-illustration" aria-hidden="true">
        <div class="al-docs-masthead-book"></div>
      </div>
    </section>

    <div class="al-docs-feature-grid">
      <.link
        :for={card <- @cards}
        navigate={card.href}
        class={["al-panel al-docs-feature-card", card.active && "is-active"]}
      >
        <div class="al-docs-feature-icon" aria-hidden="true">
          {docs_icon(card.key)}
        </div>
        <div class="al-docs-feature-copy">
          <strong>{card.title}</strong>
          <p>{card.body}</p>
        </div>
        <span class="al-docs-feature-link">{card.link_label}</span>
      </.link>
    </div>
    """
  end

  defp docs_icon("guide"), do: "⌘"
  defp docs_icon("contracts"), do: "</>"
  defp docs_icon("terms"), do: "§"
  defp docs_icon("privacy"), do: "◫"
  defp docs_icon(_key), do: "•"
end
