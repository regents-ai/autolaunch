defmodule AutolaunchWeb.BlogController do
  use AutolaunchWeb, :controller
  alias AutolaunchWeb.Blog
  plug AutolaunchWeb.Plugs.PageShell
  plug :blog_page

  defp blog_page(conn, _opts), do: assign(conn, :blog_page, true)

  def index(conn, _params),
    do: render(conn, :index, page_title: "Blog · Autolaunch", posts: Blog.all())

  def show(conn, %{"slug" => slug}) do
    case Blog.get(slug) do
      nil ->
        conn
        |> put_status(:not_found)
        |> render(:not_found, page_title: "Post not found · Autolaunch")

      post ->
        render(conn, :show, page_title: post.title <> " · Autolaunch", post: post)
    end
  end
end
