defmodule AutolaunchWeb.PublicPagesHTML do
  use AutolaunchWeb, :html

  def show(assigns) do
    ~H"""
    <main class="fact-page document-page">
      {@document}
    </main>
    """
  end
end
