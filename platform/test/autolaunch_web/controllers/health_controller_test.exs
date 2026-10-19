defmodule AutolaunchWeb.HealthControllerTest do
  @moduledoc """
  A ready site's health answer names the commit it was built from, so a release
  check sees which build is answering.
  """
  use AutolaunchWeb.ConnCase, async: true

  test "HEALTH_NAMES_THE_COMMIT: a ready site answers ok with its build's commit", %{conn: conn} do
    commit = Application.fetch_env!(:autolaunch, :source_commit)
    answer = get(conn, "/healthz")

    assert answer.status == 200
    assert answer.resp_body == "ok " <> commit
  end
end
