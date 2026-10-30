defmodule AutolaunchWeb.Components.HomeProducts do
  @moduledoc """
  The home page's four products, at the top of the page: covered calls,
  Isolated Exposure to After-hours Stocks, Memestock launches and Revstake
  launches. Each card is a line drawing lit by the shared holographic foil, a
  title and one line; it opens to show a few details and the link to its page
  (`ProductCards` and `ProductFoil` in `assets/js/hooks/product_cards.ts`).

  A product switched off on this site (covered calls, Exposure) has no card, so
  no card links to a page that answers not found. Before launches open, the two
  launch cards keep their place with their button switched off and the reason
  beside it, as the rest of the site does.

  `/stocks` shows the stock products with `open`: the same cards, their details
  and link always shown, with nothing to open.
  """

  use Phoenix.Component

  attr :launches_open, :boolean, required: true

  attr :only, :list,
    default: ~w(calls after-hours memestock revstake),
    doc: "product ids, in order"

  attr :open, :boolean, default: false

  def product_cards(assigns) do
    assigns = assign(assigns, :products, products(assigns.only))

    ~H"""
    <section
      id="home-products"
      class={["home-products", @open && "home-products--open"]}
      aria-label="Products"
      phx-hook={!@open && "ProductCards"}
      phx-update="ignore"
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["data-ready"])}
    >
      <ul class="home-products__row">
        <li
          :for={product <- @products}
          id={"home-product-#{product.id}"}
          class="home-product"
          data-product={product.id}
          phx-hook="ProductFoil"
        >
          <div class="home-product__face">
            <div class="home-product__art rg-technical-figure__art" aria-hidden="true">
              <Regent.HolographicCard.foil
                id={"home-product-foil-#{product.id}"}
                class="rg-holo-foil--ink"
              />
              <.drawing id={"home-product-drawing-#{product.id}"} product={product.id} />
            </div>
            <p class="home-product__kicker">{product.kicker}</p>
            <h2 :if={@open} id={"home-product-#{product.id}-title"} class="home-product__title">
              {product.title}
            </h2>
            <h2 :if={!@open} class="home-product__title">
              <button
                type="button"
                id={"home-product-#{product.id}-title"}
                aria-expanded="false"
                aria-controls={"home-product-#{product.id}-more"}
              >
                {product.title}
              </button>
            </h2>
            <p class="home-product__summary">{product.summary}</p>
          </div>
          <div
            id={"home-product-#{product.id}-more"}
            class="home-product__more"
            data-product-more
            role="region"
            aria-labelledby={"home-product-#{product.id}-title"}
          >
            <span class="home-product__fill" data-product-fill aria-hidden="true"></span>
            <ul class="home-product__details">
              <li :for={detail <- product.details} data-product-row>{detail}</li>
            </ul>
            <div class="home-product__action" data-product-row>
              <.link
                :if={!product.launch or @launches_open}
                navigate={product.path}
                class="rg-button rg-button--primary"
              >
                <span class="rg-button__label">{product.action}</span>
              </.link>
              <span :if={product.launch and !@launches_open} class="home-product__closed">
                <Regent.Primitives.button variant="secondary" disabled class="create-button">
                  {product.action}
                </Regent.Primitives.button>
                <small>Opens soon</small>
              </span>
            </div>
          </div>
        </li>
      </ul>
    </section>
    """
  end

  defp products(only) do
    [
      Autolaunch.CoveredCalls.Deployment.enabled?() &&
        %{
          id: "calls",
          kicker: "Options",
          title: "Call Option Onchain",
          summary: "Earn USDC on stock you hold, or buy the right to own it at a set price.",
          details: [
            "Sellers lock a stock token and list calls with a strike and a premium.",
            "Buyers pay the premium in USDC.",
            "Exercise in the 24 hours after each Friday expiry, on Base."
          ],
          action: "Trade calls",
          path: "/stock/covered-call",
          launch: false
        },
      Autolaunch.Exposure.Deployment.enabled?() &&
        %{
          id: "after-hours",
          kicker: "Isolated",
          title: "Isolated After-hours Exposure",
          summary: "Hold a stock's moves while the market is closed, or only while it is open.",
          details: [
            "One stock token splits into two tokens for a week.",
            "After-hours carries each close to the next open; Market-hours, each open to the close.",
            "One of each always returns one stock token."
          ],
          action: "Split stock",
          path: "/stock/isolated-afters",
          launch: false
        },
      %{
        id: "memestock",
        kicker: "Memestock",
        title: "Memestock Pair",
        summary: "A memecoin paired with a real onchain stock, sold in a 24-hour auction.",
        details: [
          "Everyone in the auction pays the same price.",
          "Holders stake it to receive the stock from its trading fees.",
          "On Base or Robinhood Chain."
        ],
        action: "Launch one",
        path: "/create",
        launch: true
      },
      %{
        id: "revstake",
        kicker: "Revstake",
        title: "Revenue Share Token",
        summary: "Raise early funds for an agent or service in a 48-hour auction.",
        details: [
          "Priced in REGENT, on Base.",
          "Holders stake it for a share of the stablecoin revenue sent to it.",
          "Everyone in the auction pays the same price."
        ],
        action: "Launch one",
        path: "/create/revstake",
        launch: true
      }
    ]
    |> Enum.filter(&(&1 && &1.id in only))
    |> Enum.sort_by(&Enum.find_index(only, fn id -> id == &1.id end))
  end

  attr :id, :string, required: true
  attr :product, :string, required: true

  # Line drawings, one for each product: registration marks and sparse
  # geometry. A filled shape hides the lines behind it, in the drawing and in
  # the foil's mask alike.
  defp drawing(assigns) do
    ~H"""
    <svg
      id={@id}
      class="home-product__drawing"
      viewBox="0 0 320 168"
      fill="none"
      stroke="currentColor"
      stroke-width="1.2"
      stroke-linecap="square"
      focusable="false"
    >
      <defs>
        <pattern id={"#{@id}-hatch"} width="7" height="7" patternUnits="userSpaceOnUse">
          <path d="M-2 2L2-2M0 7L7 0M5 9L9 5" stroke-width=".65" />
        </pattern>
      </defs>
      <path d="M8 24V8H24M296 8H312V24M312 144V160H296M24 160H8V144" />
      <g :if={@product == "calls"}>
        <path d="M52 132H276M52 132V36" />
        <rect x="52" y="108" width="112" height="14" fill={"url(##{@id}-hatch)"} />
        <path d="M164 40V132" stroke-dasharray="3 5" />
        <path d="M52 108H164L256 44" />
        <circle cx="164" cy="108" r="4" fill="var(--home-product-ground)" />
        <path d="M244 44H256V56" />
      </g>
      <g :if={@product == "after-hours"}>
        <rect x="52" y="36" width="44" height="96" fill={"url(##{@id}-hatch)"} />
        <rect x="148" y="36" width="44" height="96" fill={"url(##{@id}-hatch)"} />
        <rect x="244" y="36" width="28" height="96" fill={"url(##{@id}-hatch)"} />
        <path d="M44 132H280M96 36V132M148 36V132M192 36V132M244 36V132" />
        <path d="M52 100L74 86L96 92L122 70L148 80L170 58L192 66L218 50L244 60L272 46" />
        <circle cx="96" cy="92" r="3.5" fill="var(--home-product-ground)" />
        <circle cx="148" cy="80" r="3.5" fill="var(--home-product-ground)" />
        <circle cx="192" cy="66" r="3.5" fill="var(--home-product-ground)" />
        <circle cx="244" cy="60" r="3.5" fill="var(--home-product-ground)" />
      </g>
      <g :if={@product == "memestock"}>
        <circle cx="104" cy="84" r="44" fill="var(--home-product-ground)" />
        <circle cx="104" cy="84" r="30" />
        <path d="M92 74L104 66L116 74V94L104 102L92 94Z" />
        <path d="M148 84H180M156 78L148 84L156 90M172 78L180 84L172 90" />
        <rect x="180" y="44" width="92" height="80" fill="var(--home-product-ground)" />
        <rect x="180" y="44" width="92" height="14" fill={"url(##{@id}-hatch)"} />
        <path d="M194 112L212 96L228 102L258 74M194 70H242" />
      </g>
      <g :if={@product == "revstake"}>
        <rect x="44" y="60" width="60" height="48" fill="var(--home-product-ground)" />
        <path d="M58 76H88M58 92H78M104 84H148M172 84H212M168 76L212 40M168 92L212 128" />
        <circle cx="160" cy="84" r="12" fill="var(--home-product-ground)" />
        <circle cx="234" cy="40" r="20" fill={"url(##{@id}-hatch)"} />
        <circle cx="234" cy="84" r="20" fill="var(--home-product-ground)" />
        <circle cx="234" cy="128" r="20" fill="var(--home-product-ground)" />
        <path d="M226 84H242M226 128H242" />
      </g>
    </svg>
    """
  end
end
