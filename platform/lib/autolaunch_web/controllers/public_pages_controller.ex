defmodule AutolaunchWeb.PublicPagesController do
  @moduledoc """
  The developer guide, About, Contact and Privacy pages, the agent guide, the
  sitemap and the API description. A request for a page's Markdown is answered before the
  router; this controller shows the same document as HTML.
  """
  use AutolaunchWeb, :controller

  alias AutolaunchWeb.PublicDocuments

  plug AutolaunchWeb.Plugs.PageShell when action == :show

  def show(conn, _params) do
    path = conn.request_path
    {title, description} = PublicDocuments.page(path)
    %{markdown: markdown} = PublicDocuments.document(path)

    render(conn, :show,
      page_title: title,
      page_description: description,
      document: PublicDocuments.html(markdown)
    )
  end

  def sitemap(conn, _params) do
    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, PublicDocuments.sitemap())
  end

  def agent_guide(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, PublicDocuments.agent_guide())
  end

  def openapi(conn, _params), do: json(conn, PublicDocuments.openapi())
end
