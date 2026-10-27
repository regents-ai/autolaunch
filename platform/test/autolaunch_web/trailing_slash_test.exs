defmodule AutolaunchWeb.TrailingSlashTest do
  # Regression: the router matched /contact/ and /docs/ as /contact and /docs, and
  # the page then looked up its document under the slash address and crashed.
  use AutolaunchWeb.ConnCase, async: true

  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]
  import Plug.Test, only: [conn: 2]

  test "a page address with a slash at the end is the site's not-found page" do
    for path <- ["/contact/", "/docs/", "/account/", "/llms.txt/"] do
      response = request(path, "text/html")
      assert response.status == 404
      assert response.resp_body =~ "We can’t find that page"
    end
  end

  test "an API address with a slash at the end is the API's not-found answer" do
    response = request("/api/v1/auctions/", "*/*")
    assert response.status == 404
    assert [content_type] = get_resp_header(response, "content-type")
    assert content_type =~ "application/json"
    assert %{"error" => %{"code" => "not_found"}} = Jason.decode!(response.resp_body)
  end

  test "the homepage keeps its slash" do
    assert request("/", "text/html").status == 200
  end

  defp request(path, accept) do
    :get
    |> conn(path)
    |> put_req_header("accept", accept)
    |> AutolaunchWeb.Endpoint.call(AutolaunchWeb.Endpoint.init([]))
  end
end
