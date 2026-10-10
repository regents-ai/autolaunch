defmodule AutolaunchWeb.PublicPagesController do
  @moduledoc """
  The developer guide, About, Contact, Privacy and Terms pages, the agent guide,
  the tool manifest, the sitemap, robots.txt, security.txt, the API catalog and
  the API description. A request for a page's Markdown is answered before the
  router; this controller shows the same document as HTML.
  """
  use AutolaunchWeb, :controller

  alias AutolaunchWeb.PublicDocuments

  plug AutolaunchWeb.Plugs.PageShell when action == :show

  def show(conn, _params) do
    path = conn.request_path
    %{markdown: markdown} = PublicDocuments.document(path)

    render(conn, :show, [document: PublicDocuments.html(markdown)] ++ PublicDocuments.page(path))
  end

  def developers(conn, _params), do: conn |> put_status(301) |> redirect(to: "/docs")

  def sitemap(conn, _params) do
    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, PublicDocuments.sitemap())
  end

  def agent_guide(conn, _params), do: text_document(conn, PublicDocuments.agent_guide())

  def signed_agent_guide(conn, _params),
    do: text_document(conn, PublicDocuments.signed_agent_guide())

  def openapi(conn, _params), do: json_document(conn, PublicDocuments.openapi())

  def capabilities(conn, _params), do: json_document(conn, PublicDocuments.capabilities())

  def robots(conn, _params) do
    body = """
    # Every public page may be read. The agent guide is at /llms.txt.
    User-agent: *
    Allow: /

    Sitemap: #{PublicDocuments.url("/sitemap.xml")}
    """

    text_document(conn, body)
  end

  def security(conn, _params), do: text_document(conn, PublicDocuments.security_txt())

  # The body is JSON built from this site's own addresses, sent as a linkset with
  # the RFC 9727 profile, which Sobelow does not read as a safe content type.
  # sobelow_skip ["XSS.SendResp"]
  def api_catalog(conn, _params) do
    body = Jason.encode!(PublicDocuments.api_catalog())

    conn
    |> cached(body)
    |> put_resp_content_type(
      ~s(application/linkset+json; profile="https://www.rfc-editor.org/info/rfc9727"),
      nil
    )
    |> send_resp(200, body)
  end

  defp text_document(conn, body),
    do: conn |> cached(body) |> put_resp_content_type("text/plain") |> send_resp(200, body)

  defp json_document(conn, document) do
    body = Jason.encode!(document)
    conn |> cached(body) |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  # These documents change only with a release: a sha256 ETag of the body and a
  # five-minute public cache.
  defp cached(conn, body) do
    conn
    |> put_resp_header("etag", ~s("#{Base.encode16(:crypto.hash(:sha256, body), case: :lower)}"))
    |> put_resp_header("cache-control", "public, max-age=300")
  end
end
