defmodule AutolaunchWeb.CoveredCallsOffTest do
  @moduledoc """
  With covered calls switched off, as main runs, the site is what it was before
  them: `/openapi.json` is `contracts/api-contract.openapiv3.yaml` exactly, with
  only this site's address, guide and terms filled in, and no agent document or
  page names covered calls. The browser walk holds the scripts and stylesheets
  the pages load (test/browser/switched_off.spec.ts).
  """
  use AutolaunchWeb.ConnCase, async: false

  @contract Path.expand("../../../contracts/api-contract.openapiv3.yaml", __DIR__)
  @named ~r/covered[-_ ]?calls?|coveredcall/i
  # The stock list's own line, on main since before covered calls were built.
  @coming_soon "Covered Call Options coming soon."
  @documents ~w(/llms.txt /llms-full.txt /agents.md /skill.md /openapi.json /capabilities /.well-known/api-catalog /sitemap.xml /sitemap.md)
  @pages ~w(/ /auctions /tokens /stock-listing /stock-listing/AMZNc /how-it-works /regent /docs /about)

  setup do
    previous = Application.get_env(:autolaunch, :covered_calls)
    on_exit(fn -> Application.put_env(:autolaunch, :covered_calls, previous) end)
    Application.put_env(:autolaunch, :covered_calls, :off)
  end

  test "COVERED_CALLS_OFF_OPENAPI: /openapi.json is the API contract built without covered calls" do
    served = build_conn() |> get("/openapi.json") |> json_response(200)
    site = AutolaunchWeb.Endpoint.url()

    assert served["servers"] == [%{"url" => site}]
    assert served["externalDocs"]["url"] == site <> "/docs"
    assert served["info"]["termsOfService"] == site <> "/terms"

    refute File.read!(@contract) =~ @named
    assert built(served) == built(YamlElixir.read_from_file!(@contract))
  end

  # The document without the parts filled in from this site's address.
  defp built(document),
    do:
      document
      |> Map.drop(["servers", "externalDocs"])
      |> pop_in(["info", "termsOfService"])
      |> elem(1)

  test "COVERED_CALLS_OFF_NO_ASSET: the covered-call styles' address answers as an unknown asset" do
    unknown = build_conn() |> get("/assets/js/nothing-here.css")
    styles = build_conn() |> get("/assets/js/covered_calls.css")

    assert unknown.status == 404
    assert {styles.status, styles.resp_body} == {unknown.status, unknown.resp_body}
  end

  test "COVERED_CALLS_OFF_UNNAMED: no agent document or page names covered calls" do
    for path <- @documents ++ @pages do
      body = build_conn() |> get(path) |> response(200) |> String.replace(@coming_soon, "")
      refute body =~ @named, "#{path} names covered calls"
    end

    account = Autolaunch.TestSupport.register_creator!()

    portfolio =
      build_conn()
      |> Phoenix.ConnTest.init_test_session(signed_in_session(account.id))
      |> get("/portfolio")
      |> html_response(200)

    assert portfolio =~ "autolaunch-held-tokens"
    refute portfolio =~ @named, "the signed-in portfolio names covered calls"
  end
end
