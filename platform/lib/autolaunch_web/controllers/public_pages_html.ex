defmodule AutolaunchWeb.PublicPagesHTML do
  use AutolaunchWeb, :html

  def show(assigns) do
    ~H"""
    <div class="fact-page document-page">
      {@document}
    </div>
    """
  end
end
