defmodule AutolaunchWeb.AgentRobinhoodBidsOffTest do
  @moduledoc """
  With agent Robinhood bids switched off, as every environment starts, the
  site is what it was before them: each of their addresses answers as an
  address with nothing at it, `/openapi.json` carries none of their contract,
  and no agent document or page names them. Switched on, the agent documents
  name them, every page registers their browser tools, the site map and API
  catalog are unchanged, and the contract gains their own paths and components
  and nothing else.

  The guides' sentences on who bids follow both agent bid switches, Base's and
  Robinhood Chain's: with neither on, bidding and settlement stay with the
  person in the words they had before agent bids; with either or both on, they
  name exactly the chains offered, and the bids on a chain not offered stay
  with the site's pages.
  """
  use AutolaunchWeb.ConnCase, async: false

  @contract "../../../contracts/agent-robinhood-bids.openapiv3.yaml"
            |> Path.expand(__DIR__)
            |> YamlElixir.read_from_file!()
  # The tools, their routes and the guides' section.
  @named ~r{\bprepare_robinhood_bid(_settlement)?\b|\bautolaunch_robinhood_bid_(settlement_)?prepare\b|/api/agent/v1/robinhood/bids\b|\bRobinhood bids\b}
  @documents ~w(/llms.txt /llms-full.txt /agents.md /skill.md /openapi.json /capabilities.json /.well-known/api-catalog /sitemap.xml /sitemap.md)
  @pages ~w(/ /auctions /tokens /stocks /how-it-works /regent /docs /about)
  @guides ~w(/ /docs /llms.txt /llms-full.txt /agents.md /skill.md)
  # The guides with a section for each chain's agent bids.
  @sectioned ~w(/docs /llms-full.txt /agents.md /skill.md)
  # Each chain's agent bids, by its switch: the chain, its guide section and
  # its bids, as the guides name them.
  @chains [
    {:agent_bids, "Base", "Agent bids", "Base bids"},
    {:agent_robinhood_bids, "Robinhood Chain", "Robinhood bids", "Robinhood Chain bids"}
  ]
  # The ways a guide says that bidding or settling is not for agents.
  @not_for_agents [
    ~r/\b(bidding|settlement)\b[^.]*\bremain person-controlled/i,
    ~r/no agent tool or command\s+does them/i,
    ~r/no agent command claims, withdraws or\s+bids\./i,
    ~r/\b(wallet|financial) and launch controls\b[^.;]*\bnot registered as agent tools/i,
    ~r/\bbidding\b[^.]*\bthrough the person-controlled interface/i,
    ~r/\bbidding\b[^.;]*\bhappen on the website/i,
    ~r/these happen on the website/i
  ]

  setup do
    for {key, _chain, _see, _bids} <- @chains do
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

  test "AGENT_ROBINHOOD_BIDS_OFF_NO_ROUTE: each agent Robinhood bid address answers as an address with nothing at it" do
    # Past the prelaunch gate, which would refuse every POST before the router.
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)

    for agent_bids <- [:off, :on],
        path <- [
          "/api/agent/v1/robinhood/bids/steps",
          "/api/agent/v1/robinhood/bids/0x3000000000000000000000000000000000000003:7/steps"
        ] do
      Application.put_env(:autolaunch, :agent_bids, agent_bids)
      assert {404, _body} = answer("POST", path)
      assert answer("POST", path) == answer("POST", "/api/agent/v1/nothing-here"), path
    end
  end

  test "AGENT_ROBINHOOD_BIDS_OFF_UNNAMED: no agent document or page names agent Robinhood bids, and only switched on do they" do
    read = fn ->
      Map.new(@documents ++ @pages, &{&1, build_conn() |> get(&1) |> response(200)})
    end

    # Off, whether or not Base's agent bids are on.
    for agent_bids <- [:off, :on] do
      Application.put_env(:autolaunch, :agent_bids, agent_bids)

      for {path, body} <- read.(),
          do: refute(body =~ @named, "#{path} names agent Robinhood bids")
    end

    Application.put_env(:autolaunch, :agent_bids, :off)
    Application.put_env(:autolaunch, :agent_robinhood_bids, :on)
    on = read.()

    # Every page registers the browser tools for agents in the browser, as it
    # does each switched-on feature's.
    named = ~w(/llms.txt /llms-full.txt /agents.md /skill.md /openapi.json /capabilities.json)

    for path <- named ++ @pages,
        do: assert(on[path] =~ @named, "#{path} does not name agent Robinhood bids")

    for path <- @documents -- named, do: refute(on[path] =~ @named, path)
  end

  test "AGENT_ROBINHOOD_BIDS_GUIDES: in each of the four ways the two agent bid switches stand, every guide names exactly the chains offered, and with neither on says bidding stays with the person" do
    for on <- [[], [:agent_bids], [:agent_robinhood_bids], [:agent_bids, :agent_robinhood_bids]] do
      for {key, _chain, _see, _bids} <- @chains,
          do: Application.put_env(:autolaunch, key, if(key in on, do: :on, else: :off))

      {offered, others} = Enum.split_with(@chains, fn {key, _, _, _} -> key in on end)
      chains = for {_key, chain, _see, _bids} <- offered, do: chain
      sections = for {_key, _chain, see, _bids} <- offered, do: see

      staying =
        if offered == [], do: [], else: for({_key, _chain, _see, bids} <- others, do: bids)

      for path <- @guides do
        guide =
          build_conn() |> put_req_header("accept", "text/markdown") |> get(path) |> response(200)

        named = "#{inspect(on)} #{path}"
        refute guide =~ "{{bidding", named
        refute guide =~ "%{", named

        # Every guide says who bids on which chain, naming the chains offered.
        assert Enum.uniq(scan(~r/(?:For a|steps of a) bid on a (.+?) auction\b/, guide)) ==
                 if(offered == [], do: [], else: [Enum.join(chains, " or ")]),
               named

        # Where it points to the guides' sections, it names theirs.
        assert Enum.uniq(scan(~r/\(see ((?:Agent|Robinhood) bids.*?)\)/, guide)) --
                 [Enum.join(sections, " and ")] == [],
               named

        # Every guide but the home page says which bids stay with the site's
        # pages: those on the chain not offered, while the other is.
        assert Enum.uniq(
                 scan(
                   ~r/(\w+(?: Chain)? bids) (?:and (?:the|your) person's launches|stay on the auction's page)/,
                   guide
                 )
               ) == if(path == "/", do: [], else: staying),
               named

        if offered == [] do
          assert Enum.any?(@not_for_agents, &(guide =~ &1)), named
        else
          for words <- @not_for_agents, do: refute(guide =~ words, "#{named}: #{inspect(words)}")
        end

        for {key, _chain, see, _bids} <- @chains,
            do: assert(guide =~ "## #{see}\n" == (key in on and path in @sectioned), named)
      end
    end
  end

  test "AGENT_ROBINHOOD_BIDS_OFF_OPENAPI: /openapi.json carries agent Robinhood bids' paths and components only while they are on" do
    off = build_conn() |> get("/openapi.json") |> json_response(200)
    Application.put_env(:autolaunch, :agent_robinhood_bids, :on)
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

  defp scan(pattern, text), do: pattern |> Regex.scan(text) |> Enum.map(&List.last/1)
end
