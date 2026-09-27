defmodule AutolaunchWeb.BlogController do
  use AutolaunchWeb, :controller
  alias AutolaunchWeb.{Blog, PublicDocuments}
  plug AutolaunchWeb.Plugs.PageShell
  plug :blog_page

  defp blog_page(conn, _opts), do: assign(conn, :blog_page, true)

  def index(conn, _params),
    do: render(conn, :index, [posts: Blog.all()] ++ PublicDocuments.page("/blog"))

  def show(conn, %{"slug" => slug}) do
    case Blog.get(slug) do
      nil ->
        conn
        |> put_status(:not_found)
        |> render(:not_found, PublicDocuments.page(:missing_post))

      post ->
        render(conn, :show,
          page_title: post.title,
          page_description: post.description,
          post: post
        )
    end
  end
end
