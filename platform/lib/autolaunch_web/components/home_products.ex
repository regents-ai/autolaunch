defmodule AutolaunchWeb.Components.HomeProducts do
  @moduledoc """
  The home page's products, at the top of the page: covered calls, Memestock
  launches and Revstake launches. Each card is one link: a moving panel of
  small lit cells drawn on the GPU (`HomeCells` in `assets/js/hooks/home_cells.ts`),
  a pattern for each product, then a title and what the link does. The
  product's line drawing is the picture until the panel has drawn, and stays
  it without WebGPU.

  A product switched off on this site (covered calls) has no card, so
  no card links to a page that answers not found. Before launches open, the two
  launch cards keep their place, not a link, and say so where the action would be.


  `/stocks` shows the stock products' cards, Memestock and covered calls, with `only`.
  """

  use Phoenix.Component

  attr :launches_open, :boolean, required: true
  attr :only, :list, default: ~w(calls memestock revstake), doc: "product ids, in order"

  # Each product's moving pattern (`assets/js/home_cells.ts`).
  @patterns %{"calls" => "payoff", "memestock" => "pair", "revstake" => "split"}

  def product_cards(assigns) do
    assigns = assign(assigns, :products, products(assigns.only))

    ~H"""
    <section id="home-products" class="home-products" aria-label="Products" phx-update="ignore">
      <ul class="home-products__row" data-count={length(@products)}>
        <li
          :for={product <- @products}
          id={"home-product-#{product.id}"}
          class="home-product"
          phx-hook="HomeCells"
          data-cells={pattern(product.id)}
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
    <div class="home-product__art" aria-hidden="true">
      <div id={"home-product-cells-#{@product.id}"} class="home-product__cells" phx-update="ignore">
        <canvas data-cells-canvas></canvas>
      </div>
      <.drawing id={"home-product-drawing-#{@product.id}"} product={@product.id} />
    </div>
    <div class="home-product__words">
      <h2 class="home-product__title">{@product.title}</h2>
      <p class="home-product__action">
        {@action}<Regent.Icons.icon name="arrow-right" class="home-product__arrow" />
      </p>
    </div>
    """
  end

  defp pattern(id), do: Map.fetch!(@patterns, id)

  defp products(only) do
    [
      Autolaunch.CoveredCalls.Deployment.enabled?() &&
        %{
          id: "calls",
          title: "Call Options",
          action: "Trade calls",
          path: "/stock/covered-call",
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
        path: "/agent-business",
        launch: true
      }
    ]
    |> Enum.filter(&(&1 && &1.id in only))
    |> Enum.sort_by(&Enum.find_index(only, fn id -> id == &1.id end))
  end

  attr :id, :string, required: true
  attr :product, :string, required: true

  # Line drawings, one for each product: registration marks and sparse
  # geometry. A filled shape hides the lines behind it. They are the picture
  # until the cell panel has drawn.
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
