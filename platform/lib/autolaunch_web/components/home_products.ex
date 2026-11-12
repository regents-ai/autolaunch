defmodule AutolaunchWeb.Components.HomeProducts do
  @moduledoc """
  The home page's products, at the top of the page: covered calls, Memestock
  launches and Revstake launches. Each card is one link, dark in both themes: a
  tall moving panel of small coloured glyphs drawn on the GPU (`HomeCells` in
  `assets/js/hooks/home_cells.ts`), a pattern and a colour gradient for each
  product; then the product's name in its colour beside its place in the row
  (a card alone has no place), one line saying what it is for, a sentence under
  it, and what the link does. A still frame of the same panel
  (`priv/static/images/home/`, drawn by `npm run stills:home`) is the picture
  until the panel has drawn, and stays it without WebGPU.

  A product switched off on this site (covered calls) has no card, so
  no card links to a page that answers not found. Before launches open, the two
  launch cards keep their place, not a link, and say so where the action would be.


  `/stocks` shows the stock products' cards, Memestock and covered calls, with `only`.
  """

  use Phoenix.Component

  attr :launches_open, :boolean, required: true
  attr :only, :list, default: ~w(calls memestock revstake), doc: "product ids, in order"

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
          data-cells={product.pattern}
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
      <picture class="home-product__still">
        <source
          media="(max-width: 42rem)"
          srcset={"/images/home/#{@product.pattern}-strip.webp"}
        />
        <img src={"/images/home/#{@product.pattern}-#{@product.shape}.webp"} alt="" />
      </picture>
      <div id={"home-product-cells-#{@product.id}"} class="home-product__cells" phx-update="ignore">
        <canvas data-cells-canvas></canvas>
      </div>
    </div>
    <div class="home-product__words">
      <div class="home-product__meta">
        <h2 class="home-product__title">{@product.title}</h2>
        <span :if={@product.place} class="home-product__place" aria-hidden="true">
          {@product.place}
        </span>
      </div>
      <p class="home-product__headline">{@product.headline}</p>
      <p class="home-product__line">{@product.line}</p>
      <p class="home-product__action">
        {@action}<Regent.Icons.icon name="arrow-right" class="home-product__arrow" />
      </p>
    </div>
    """
  end

  # Each card's place in its row, as "01 / 03" (a card alone in its row has none),
  # and the shape its panel takes there: square in a row of three, broad otherwise.
  defp placed(products) do
    count = length(products)
    shape = if count > 2, do: "square", else: "broad"

    for {product, number} <- Enum.with_index(products, 1) do
      product
      |> Map.put(:place, count > 1 && "#{two(number)} / #{two(count)}")
      |> Map.put(:shape, shape)
    end
  end

  defp two(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  # `pattern` names the product's moving panel (`assets/js/home_cells/panels.ts`) and its still frames.
  defp products(only) do
    [
      Autolaunch.CoveredCalls.Deployment.enabled?() &&
        %{
          id: "calls",
          pattern: "payoff",
          title: "Covered calls",
          headline: "Sell calls on your stock.",
          line: "Choose a strike and a Friday expiry, and set your premium.",
          action: "Trade calls",
          path: "/stock/covered-call",
          launch: false
        },
      %{
        id: "memestock",
        pattern: "seam",
        title: "Memestock",
        headline: "Memecoin meets stock.",
        line: "Stake the token to receive stock from its trading fees.",
        action: "Launch one",
        path: "/create",
        launch: true
      },
      %{
        id: "revstake",
        pattern: "columns",
        title: "Revstake",
        headline: "For agents that earn.",
        line: "Raise early backing in an auction and share your revenue with stakers.",
        action: "Launch one",
        path: "/agent-business",
        launch: true
      }
    ]
    |> Enum.filter(&(&1 && &1.id in only))
    |> Enum.sort_by(&Enum.find_index(only, fn id -> id == &1.id end))
    |> placed()
  end
end
