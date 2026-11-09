defmodule AutolaunchWeb.SecureEveryAnswerTest do
  use ExUnit.Case, async: false

  import Plug.Test, only: [conn: 2]

  alias AutolaunchWeb.{ContentSecurityPolicy, Endpoint}

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Autolaunch.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
  end

  test "the health answer runs under the strict policy" do
    assert_strict(Endpoint.call(conn(:get, "/api/v1/health"), []).resp_headers)
  end

  test "a page that does not exist runs under the strict policy" do
    response = Endpoint.call(conn(:get, "/no-such-page"), [])

    assert response.status == 404
    assert_strict(response.resp_headers)
  end

  defp assert_strict(headers) do
    headers = Map.new(headers)
    assert headers["content-security-policy"] == ContentSecurityPolicy.reading()
    assert headers["x-content-type-options"] == "nosniff"
    assert headers["referrer-policy"]
  end
end
