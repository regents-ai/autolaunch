defmodule AutolaunchWeb.BlogController do
  use AutolaunchWeb, :controller
  alias AutolaunchWeb.Blog
  plug :blog_layout

  defp blog_layout(conn, _opts) do
    access =
      case conn.assigns[:current_human_account] do
        nil -> Autolaunch.AccessContext.anonymous()
        account -> Autolaunch.AccessContext.human(account)
      end

    conn
    |> put_layout(html: {AutolaunchWeb.Layouts, :app})
    |> assign(:blog_page, true)
    |> assign(:current_path, conn.request_path)
    |> assign(:search_query, "")
    |> assign(:account_control, Autolaunch.AccessContext.account_control(access))
  end

  def index(conn, _params), do: render(conn, :index, page_title: "Blog", posts: Blog.all())

  def show(conn, %{"slug" => slug}) do
    case Blog.get(slug) do
      nil -> conn |> put_status(:not_found) |> render(:not_found, page_title: "Post not found")
      post -> render(conn, :show, page_title: post.title, post: post)
    end
  end
end
