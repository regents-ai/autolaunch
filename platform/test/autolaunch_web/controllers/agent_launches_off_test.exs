defmodule AutolaunchWeb.AgentLaunchesOffTest do
  @moduledoc """
  With agent launches switched off, as every environment starts, the site is
  what it was before them: their address answers as an address with nothing
  at it, `/openapi.json` carries none of their contract, and no agent document
  or page names them, whichever agent bids are on. Switched on, the agent
  documents name them, every page registers their browser tool, the site map
  and API catalog are unchanged, and the contract gains their own path and
  components and nothing else.

  The guides' sentences on who launches and who bids follow the switch with
  both agent bid switches: off, a draft an agent filled in is launched by the
  person on the create page; on, every guide says an agent can prepare its
  launch step, points to the Agent launches section where it names sections,
  and still names exactly the chains whose bids agents can prepare.
  """
  use AutolaunchWeb.ConnCase, async: false

  @contract "../../../contracts/agent-launches.openapiv3.yaml"
            |> Path.expand(__DIR__)
            |> YamlElixir.read_from_file!()
  # The tool, its route and the guides' section and sentences.
  @named ~r{\bprepare_launch\b|\bautolaunch_launch_prepare\b|/api/agent/v1/launches\b|\bAgent launches\b|\blaunch step\b}
  @documents ~w(/llms.txt /llms-full.txt /agents.md /skill.md /openapi.json /capabilities.json /.well-known/api-catalog /sitemap.xml /sitemap.md)
  @pages ~w(/ /auctions /tokens /stocks /how-it-works /regent /docs /about)
  @guides ~w(/ /docs /llms.txt /llms-full.txt /agents.md /skill.md)
  # The guides with a section for each switched-on agent feature.
  @sectioned ~w(/docs /llms-full.txt /agents.md /skill.md)
  # Each chain's agent bids, by its switch: its guide section and its chain.
  @bids [
    {:agent_bids, "Agent bids", "Base"},
    {:agent_robinhood_bids, "Robinhood bids", "Robinhood Chain"}
  ]
  @switches [:agent_launches | for({key, _see, _chain} <- @bids, do: key)]

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

  test "AGENT_LAUNCHES_OFF_NO_ROUTE: the agent launch address answers as an address with nothing at it" do
    # Past the prelaunch gate, which would refuse every POST before the router.
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)

    for bids <- bid_switches(),
        path <- [
          "/api/agent/v1/launches/#{Ecto.UUID.generate()}/steps",
          "/api/agent/v1/launches/nope/steps"
        ] do
      switch(bids)
      assert {404, _body} = answer("POST", path)
      assert answer("POST", path) == answer("POST", "/api/agent/v1/nothing-here"), path
    end
  end

  test "AGENT_LAUNCHES_OFF_UNNAMED: no agent document or page names agent launches, and only switched on do they" do
    read = fn ->
      Map.new(@documents ++ @pages, &{&1, build_conn() |> get(&1) |> response(200)})
    end

    # Off, whichever agent bids are on.
    for bids <- bid_switches() do
      switch(bids)
      for {path, body} <- read.(), do: refute(body =~ @named, "#{path} names agent launches")
    end

    switch([:agent_launches])
    on = read.()

    # Every page registers the browser tools for agents in the browser, as it
    # does each switched-on feature's.
    named = ~w(/llms.txt /llms-full.txt /agents.md /skill.md /openapi.json /capabilities.json)

    for path <- named ++ @pages,
        do: assert(on[path] =~ @named, "#{path} does not name agent launches")

    for path <- @documents -- named, do: refute(on[path] =~ @named, path)
  end

  test "AGENT_LAUNCHES_GUIDES: with agent launches off or on, whichever agent bids are on, every guide says who launches and names the sections that say how" do
    for launches? <- [false, true], bids <- bid_switches() do
      switch(if(launches?, do: [:agent_launches | bids], else: bids))
      offered = for {key, see, chain} <- @bids, key in bids, do: {see, chain}
      sections = for {see, _chain} <- offered, do: see

      # The guide sections a sentence may point to: those of the bids offered,
      # alone or with Agent launches, and Agent launches alone.
      pointers =
        if launches?,
          do: [sections, sections ++ ["Agent launches"], ["Agent launches"]],
          else: [sections]

      pointed = for names <- pointers, names != [], do: listed(names)

      for path <- @guides do
        guide =
          build_conn() |> put_req_header("accept", "text/markdown") |> get(path) |> response(200)

        named = "#{inspect({launches?, bids})} #{path}"
        refute guide =~ "{{", named
        refute guide =~ "%{", named

        # Every guide says an agent can prepare the launch step only while it can.
        assert guide =~ ~r/\blaunch step\b/ == launches?, named
        assert guide =~ "## Agent launches\n" == (launches? and path in @sectioned), named

        # Where it points to the guides' sections, it names those offered, and
        # Agent launches wherever it says an agent prepares a launch.
        seen = Enum.uniq(scan(~r/\(see ((?:Agent|Robinhood) [^)]*)\)/, guide))
        assert seen -- pointed == [], "#{named}: #{inspect(seen)}"

        assert Enum.any?(seen, &(&1 =~ "Agent launches")) ==
                 (launches? and path in @sectioned),
               "#{named}: #{inspect(seen)}"

        # It names exactly the chains whose bids agents can prepare.
        chains = for {_see, chain} <- offered, do: chain

        assert Enum.uniq(scan(~r/(?:For a|steps of a) bid on a (.+?) auction\b/, guide)) ==
                 if(chains == [], do: [], else: [Enum.join(chains, " or ")]),
               named
      end
    end
  end

  test "AGENT_LAUNCHES_OFF_OPENAPI: /openapi.json carries agent launches' path and components only while they are on" do
    off = build_conn() |> get("/openapi.json") |> json_response(200)
    switch([:agent_launches])
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

  # The four ways the two agent bid switches stand.
  defp bid_switches, do: [[], [:agent_bids], [:agent_robinhood_bids], tl(@switches)]

  # The switches in `on` on and the others off.
  defp switch(on) do
    for key <- @switches,
        do: Application.put_env(:autolaunch, key, if(key in on, do: :on, else: :off))
  end

  # Names as a sentence lists them: "A", "A and B", "A, B and C".
  defp listed([name]), do: name

  defp listed(names) do
    {first, [last]} = Enum.split(names, -1)
    Enum.join(first, ", ") <> " and " <> last
  end

  defp scan(pattern, text), do: pattern |> Regex.scan(text) |> Enum.map(&List.last/1)
end
