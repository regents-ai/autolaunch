defmodule AutolaunchWeb.EarnOffTest do
  @moduledoc """
  With Earn switched off, as main runs, the site is what it was before it:
  each Earn address answers as an address with nothing at it, `/openapi.json`
  carries none of Earn's contract, and no agent document or page, the rail,
  the home page or the signed-in portfolio names Earn. Switched on, the same
  documents and pages name it, and the contract gains Earn's own paths and
  components and nothing else.
  """
  use AutolaunchWeb.ConnCase, async: false

  @earn_contract "../../../contracts/earn.openapiv3.yaml"
                 |> Path.expand(__DIR__)
                 |> YamlElixir.read_from_file!()
  # Earn's page, routes, styles and tools, and the market it lends to.
  @named ~r{/earn\b|\bearn_(products|quote|positions)\b|\bprepare_earn\b|\baave\b}i
  @documents ~w(/llms.txt /llms-full.txt /agents.md /skill.md /openapi.json /capabilities.json /.well-known/api-catalog /sitemap.xml /sitemap.md)
  @pages ~w(/ /auctions /tokens /stocks /how-it-works /regent /docs /about)

  setup do
    previous = Application.get_env(:autolaunch, :earn)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:autolaunch, :earn, previous),
        else: Application.delete_env(:autolaunch, :earn)
    end)

    Application.put_env(:autolaunch, :earn, :off)
  end

  defp answer(method, path),
    do: build_conn() |> dispatch(@endpoint, method, path) |> then(&{&1.status, &1.resp_body})

  test "EARN_OFF_NO_ROUTE: each Earn address answers as an address with nothing at it" do
    # Past the prelaunch gate, which would refuse every POST before the router.
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)

    assert {404, _headers, page} = assert_error_sent(404, fn -> get(build_conn(), "/earn") end)
    assert answer("GET", "/nothing-here") == {404, page}

    for {method, path, unknown} <- [
          {"GET", "/assets/js/earn.css", "/assets/js/nothing-here.css"},
          {"GET", "/api/v1/earn/products", "/api/v1/nothing-here"},
          {"GET", "/api/v1/me/earn", "/api/v1/me/nothing-here"},
          {"GET", "/api/agent/v1/earn/positions", "/api/agent/v1/nothing-here"},
          {"POST", "/api/agent/v1/earn/quote", "/api/agent/v1/nothing-here"},
          {"POST", "/api/agent/v1/earn/steps", "/api/agent/v1/nothing-here"}
        ] do
      assert {404, _body} = answer(method, path)
      assert answer(method, path) == answer(method, unknown), "#{method} #{path}"
    end
  end

  test "EARN_OFF_UNNAMED: no agent document or page names Earn, and only switched on do they" do
    signed_in = fn ->
      account = Autolaunch.TestSupport.register_creator!()
      build_conn() |> Phoenix.ConnTest.init_test_session(signed_in_session(account.id))
    end

    read = fn ->
      Map.new(@documents ++ @pages, &{&1, build_conn() |> get(&1) |> response(200)})
    end

    off = read.()
    portfolio_off = signed_in.() |> get("/portfolio") |> html_response(200)

    for {path, body} <- off, do: refute(body =~ @named, "#{path} names Earn")
    assert portfolio_off =~ "autolaunch-held-tokens"
    refute portfolio_off =~ @named, "the signed-in portfolio names Earn"

    Autolaunch.EarnChain.install()
    on = read.()

    for path <-
          ~w(/llms-full.txt /agents.md /skill.md /docs /openapi.json /capabilities.json /sitemap.xml /sitemap.md /),
        do: assert(on[path] =~ @named, "#{path} does not name Earn")

    # The rail on every page, and the portfolio's own section.
    assert on["/auctions"] =~ ~s(href="/earn")
    assert signed_in.() |> get("/portfolio") |> html_response(200) =~ ~s(id="portfolio-earn")
  end

  test "EARN_OFF_OPENAPI: /openapi.json carries Earn's paths and components only while it is on" do
    off = build_conn() |> get("/openapi.json") |> json_response(200)
    Autolaunch.EarnChain.install()
    on = build_conn() |> get("/openapi.json") |> json_response(200)

    paths = Map.keys(@earn_contract["paths"])
    schemas = Map.keys(@earn_contract["components"]["schemas"])

    refute Enum.any?(paths, &is_map_key(off["paths"], &1))
    refute Enum.any?(schemas, &is_map_key(off["components"]["schemas"], &1))
    assert Enum.all?(paths, &is_map_key(on["paths"], &1))

    without_earn =
      on
      |> Map.update!("paths", &Map.drop(&1, paths))
      |> update_in(["components", "schemas"], &Map.drop(&1, schemas))

    assert without_earn == off
  end
end
