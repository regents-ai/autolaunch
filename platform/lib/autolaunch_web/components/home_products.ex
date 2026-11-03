defmodule AutolaunchWeb.Components.HomeProducts do
  @moduledoc """
  The home page's products, at the top of the page: covered calls, After-hours
  Exposure, Memestock launches and Revstake launches. Each card is one link: a
  line drawing lit by the shared holographic foil (`ProductFoil` in
  `assets/js/hooks/product_cards.ts`), a title and what the link does.

  A product switched off on this site (covered calls, Exposure) has no card, so
  no card links to a page that answers not found. Before launches open, the two
  launch cards keep their place, not a link, and say so where the action would be.
  """

  use Phoenix.Component

  attr :launches_open, :boolean, required: true

  def product_cards(assigns) do
    assigns = assign(assigns, :products, products())

    ~H"""
    <section id="home-products" class="home-products" aria-label="Products" phx-update="ignore">
      <ul class="home-products__row">
        <li
          :for={product <- @products}
          id={"home-product-#{product.id}"}
          class="home-product"
          phx-hook="ProductFoil"
        >
          <.link
            :if={!product.launch or @launches_open}
            navigate={product.path}
            class="home-product__face"
          >
            <.face product={product} action={product.action} />
          </.link>
          <div :if={product.launch and !@launches_open} class="home-product__face">
            <.face product={product} action="Opens soon" />
          </div>
        </li>
      </ul>
    </section>
    """
  end

  attr :product, :map, required: true
  attr :action, :string, required: true

  defp face(assigns) do
    ~H"""
    <div class="home-product__art rg-technical-figure__art" aria-hidden="true">
      <Regent.HolographicCard.foil
        id={"home-product-foil-#{@product.id}"}
        class="rg-holo-foil--ink"
      />
      <.drawing id={"home-product-drawing-#{@product.id}"} product={@product.id} />
    </div>
    <h2 class="home-product__title">{@product.title}</h2>
    <p class="home-product__action">{@action}</p>
    """
  end

  defp products do
    [
      Autolaunch.CoveredCalls.Deployment.enabled?() &&
        %{
          id: "calls",
          title: "Call Options",
          action: "Trade calls",
          path: "/covered-calls",
          launch: false
        },
      Autolaunch.Exposure.Deployment.enabled?() &&
        %{
          id: "after-hours",
          title: "After-hours",
          action: "Split stock",
          path: "/after-hour-stocks",
          launch: false
        },
      %{
        id: "memestock",
        title: "Memestock",
        action: "Launch one",
        path: "/create",
        launch: true
      },
      %{
        id: "revstake",
        title: "Revstake",
        action: "Launch one",
        path: "/create/revstake",
        launch: true
      }
    ]
    |> Enum.filter(& &1)
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
