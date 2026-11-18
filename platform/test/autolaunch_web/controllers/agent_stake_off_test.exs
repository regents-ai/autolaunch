defmodule AutolaunchWeb.AgentStakeOffTest do
  @moduledoc """
  With agent staking switched off, as every environment starts, the site is
  what it was before it: its address answers as an address with nothing at
  it, `/openapi.json` carries none of its contract, and no agent document or
  page names it, whichever other agent features are on. Switched on, the
  agent documents name it, the guides with sections gain the Agent staking
  section, every page registers its browser tool, the site map and API
  catalog are unchanged, and the contract gains its own path and components
  and nothing else.
  """
  use AutolaunchWeb.ConnCase, async: false

  @contract "../../../contracts/agent-stake.openapiv3.yaml"
            |> Path.expand(__DIR__)
            |> YamlElixir.read_from_file!()
  # The tool, its route and the guides' section.
  @named ~r{\bprepare_stake\b|\bautolaunch_stake_prepare\b|/stake/steps\b|\bAgent staking\b}
  @documents ~w(/llms.txt /llms-full.txt /agents.md /skill.md /openapi.json /capabilities.json /.well-known/api-catalog /sitemap.xml /sitemap.md)
  @pages ~w(/ /auctions /tokens /stocks /how-it-works /regent /docs /about)
  @guides ~w(/ /docs /llms.txt /llms-full.txt /agents.md /skill.md)
  # The guides with a section for each switched-on agent feature.
  @sectioned ~w(/docs /llms-full.txt /agents.md /skill.md)
  # The other agent features with a wallet step, each with its own switch.
  @others [:agent_bids, :agent_robinhood_bids, :agent_launches, :agent_finish]
  @switches [:agent_staking | @others]

  setup do
    for key <- @switches do
      previous = Application.fetch_env(:autolaunch, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:autolaunch, key, value)
          :error -> Application.delete_env(:autolaunch, key)
        end
      end)

      Application.put_env(:autolaunch, key, :off)
    end

    :ok
  end

  defp answer(method, path),
    do: build_conn() |> dispatch(@endpoint, method, path) |> then(&{&1.status, &1.resp_body})

  test "AGENT_STAKING_OFF_NO_ROUTE: the agent staking address answers as an address with nothing at it" do
    # Past the prelaunch gate, which would refuse every POST before the router.
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)

    for others <- [[], @others],
        path <- [
          "/api/agent/v1/tokens/#{Ecto.UUID.generate()}/stake/steps",
          "/api/agent/v1/tokens/nope/stake/steps"
        ] do
      switch(others)
      assert {404, _body} = answer("POST", path)
      assert answer("POST", path) == answer("POST", "/api/agent/v1/nothing-here"), path
    end
  end

  test "AGENT_STAKING_OFF_UNNAMED: no agent document or page names agent staking, and only switched on do they, the site map and API catalog unchanged" do
    read = fn ->
      Map.new(@documents ++ @pages, &{&1, build_conn() |> get(&1) |> response(200)})
    end

    # Off, whichever other agent features are on.
    for others <- [[], @others] do
      switch(others)
      for {path, body} <- read.(), do: refute(body =~ @named, "#{path} names agent staking")
    end

    switch([])
    off = read.()
    switch([:agent_staking])
    on = read.()

    # Every page registers the browser tools for agents in the browser, as it
    # does each switched-on feature's.
    named = ~w(/llms.txt /llms-full.txt /agents.md /skill.md /openapi.json /capabilities.json)

    for path <- named ++ @pages,
        do: assert(on[path] =~ @named, "#{path} does not name agent staking")

    for path <- @documents -- named do
      refute on[path] =~ @named, path
      assert on[path] == off[path], path
    end
  end

  test "AGENT_STAKING_GUIDES: off, no guide holds the section or its marker; on, each guide with sections holds it once, after Finishing auctions when they are on too" do
    for staking? <- [false, true], others <- [[], @others] do
      switch(if(staking?, do: [:agent_staking | others], else: others))

      for path <- @guides do
        guide =
          build_conn() |> put_req_header("accept", "text/markdown") |> get(path) |> response(200)

        named = "#{inspect({staking?, others})} #{path}"
        refute guide =~ "{{", named
        refute guide =~ "%{", named

        sections = length(String.split(guide, "\n## Agent staking\n")) - 1
        assert sections == if(staking? and path in @sectioned, do: 1, else: 0), named

        # The section follows the finishing section, as the guides list them.
        if staking? and path in @sectioned and :agent_finish in others do
          [before, _after] = String.split(guide, "\n## Agent staking\n")
          assert before =~ "\n## Finishing auctions\n", named
        end
      end
    end
  end

  test "AGENT_STAKING_OFF_OPENAPI: /openapi.json carries agent staking's path and components only while it is on" do
    off = build_conn() |> get("/openapi.json") |> json_response(200)
    switch([:agent_staking])
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

  # The switches in `on` on and the others off.
  defp switch(on) do
    for key <- @switches,
        do: Application.put_env(:autolaunch, key, if(key in on, do: :on, else: :off))
  end
end
