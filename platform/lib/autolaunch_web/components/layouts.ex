defmodule AutolaunchWeb.Layouts do
  @moduledoc "Root document layout and the product shell."

  use AutolaunchWeb, :html

  import AutolaunchWeb.Components.Rail
  import AutolaunchWeb.Components.TopBar

  embed_templates("layouts/*")
  @doc "Product and source discovery without loading a browser integration."
  def product_links(assigns) do
    ~H"""
    <footer aria-label="Project links" class="product-links">
      <a href="https://github.com/regents-ai/autolaunch" rel="noopener noreferrer">Star on GitHub</a>
      <a href="/llms.txt">For agents</a>
      <details>
        <summary>Regents Labs</summary>
        <nav aria-label="Related products" class="product-links__related">
          <a href="https://regents.sh">Regents</a>
          <a href="https://patchbay.help">Patchbay</a>
          <a href="https://techtree.sh">Techtree</a>
        </nav>
      </details>
    </footer>
    """
  end
end
