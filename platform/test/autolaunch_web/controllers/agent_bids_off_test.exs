defmodule AutolaunchWeb.AgentBidsOffTest do
  @moduledoc """
  With agent bids switched off, as every environment starts, the site is what
  it was before them: each agent bid address answers as an address with
  nothing at it, `/openapi.json` carries none of their contract, and no agent
  document or page names them. Switched on, the agent documents name them,
  every page registers their browser tools, the site map and API catalog are
  unchanged, and the contract gains their own paths and components and nothing
  else.
  """
  use AutolaunchWeb.ConnCase, async: false

  @contract "../../../contracts/agent-bids.openapiv3.yaml"
            |> Path.expand(__DIR__)
            |> YamlElixir.read_from_file!()
  # The tools, their routes and the guides' section.
  @named ~r{\bprepare_bid(_settlement)?\b|\bautolaunch_bid_(settlement_)?prepare\b|/api/agent/v1/bids\b|\bAgent bids\b}
  @documents ~w(/llms.txt /llms-full.txt /agents.md /skill.md /openapi.json /capabilities.json /.well-known/api-catalog /sitemap.xml /sitemap.md)
  @pages ~w(/ /auctions /tokens /stocks /how-it-works /regent /docs /about)

  setup do
    previous = Application.fetch_env(:autolaunch, :agent_bids)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:autolaunch, :agent_bids, value)
        :error -> Application.delete_env(:autolaunch, :agent_bids)
      end
    end)

    Application.put_env(:autolaunch, :agent_bids, :off)
  end

  defp answer(method, path),
    do: build_conn() |> dispatch(@endpoint, method, path) |> then(&{&1.status, &1.resp_body})

  test "AGENT_BIDS_OFF_NO_ROUTE: each agent bid address answers as an address with nothing at it" do
    # Past the prelaunch gate, which would refuse every POST before the router.
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)

    for path <- ["/api/agent/v1/bids/steps", "/api/agent/v1/bids/lab:1/steps"] do
      assert {404, _body} = answer("POST", path)
      assert answer("POST", path) == answer("POST", "/api/agent/v1/nothing-here"), path
    end
  end

  test "AGENT_BIDS_OFF_UNNAMED: no agent document or page names agent bids, and only switched on do they" do
    read = fn ->
      Map.new(@documents ++ @pages, &{&1, build_conn() |> get(&1) |> response(200)})
    end

    for {path, body} <- read.(), do: refute(body =~ @named, "#{path} names agent bids")

    Application.put_env(:autolaunch, :agent_bids, :on)
    on = read.()

    # Every page registers the browser tools for agents in the browser, as it
    # does each switched-on feature's.
    named = ~w(/llms.txt /llms-full.txt /agents.md /skill.md /openapi.json /capabilities.json)

    for path <- named ++ @pages,
        do: assert(on[path] =~ @named, "#{path} does not name agent bids")

    for path <- @documents -- named, do: refute(on[path] =~ @named, path)
  end

  test "AGENT_BIDS_OFF_OPENAPI: /openapi.json carries agent bids' paths and components only while they are on" do
    off = build_conn() |> get("/openapi.json") |> json_response(200)
    Application.put_env(:autolaunch, :agent_bids, :on)
    on = build_conn() |> get("/openapi.json") |> json_response(200)

    paths = Map.keys(@contract["paths"])
    components = Map.new(@contract["components"], fn {kind, named} -> {kind, Map.keys(named)} end)

    refute Enum.any?(paths, &is_map_key(off["paths"], &1))
    assert Enum.all?(paths, &is_map_key(on["paths"], &1))

    for {kind, names} <- components do
      refute Enum.any?(names, &is_map_key(off["components"][kind] || %{}, &1)), kind
      assert Enum.all?(names, &is_map_key(on["components"][kind], &1)), kind
    end

    without =
      Enum.reduce(components, Map.update!(on, "paths", &Map.drop(&1, paths)), fn {kind, names},
                                                                                 contract ->
        update_in(contract, ["components", kind], &Map.drop(&1, names))
      end)

    assert without == off
  end
end
