defmodule AutolaunchWeb.PageToolsHeadersTest do
  # Chrome offers a page's WebMCP tools to an agent only when the answer allows
  # `tools` for this site and carries a live origin-trial token for this host.
  use ExUnit.Case, async: false

  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]
  import Plug.Test, only: [conn: 2]

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Autolaunch.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
  end

  test "pages, Markdown documents, refusals and API answers all allow the page tools" do
    for {path, accept, status} <- [
          {"/", "text/html", 200},
          {"/agents.md", "text/markdown", 200},
          {"/no-such-page", "text/html", 404},
          {"/api/v1/no-such-address", "application/json", 404}
        ] do
      response = request(path, accept)
      assert response.status == status, path
      assert get_resp_header(response, "permissions-policy") == ["tools=(self)"], path
      assert [token] = get_resp_header(response, "origin-trial"), path
      assert_live_webmcp_token(token)
    end
  end

  # A token is a version byte, a 64-byte signature, a 4-byte length and the JSON
  # it signs.
  defp assert_live_webmcp_token(token) do
    <<_version, _signature::binary-size(64), size::32, payload::binary-size(size)>> =
      Base.decode64!(token)

    assert %{"origin" => "https://autolaunch.sh:443", "feature" => "WebMCP", "expiry" => expiry} =
             Jason.decode!(payload)

    assert expiry > System.os_time(:second),
           "The WebMCP origin-trial token has expired; register a new one for autolaunch.sh."
  end

  defp request(path, accept) do
    :get
    |> conn(path)
    |> put_req_header("accept", accept)
    |> AutolaunchWeb.Endpoint.call(AutolaunchWeb.Endpoint.init([]))
  end
end
