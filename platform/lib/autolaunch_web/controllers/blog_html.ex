defmodule AutolaunchWeb.BlogHTML do
  use AutolaunchWeb, :html

  def index(assigns), do: page(Map.put(assigns, :view, :index))
  def show(assigns), do: page(Map.put(assigns, :view, :show))
  def not_found(assigns), do: page(Map.put(assigns, :view, :not_found))

  defp page(assigns) do
    ~H"""
    <main id="blog-content">
      <Regent.Blog.gallery
        :if={@view == :index}
        posts={@posts}
        site="Autolaunch"
        name="Blog"
        path="/blog"
      />
      <Regent.Blog.article :if={@view == :show} post={@post} name="Blog" path="/blog" />
      <Regent.Blog.not_found :if={@view == :not_found} name="Blog" path="/blog" />
    </main>
    """
  end
end
