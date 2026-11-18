defmodule AutolaunchWeb.AgentDoorsTest do
  @moduledoc """
  Every way in an agent has, as the guides' Agent access table names it and as
  the site serves it:

  - the table has one row per action offered while its switch is on, and each
    cell is what that way in serves: the page's tools, the hosted MCP server's
    tools as a paired agent lists them, the routes and regents-cli's commands;
    while Autolaunch is not open, an action whose route waits says so;
  - one read through each way in gets the same answer;
  - each hosted tool that reads the market, a person's drafts, positions,
    Points or Exposure, or saves a draft, gives its route's `data` (a paged
    list and one auction their route's whole answer, and Points, which has no
    `data`, its whole answer), and its route's refusals, in the same code and
    words; a bid estimate whatever its amount and highest price; a paged list
    reads every page by the cursor each page gives; the lists and one auction
    say when Robinhood could not be read, as their routes do; the auction list
    has the route's own budget, and a draft save before opening the route's
    answer; a list read that fails in its cache is refused in words, and a
    tool that raises tells nothing of it;
  - all of one person's signed agents and connected apps spend one budget of
    120 calls a minute, and its signed agents another 120 on the signed
    routes, apart from it; a person's own reads and saves run, by each action
    itself, for the agent paired with them alone, their covered calls' and
    Earn's positions for them signed in too, and their bids and holdings are
    read from the account the pairing named, by its id;
  - every hosted tool in `priv/capabilities.json` is called, a connected app's
    own as that app, and each one it lists as read-only writes no row;
  - the guides and the server's own instructions name every hosted tool a
    paired agent is served and no other.

  A connected app's own tools are otherwise in AutolaunchWeb.ClaudeConnectorTest.
  The sign-in service is stubbed: it vouches for the wallet a request names,
  unless the request carries a forged proof.
  """
  use AutolaunchWeb.ConnCase, async: false
  use ExUnitProperties

  import Plug.Test, only: [conn: 3]

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.RequestRateLimiter
  alias Autolaunch.Actors.{ConnectedApp, Human}
  alias Autolaunch.CoveredCalls.Terms

  alias Autolaunch.{
    BidFixture,
    ChainHead,
    CoveredCallsChain,
    EarnChain,
    ExposureChain,
    LaunchFixture,
    RobinhoodBidChain,
    SharedReading,
    TestAutolaunchBidSettlementChainClient,
    TestAutolaunchTreasuryChainClient,
    TestSupport
  }

  alias Autolaunch.Points.Board
  alias AutolaunchWeb.{AccountAnswer, Capabilities, ClientAddress, MarketAnswer, ToolManifest}

  @moduletag :capture_log
  @commands Path.expand("../../../cli/commands.json", __DIR__)
  @features ~w(covered_calls exposure earn agent_bids agent_robinhood_bids agent_launches)
  @who %{"public" => "Yes", "signed_agent" => "Signed agent", "paired_agent" => "Paired agent"}
  @requires %{"none" => "Yes", "siwa" => "Signed agent", "siwa_and_pairing" => "Paired agent"}
  @lists %{"autolaunch_auctions" => "/api/v1/auctions", "autolaunch_tokens" => "/api/v1/tokens"}
  # The answers a hosted tool gives whole: a paged list's page and one auction's,
  # each with Robinhood's flag, and Points', which has no `data`.
  @whole ["account_points", "autolaunch_auction" | Map.keys(@lists)]
  @robinhood 4_663
  @exposure_contract "../../contracts/exposure.openapiv3.yaml"
                     |> Path.expand(__DIR__)
                     |> YamlElixir.read_from_file!()
  @safe "0x9999999999999999999999999999999999999999"
  @site_key String.duplicate("k", 32)
  @signed %{
    "x-siwa-signature" => "sig1=:c2lnbmVk:",
    "x-siwa-signature-input" =>
      ~s|sig1=("@method" "@path");created=1;expires=2;nonce="n";keyid="k"|,
    "x-siwa-receipt" => "receipt",
    "x-key-id" => "k",
    "x-timestamp" => "1",
    "x-agent-chain-id" => "8453"
  }

  setup do
    Req.Test.stub(RegentAgents.Broker, fn broker ->
      {:ok, body, broker} = Plug.Conn.read_body(broker)
      headers = Jason.decode!(body)["headers"]

      case headers["x-siwa-signature"] do
        "forged-proof" ->
          broker
          |> Plug.Conn.put_status(401)
          |> Req.Test.json(%{
            "error" => %{
              "code" => "http_signature_invalid",
              "message" => "Signature invalid",
              "hint" => "Sign again"
            }
          })

        _proof ->
          Req.Test.json(broker, %{
            "code" => "http_envelope_valid",
            "data" => %{
              "verified" => true,
              "principal" => %{
                "kind" => "wallet",
                "wallet_address" => headers["x-agent-wallet-address"],
                "chain_id" => 8453,
                "audience" => "autolaunch"
              },
              "agentRegistration" => nil,
              "agentBook" => nil
            }
          })
      end
    end)

    # Past the prelaunch gate, so a draft save and every listed tool are served.
    keep_env(:autolaunch, :prelaunch_read_only)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)

    # The auction list keeps an answer for a few seconds; this case's must not
    # answer the next case's read.
    on_exit(fn -> Cachex.clear(MarketAnswer.cache()) end)
    :ok
  end

  test "the Agent access table has one row per action offered, each cell what its way in serves" do
    agent = paired_agent()
    commands = commands()

    for on <- [
          [],
          ["covered_calls"],
          ["exposure"],
          ["earn"],
          ["agent_bids"],
          ["agent_robinhood_bids"],
          ["agent_launches"],
          @features
        ],
        connector? <- [false, true] do
      switch(on, connector?)
      offered = Capabilities.offered(on ++ if(connector?, do: ["connected_apps"], else: []))
      {heads, rows} = doors(markdown("/docs"))

      assert heads ==
               ["Action", "Browser", "Hosted MCP", "API"] ++
                 if(connector?, do: ["Claude"], else: []) ++ ["CLI"]

      assert Enum.map(rows, & &1["Action"]) == Enum.map(offered, & &1["title"]),
             "#{inspect(on)} with the connector #{connector?}"

      page_tools = Map.new(ToolManifest.tools(), &{&1["name"], &1})
      served = Enum.map(Capabilities.hosted_tools(), &Atom.to_string/1)
      listed = tool_names(agent)

      for {row, operation} <- Enum.zip(rows, offered) do
        name = operation["operation"]
        tool = page_tools[name]
        command = commands[name]
        hosted = operation["hosted_tool"]

        assert row["Browser"] == if(tool, do: @requires[tool["requires"]], else: "No"), name
        assert row["API"] == if(tool && served?(tool["route"]), do: row["Browser"], else: "No")
        assert row["CLI"] == if(command, do: @who[command["authority"]], else: "No"), name

        # A connected app's own tools are listed to a connected app, not to an agent.
        expected =
          cond do
            operation["authority"] == "connected_app" and hosted in served -> "Connected app"
            hosted in listed -> "Paired agent"
            true -> "No"
          end

        assert row["Hosted MCP"] == expected, name

        if connector? do
          claude = %{"Connected app" => "Yes", "Paired agent" => "Once paired", "No" => "No"}
          assert row["Claude"] == claude[expected], name
        end
      end
    end
  end

  test "switching a feature off takes its actions out of every guide's table" do
    earn = Enum.map(Capabilities.offered(["earn"]) -- Capabilities.offered([]), & &1["title"])
    assert earn != []

    for {on, shown?} <- [{["earn"], true}, {[], false}],
        path <- ["/docs", "/llms-full.txt", "/agents.md"] do
      switch(on, false)
      {_heads, rows} = doors(markdown(path))
      titles = Enum.map(rows, & &1["Action"])
      assert Enum.filter(earn, &(&1 in titles)) == if(shown?, do: earn, else: []), path
    end
  end

  test "before Autolaunch opens, an action whose route waits opens soon on every way in that offers it, and no other does" do
    agent = paired_agent()
    switch(@features, false)
    {_heads, open} = doors(markdown("/docs"))

    Application.put_env(:autolaunch, :prelaunch_read_only, true)
    {_heads, shut} = doors(markdown("/docs"))
    listed = tool_names(agent)
    rows = Enum.zip([open, shut, Capabilities.offered(@features)])

    # Each route is asked as an agent asks it, with every feature's deployment
    # in place.
    Enum.each(@features, &chain/1)

    waiting =
      for {_open, _shut, %{"operation" => name} = operation} <- rows,
          refused_before_opening?(operation["route"], agent),
          do: name

    assert waiting != []

    for {open_row, shut_row, %{"operation" => name} = operation} <- rows do
      waits? = name in waiting

      assert shut_row ==
               Map.new(open_row, fn
                 {door, who} when waits? and door != "Action" and who != "No" ->
                   {door, "Opens soon"}

                 cell ->
                   cell
               end),
             name

      # Its hosted tool waits too: it is not listed, or it is refused as its route is.
      hosted = operation["hosted_tool"]

      if waits? and hosted in listed do
        assert {:error, %{"error" => %{"code" => "prelaunch_read_only"}}} =
                 tool(agent, hosted, %{})
      end
    end
  end

  test "one read through each way in gets the same answer" do
    agent = paired_agent()
    TestSupport.project_auction(chain_id: 8453, state: :active)
    assert :ok = Board.read()
    on_exit(fn -> SharedReading.delete(Board.key()) end)

    page_tools = Map.new(ToolManifest.tools(), &{&1["name"], &1["route"]})
    commands = commands()

    for {operation, signer} <- [{"autolaunch_auction_counts", nil}, {"account_points", agent}] do
      %{"method" => method, "path" => path} = commands[operation]
      by_page = request(page_tools[operation], signer)
      by_cli = request("#{method} #{path}", signer)

      assert by_page.status == 200
      assert by_cli == by_page
      assert tool(agent, operation) == hosted(operation, by_page)
    end
  end

  test "the market reads answer as their routes do, refusals included" do
    agent = paired_agent()
    graduated = TestSupport.project_auction(chain_id: 8453, state: :graduated, title: "Graduated")

    active =
      TestSupport.project_auction(chain_id: 8453, state: :active, current_clearing_price: "3")

    token = TestSupport.project_token(auction_id: graduated.id, graduated_at: DateTime.utc_now())
    TestAutolaunchTreasuryChainClient.seed_verified!(@safe)
    unknown = Ecto.UUID.generate()
    nobody = "0x" <> String.duplicate("12", 20)

    for {name, input, path, status} <- [
          {"autolaunch_auctions", nil, "/api/v1/auctions", 200},
          {"autolaunch_auctions", %{state: "active", sort: "ending", limit: 1},
           "/api/v1/auctions?state=active&sort=ending&limit=1", 200},
          {"autolaunch_auctions", %{chain: "base", kind: "revstake", x: true, q: "Grad"},
           "/api/v1/auctions?chain=base&kind=revstake&x=true&q=Grad", 200},
          {"autolaunch_auctions", %{state: "sideways"}, "/api/v1/auctions?state=sideways", 400},
          {"autolaunch_auctions", %{bogus: "1"}, "/api/v1/auctions?bogus=1", 400},
          {"autolaunch_auction", %{id: graduated.id}, "/api/v1/auctions/#{graduated.id}", 200},
          {"autolaunch_auction", %{id: unknown}, "/api/v1/auctions/#{unknown}", 404},
          {"autolaunch_auction", %{id: "nope"}, "/api/v1/auctions/nope", 404},
          {"autolaunch_tokens", nil, "/api/v1/tokens", 200},
          {"autolaunch_tokens", %{q: "Token", chain: "base", limit: 5},
           "/api/v1/tokens?q=Token&chain=base&limit=5", 200},
          {"autolaunch_tokens", %{kind: "nope"}, "/api/v1/tokens?kind=nope", 400},
          {"autolaunch_token", %{id: token.id}, "/api/v1/tokens/#{token.id}", 200},
          {"autolaunch_token", %{id: unknown}, "/api/v1/tokens/#{unknown}", 404},
          {"autolaunch_token", %{id: "nope"}, "/api/v1/tokens/nope", 400},
          {"autolaunch_treasury", %{address: @safe}, "/api/v1/treasury-security/#{@safe}", 200},
          {"autolaunch_treasury", %{address: nobody}, "/api/v1/treasury-security/#{nobody}", 404},
          {"autolaunch_treasury", %{address: "nope"}, "/api/v1/treasury-security/nope", 400}
        ] do
      route = http(:get, path, nil)
      assert route.status == status, path
      assert tool(agent, name, input) == hosted(name, route), "#{name} #{inspect(input)}"
    end

    for {id, amount, max_price, status} <- [
          {active.id, "10", "4", 200},
          {active.id, "0", "4", 422},
          {active.id, "10", "x", 422},
          {active.id, 10, "4", 422},
          {active.id, "10", nil, 422},
          {unknown, "1", "1", 404}
        ] do
      body = %{amount: amount, max_price: max_price}
      route = http(:post, "/api/v1/auctions/#{id}/bid-quote", body)
      assert route.status == status, inspect(body)
      assert tool(agent, "autolaunch_bid_quote", Map.put(body, :id, id)) == answer(route)
    end
  end

  property "a bid estimate answers any amount and highest price as its route answers the same body" do
    agent = paired_agent()

    %{id: id} =
      TestSupport.project_auction(chain_id: 8453, state: :active, current_clearing_price: "3")

    value =
      one_of([
        member_of(["10", "4", "0", "-1", "1.5", "1e3", " 10", ""]),
        string(:printable, max_length: 6),
        integer(),
        float(),
        boolean(),
        constant(nil),
        list_of(integer(), max_length: 2),
        map_of(string(:alphanumeric, max_length: 3), integer(), max_length: 2)
      ])

    check all(amount <- value, max_price <- value, max_runs: 40) do
      body = %{amount: amount, max_price: max_price}
      route = http(:post, "/api/v1/auctions/#{id}/bid-quote", body)
      assert tool(agent, "autolaunch_bid_quote", Map.put(body, :id, id)) == answer(route)
    end
  end

  test "the auction list tool has its route's budget: six reads a minute, for each agent as for each address" do
    agent = paired_agent()
    address = {10, 11, :rand.uniform(250), :rand.uniform(250)}

    # Budgets are counted in whole minutes; seven reads that might straddle two
    # start in the next one.
    {:ok, %{reset: left}} = RequestRateLimiter.admit({"minute", make_ref()}, 1, 60)
    if left < 5, do: Process.sleep(left * 1000)

    route =
      for _read <- 1..7 do
        conn(:get, "/api/v1/auctions", nil) |> Map.put(:remote_ip, address) |> @endpoint.call([])
      end

    hosted = for _call <- 1..7, do: mcp(agent, call("autolaunch_auctions", nil))

    for answers <- [route, hosted] do
      assert Enum.map(answers, & &1.status) == List.duplicate(200, 6) ++ [429]
      assert get_resp_header(List.last(answers), "retry-after") != []
    end

    assert json(List.last(hosted)) == json(List.last(route))
    assert %{"error" => %{"code" => "too_many_requests"}} = json(List.last(route))

    # Another agent, or the same agent's other tools, still answer.
    assert {:ok, _counts} = tool(agent, "autolaunch_auction_counts")
    assert {:ok, _page} = tool(paired_agent(), "autolaunch_auctions")
  end

  test "one person's signed agents and connected apps spend one budget of 120 calls a minute here" do
    account = TestSupport.register_creator!()
    agents = {paired_agent(account), paired_agent(account)}

    # Budgets are counted in whole minutes; calls that might straddle two start
    # in the next one.
    {:ok, %{reset: left}} = RequestRateLimiter.admit({"minute", make_ref()}, 1, 60)
    if left < 5, do: Process.sleep(left * 1000)

    # Each call from an address of its own, so only the person's budget runs out.
    answers = for n <- 1..121, do: mcp(elem(agents, rem(n, 2)), rpc("ping"))
    assert Enum.map(answers, & &1.status) == List.duplicate(200, 120) ++ [429]
    refused = List.last(answers)
    assert get_resp_header(refused, "ratelimit") |> hd() =~ ~s("mcp";r=0)

    # The person's connected app is refused from that same budget, in the same words.
    app = mcp(connected_app(account.privy_user_id), rpc("ping"))
    assert app.status == 429 and json(app) == json(refused)

    # The signed routes still answer the same agent, from their own budget.
    assert signed(elem(agents, 0), "/api/agent/v1/drafts/revstake").status == 200
  end

  test "one person's signed agents spend one budget of 120 requests a minute on the signed routes, apart from the hosted server's" do
    account = TestSupport.register_creator!()
    agents = {paired_agent(account), paired_agent(account)}
    other = paired_agent()
    path = "/api/agent/v1/drafts/revstake"

    # Requests that might straddle two minutes start in the next one.
    {:ok, %{reset: left}} = RequestRateLimiter.admit({"minute", make_ref()}, 1, 60)
    if left < 5, do: Process.sleep(left * 1000)

    # Each request from an address of its own, so only the person's budget runs out.
    answers = for n <- 1..121, do: signed(elem(agents, rem(n, 2)), path)
    assert Enum.map(answers, & &1.status) == List.duplicate(200, 120) ++ [429]
    refused = List.last(answers)
    assert get_resp_header(refused, "ratelimit") |> hd() =~ ~s("agent";r=0)
    assert [wait] = get_resp_header(refused, "retry-after")
    assert String.to_integer(wait) in 1..60

    # An address past its own limit is refused in those same words.
    address = from()
    key = ClientAddress.key(%{build_conn() | remote_ip: address})
    for _request <- 1..120, do: RequestRateLimiter.admit({"default", key}, 120, 60)
    by_address = signed(other, path, address)
    assert by_address.status == 429 and json(by_address) == json(refused)

    # Another person's agent still goes on, and so do these agents on the hosted server.
    assert signed(other, path).status == 200
    assert mcp(elem(agents, 0), rpc("ping")).status == 200
  end

  test "a request refused for its signature or its pairing spends nothing of a person's budget" do
    agent = paired_agent()
    unpaired = wallet()
    path = "/api/agent/v1/drafts/revstake"

    # Requests that might straddle two minutes start in the next one.
    {:ok, %{reset: left}} = RequestRateLimiter.admit({"minute", make_ref()}, 1, 60)
    if left < 5, do: Process.sleep(left * 1000)

    # Forged requests naming the paired agent's wallet, and an unpaired agent's
    # own, each from an address of its own.
    refused =
      [{:forged, agent}, unpaired]
      |> Stream.cycle()
      |> Enum.take(121)
      |> Enum.map(&signed(&1, path))

    assert Enum.frequencies(Enum.map(refused, & &1.status)) == %{401 => 61, 403 => 60}

    answer = signed(agent, path)
    assert answer.status == 200
    assert get_resp_header(answer, "ratelimit") |> hd() =~ ~s("agent";r=119)
  end

  test "a paged list reads every page by the cursor each page gives, each page the route's own" do
    agent = paired_agent()

    for _launch <- 1..3 do
      auction = TestSupport.project_auction(chain_id: 8453, state: :graduated)
      TestSupport.project_token(auction_id: auction.id, graduated_at: DateTime.utc_now())
    end

    for {name, path} <- @lists do
      assert {:ok, first} = tool(agent, name, %{limit: 2})
      assert %{"has_more" => true, "next_cursor" => cursor} = first["pagination"]
      assert {:ok, rest} = tool(agent, name, %{limit: 2, after: cursor})
      assert %{"has_more" => false, "next_cursor" => nil} = rest["pagination"]

      pages = [first["data"], rest["data"]]
      ids = Enum.flat_map(pages, &Enum.map(&1, fn entry -> entry["id"] end))
      assert Enum.map(pages, &length/1) == [2, 1] and Enum.uniq(ids) == ids, name

      # The route reads that page itself rather than the hosted call's kept list.
      Cachex.clear(MarketAnswer.cache())
      route = http(:get, path <> "?" <> URI.encode_query(limit: 2, after: cursor), nil)
      assert hosted(name, route) == {:ok, rest}, name
    end
  end

  test "the lists and one auction say whether Robinhood could be read, as their routes do" do
    agent = paired_agent()
    keep_env(:autolaunch, :autolaunch_robinhood_chain_id)
    Application.put_env(:autolaunch, :autolaunch_robinhood_chain_id, @robinhood)
    TestSupport.project_auction(chain_id: 8453, state: :graduated)
    %{id: id} = TestSupport.project_auction(chain_id: @robinhood, kind: :stocks, state: :active)
    reads = Enum.map(@lists, fn {name, path} -> {name, nil, path} end)
    reads = [{"autolaunch_auction", %{id: id}, "/api/v1/auctions/#{id}"} | reads]
    key = ChainHead.key("robinhood")
    on_exit(fn -> SharedReading.delete(key) end)

    # Robinhood's head read, then its next read failed, as `ChainHead` keeps them.
    for {read, unreadable?} <- [
          {&SharedReading.put(&1, 1_000), false},
          {&SharedReading.degraded/1, true}
        ] do
      :ok = read.(key)

      for {name, input, path} <- reads do
        Cachex.clear(MarketAnswer.cache())
        route = http(:get, path, nil)
        assert route.body["robinhood_unavailable"] == unreadable?, path
        Cachex.clear(MarketAnswer.cache())
        assert tool(agent, name, input) == hosted(name, route), name
      end
    end
  end

  test "a list read that fails in its cache is refused in words, and a tool that raises tells nothing of it" do
    agent = paired_agent()

    %{id: id} =
      TestSupport.project_auction(
        chain_id: 8453,
        state: :active,
        current_clearing_price: "unreadable"
      )

    # A stored price the list cannot state raises in the cache's own process,
    # which hands the raise back as its error.
    route = http(:get, "/api/v1/auctions", nil)
    assert route.status == 500 and route.body["error"]["code"] == "internal_error"
    assert tool(agent, "autolaunch_auctions") == {:error, route.body}

    # One auction's read raises in the tool itself: the caller gets the same
    # refusal and nothing of the raise.
    raised = mcp(agent, call("autolaunch_auction", %{id: id}))
    refute IO.iodata_to_binary(raised.resp_body) =~ ~r/Decimal|unreadable|AuctionFigures/
    assert tool(agent, "autolaunch_auction", %{id: id}) == {:error, route.body}

    # The cache not running, for the moment it restarts.
    cache = Process.whereis(MarketAnswer.cache())

    {child, _pid, _type, _modules} =
      Enum.find(Supervisor.which_children(Autolaunch.Supervisor), &(elem(&1, 1) == cache))

    :ok = Supervisor.terminate_child(Autolaunch.Supervisor, child)
    on_exit(fn -> Supervisor.restart_child(Autolaunch.Supervisor, child) end)

    assert http(:get, "/api/v1/auctions", nil) == route
    assert tool(agent, "autolaunch_auctions") == {:error, route.body}
  end

  test "a paired agent's drafts read and save as their routes do, refusals included" do
    agent = paired_agent()

    for {kind, refused} <- [
          {"revstake", %{treasury_path: "bank"}},
          {"memestock", %{chain: "mars"}}
        ] do
      path = "/api/agent/v1/drafts/#{kind}"
      read = "autolaunch_#{kind}_draft"
      save = "autolaunch_#{kind}_draft_save"

      # A draft not started yet is `null`.
      assert tool(agent, read) == {:ok, nil}
      assert tool(agent, read) == answer(http(:get, path, nil, agent))

      assert http(:patch, path, %{name: "Route", symbol: "RT"}, agent).status == 200
      assert {:ok, %{"name" => "Route"}} = tool(agent, read)
      assert tool(agent, read) == answer(http(:get, path, nil, agent))

      assert {:ok, saved} = tool(agent, save, %{name: " Tool ", description: ""})
      assert {:ok, saved} == answer(http(:get, path, nil, agent))
      assert saved["name"] == "Tool"

      for input <- [
            refused,
            %{name: 5},
            %{bogus: "x"},
            %{image: %{content_type: "image/gif", data: "R0lGODlhAQABAAAAACw="}}
          ] do
        route = http(:patch, path, input, agent)
        assert route.status == 422, "#{path} #{inspect(input)} answered #{route.status}"
        assert tool(agent, save, input) == {:error, route.body}, "#{save} #{inspect(input)}"
      end
    end
  end

  test "in prelaunch read-only mode a draft save is refused as its route refuses it" do
    agent = paired_agent()
    Application.put_env(:autolaunch, :prelaunch_read_only, true)

    for kind <- ["revstake", "memestock"] do
      route = http(:patch, "/api/agent/v1/drafts/#{kind}", %{name: "Shut"}, agent)
      assert route.status == 503 and route.body["error"]["code"] == "prelaunch_read_only"
      assert tool(agent, "autolaunch_#{kind}_draft_save", %{name: "Shut"}) == answer(route)

      read = "/api/agent/v1/drafts/#{kind}"
      assert tool(agent, "autolaunch_#{kind}_draft") == answer(http(:get, read, nil, agent))
    end
  end

  test "a paired agent's positions and Points answer as their routes do, refusals included" do
    agent = paired_agent()
    assert :ok = Board.read()
    on_exit(fn -> SharedReading.delete(Board.key()) end)

    # With no chain to read, the bids and holdings are the site's own records.
    for key <- [:autolaunch_base_deployment, :autolaunch_robinhood_deployment] do
      keep_env(:autolaunch, key)
      Application.delete_env(:autolaunch, key)
    end

    for {name, path} <- [
          {"autolaunch_my_positions", "/api/agent/v1/positions"},
          {"account_points", "/api/v1/account/points"}
        ] do
      route = http(:get, path, nil, agent)
      assert route.status == 200, "#{path} answered #{route.status}"
      assert tool(agent, name) == hosted(name, route)
    end

    # A Base chain that cannot be read, and a Points board not read yet.
    Application.put_env(
      :autolaunch,
      :autolaunch_base_deployment,
      Path.expand("../fixtures/base-deployment.json", __DIR__)
    )

    SharedReading.delete(Board.key())

    for {name, path} <- [
          {"autolaunch_my_positions", "/api/agent/v1/positions"},
          {"account_points", "/api/v1/account/points"}
        ] do
      route = http(:get, path, nil, agent)
      assert route.status == 503, "#{path} answered #{route.status}"
      assert tool(agent, name) == answer(route)
    end
  end

  test "a paired agent's bids and holdings are read from the account its pairing named, by that account's id" do
    {:ok, agent} = Autolaunch.Agents.resolve(paired_agent())

    no_wallet =
      Accounts.register_verified!("did:privy:no-wallet-#{System.unique_integer()}", nil, [],
        actor: %Autolaunch.Actors.System{}
      )

    # The account the agent's account id names is the one read, never one found
    # again by its person's sign-in id, which here has a verified wallet.
    assert {:error, %{code: "wallet_required"}} =
             AccountAnswer.positions(%{agent | human_account_id: no_wallet.id})
  end

  test "a person's own hosted reads and saves run for the agent paired with them alone, whoever else asks" do
    ExposureChain.install()
    account = TestSupport.register_creator!()
    {:ok, agent} = Autolaunch.Agents.resolve(paired_agent(account))
    holding = {Autolaunch.Exposure.Series, :holdings_answer, %{series: ExposureChain.series()}}

    actions = [
      holding
      | for(
          %{name: name} <- Ash.Resource.Info.actions(Autolaunch.AgentAccount),
          do: {Autolaunch.AgentAccount, name, %{}}
        )
    ]

    others = [
      %Human{human_account_id: account.id},
      %ConnectedApp{principal: %{subject: account.privy_user_id}},
      nil
    ]

    for {resource, action, input} <- actions do
      may? = &Ash.can?(Ash.ActionInput.for_action(resource, action, input), &1)
      assert may?.(agent), "#{action}"
      for actor <- others, do: refute(may?.(actor), "#{action} runs for #{inspect(actor)}")
    end
  end

  test "a person's covered calls and Earn balances go to them signed in and to the agent paired with them, a preview and the steps to that agent alone" do
    switch(@features, false)
    account = TestSupport.register_creator!()
    {:ok, agent} = Autolaunch.Agents.resolve(paired_agent(account))
    # A connected app whose identity is paired calls as that agent.
    app_as_agent = %{agent | connection: %{subject: account.privy_user_id}}
    person = %Human{human_account_id: account.id}
    app = %ConnectedApp{principal: %{subject: account.privy_user_id}}
    deposit = %{product: "aave-usdc", kind: :deposit}

    for {resource, action, input, allowed} <- [
          {Autolaunch.CoveredCalls.Market, :positions_answer, %{symbol: "AMZNc"},
           [agent, app_as_agent, person]},
          {Autolaunch.CoveredCalls.Market, :prepare_answer, %{symbol: "AMZNc", kind: :claim},
           [agent, app_as_agent]},
          {Autolaunch.Earn.Product, :positions_answer, %{}, [agent, app_as_agent, person]},
          {Autolaunch.Earn.Product, :quote_answer, deposit, [agent, app_as_agent]},
          {Autolaunch.Earn.Product, :prepare_answer, deposit, [agent, app_as_agent]}
        ],
        actor <- [agent, app_as_agent, person, app, %Autolaunch.Actors.System{}, nil] do
      may? = Ash.can?(Ash.ActionInput.for_action(resource, action, input), actor)
      assert may? == actor in allowed, "#{action} of #{inspect(resource)} for #{inspect(actor)}"
    end
  end

  test "every hosted tool listed as read-only writes nothing when it is called" do
    switch(@features, false)
    # Paired with the bid fixture's bidder, whose wallet holds a bid to settle.
    {:ok, bidder} = BidFixture.bidder()
    agent = paired_agent(bidder[:account])
    person = TestSupport.register_creator!().privy_user_id
    graduated = TestSupport.project_auction(chain_id: 8453, state: :graduated)

    active =
      TestSupport.project_auction(chain_id: 8453, state: :active, current_clearing_price: "3")

    token = TestSupport.project_token(auction_id: graduated.id, graduated_at: DateTime.utc_now())
    report = TestAutolaunchTreasuryChainClient.seed_verified!(@safe)
    assert :ok = Board.read()
    on_exit(fn -> SharedReading.delete(Board.key()) end)

    Autolaunch.set_auction_treasury_security_report!(bidder[:auction], report.id,
      actor: BidFixture.system()
    )

    bid = bid_position!(bidder[:auction])
    draft = LaunchFixture.draft!(%Human{human_account_id: bidder[:account].id})

    robinhood =
      TestSupport.project_auction(
        chain_id: @robinhood,
        kind: :stocks,
        state: :active,
        address: RobinhoodBidChain.auction()
      )

    series = ExposureChain.series()
    expiry = hd(Terms.expiries(CoveredCallsChain.now()))
    deposit = %{product: "aave-usdc", kind: "deposit", amount: 10 * EarnChain.unit()}
    code = RegentAgents.issue_pairing_code!(actor: %RegentAgents.Person{privy_user_id: person})

    inputs = %{
      "autolaunch_auctions" => nil,
      "autolaunch_auction" => %{id: active.id},
      "autolaunch_auction_counts" => nil,
      "autolaunch_tokens" => nil,
      "autolaunch_token" => %{id: token.id},
      "autolaunch_treasury" => %{address: @safe},
      "autolaunch_bid_quote" => %{id: active.id, amount: "10", max_price: "4"},
      "autolaunch_revstake_draft" => nil,
      "autolaunch_revstake_draft_save" => %{name: "Saved"},
      "autolaunch_memestock_draft" => nil,
      "autolaunch_memestock_draft_save" => %{name: "Saved"},
      "autolaunch_my_positions" => nil,
      "account_points" => nil,
      "covered_call_book" => %{symbol: "AMZNc"},
      "covered_call_quote" => %{symbol: "AMZNc", strike_per_token: 260_000_000, expiry: expiry},
      "covered_call_positions" => %{symbol: "AMZNc"},
      "prepare_covered_call" => %{symbol: "AMZNc", kind: "cancel", listing_id: 1},
      "autolaunch_after_hour_stocks_list" => nil,
      "autolaunch_after_hour_stocks_series" => %{series: series},
      "autolaunch_my_after_hour_stocks" => %{series: series},
      "earn_products" => nil,
      "earn_quote" => deposit,
      "earn_positions" => nil,
      "prepare_earn" => deposit,
      "prepare_bid" => %{auction_id: bidder[:auction].id, amount: "1", max_price: "3"},
      "prepare_bid_settlement" => %{bid: bid.bid_id},
      "prepare_robinhood_bid" => %{auction_id: robinhood.id, usdg_amount: "1", max_price: "3"},
      "prepare_robinhood_bid_settlement" => %{bid: RobinhoodBidChain.auction() <> ":7"},
      "prepare_launch" => %{draft: draft.id},
      "register_identity" => nil,
      "get_identity" => nil,
      "pair_identity" => %{code: code.code, name: "Claude", harness: "claude"},
      "check_in" => nil
    }

    hosted =
      for %{"surfaces" => %{"hosted_mcp" => true}} = row <- Capabilities.operations(), do: row

    assert Enum.sort(Map.keys(inputs)) == Enum.sort(Enum.map(hosted, & &1["hosted_tool"]))
    assert length(hosted) == 33

    # Each switch's tools are called in turn, by their caller (`caller/3`); every
    # call answers.
    called =
      Enum.flat_map(Enum.chunk_by(hosted, & &1["switch"]), fn [%{"switch" => switch} | _] = rows ->
        caller = caller(switch, agent, person)
        read_only = Map.new(listed(caller), &{&1["name"], &1["annotations"]["readOnlyHint"]})

        for %{"hosted_tool" => name} <- rows do
          assert is_boolean(read_only[name]), "#{name} is not listed with its hint"
          before = writes()
          assert {:ok, _answer} = tool(caller, name, inputs[name]), name
          written = writes() - before
          if read_only[name], do: assert(written == 0, "#{name} wrote #{written} rows")
          {name, read_only[name]}
        end
      end)

    assert length(called) == 33

    # The ones that write: a draft save, a launch's review the site keeps, and a
    # connected app's identity, pairing and check-in.
    assert for({name, false} <- called, do: name) ==
             ~w(autolaunch_revstake_draft_save autolaunch_memestock_draft_save prepare_launch register_identity pair_identity check_in)
  end

  test "with Exposure on its three reads answer as their routes do; off, none is listed or run" do
    ExposureChain.install()
    agent = paired_agent()
    series = ExposureChain.series()
    unknown = "0x1234567890123456789012345678901234567890"

    reads =
      ~w(autolaunch_after_hour_stocks_list autolaunch_after_hour_stocks_series autolaunch_my_after_hour_stocks)

    assert Enum.all?(reads, &(&1 in tool_names(agent)))

    for {name, input, path, signer, status} <- [
          {"autolaunch_after_hour_stocks_list", nil, "/api/v1/after-hour-stocks", nil, 200},
          {"autolaunch_after_hour_stocks_series", %{series: series},
           "/api/v1/after-hour-stocks/#{series}", nil, 200},
          {"autolaunch_after_hour_stocks_series", %{series: unknown},
           "/api/v1/after-hour-stocks/#{unknown}", nil, 404},
          {"autolaunch_after_hour_stocks_series", %{series: "nope"},
           "/api/v1/after-hour-stocks/nope", nil, 404},
          {"autolaunch_my_after_hour_stocks", %{series: series},
           "/api/agent/v1/after-hour-stocks/#{series}/holdings", agent, 200},
          {"autolaunch_my_after_hour_stocks", %{series: unknown},
           "/api/agent/v1/after-hour-stocks/#{unknown}/holdings", agent, 404}
        ] do
      route = http(:get, path, nil, signer)
      assert route.status == status, "#{path}: #{inspect(route.body)}"
      assert unclocked(tool(agent, name, input)) == unclocked(answer(route)), path
    end

    Application.put_env(:autolaunch, :exposure, :off)
    refute Enum.any?(reads, &(&1 in tool_names(agent)))

    for name <- reads do
      assert %{"error" => _} = json(mcp(agent, call(name, %{series: series})))
    end
  end

  test "Exposure on a deployment it cannot run on is refused in words, on the route and the tool alike" do
    ExposureChain.install()
    agent = paired_agent()
    keep_env(:autolaunch, :autolaunch_base_deployment_id)
    id = Application.fetch_env!(:autolaunch, :autolaunch_base_deployment_id)
    path = "/api/v1/after-hour-stocks"

    # Exposure's description, on another chain than the Base deployment's.
    other_chain =
      Path.join(System.tmp_dir!(), "exposure-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(other_chain) end)

    :autolaunch
    |> Application.fetch_env!(:autolaunch_base_exposure_deployment)
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("chain_id", 31_337)
    |> Jason.encode!()
    |> then(&File.write!(other_chain, &1))

    for {started, code} <- [
          {[autolaunch_base_deployment_id: ""], "missing_deployment_id"},
          {[autolaunch_base_deployment_id: id, autolaunch_base_exposure_deployment: other_chain],
           "base_deployment_mismatch"}
        ] do
      Application.put_all_env(autolaunch: started)
      route = http(:get, path, nil)
      assert route.status == 503 and route.body["error"]["code"] == code
      assert code in refusals(@exposure_contract, path), code
      assert tool(agent, "autolaunch_after_hour_stocks_list") == {:error, route.body}
    end
  end

  test "the guides and the server's instructions name every hosted tool a paired agent is served, and no other" do
    agent = paired_agent()
    every = Enum.map(Capabilities.hosted_tools(), &Atom.to_string/1)

    for on <- [[], @features] do
      switch(on, false)
      served = tool_names(agent)
      unserved = every -- served
      instructions = json(mcp(agent, rpc("initialize", initialize())))["result"]["instructions"]

      for {where, text} <- [
            {"/docs", markdown("/docs")},
            {"/llms.txt", markdown("/llms.txt")},
            {"/llms-full.txt", markdown("/llms-full.txt")},
            {"instructions", instructions}
          ] do
        assert Enum.reject(served, &named?(text, &1)) == [], "#{where} with #{inspect(on)}"
        assert Enum.filter(unserved, &named?(text, &1)) == [], "#{where} with #{inspect(on)}"
      end

      for path <- ["/agents.md", "/skill.md"] do
        assert Enum.filter(unserved, &named?(markdown(path), &1)) == [], path
      end
    end

    # While Claude can connect, the guides also name a connected app's own tools.
    switch([], true)

    for path <- ["/docs", "/llms.txt", "/llms-full.txt"] do
      text = markdown(path)
      assert Enum.all?(RegentMCPAgents.Tools.names(), &named?(text, &1)), path
    end
  end

  # The features in `on` switched on and the rest off, and Claude's connector on
  # or off, for this test only.
  defp switch(on, connector?) do
    for feature <- @features do
      key = String.to_existing_atom(feature)
      keep_env(:autolaunch, key)
      Application.put_env(:autolaunch, key, if(feature in on, do: :on, else: :off))
    end

    keep_env(:autolaunch, Autolaunch.OAuth)

    Application.put_env(
      :autolaunch,
      Autolaunch.OAuth,
      Keyword.put(Application.fetch_env!(:autolaunch, Autolaunch.OAuth), :enabled?, connector?)
    )
  end

  # Who calls a switch's hosted tools, ready to answer them: for the site's own,
  # a paired agent with no chain to read, so a person's bids and holdings are the
  # site's own records; for a feature's, that agent with the feature's chain
  # double; for a connected app's own, that app.
  defp caller(nil, agent, _person) do
    for key <- [:autolaunch_base_deployment, :autolaunch_robinhood_deployment] do
      keep_env(:autolaunch, key)
      Application.delete_env(:autolaunch, key)
    end

    agent
  end

  defp caller("connected_apps", _agent, person), do: connected_app(person)

  defp caller(feature, agent, _person) do
    Application.put_env(
      :autolaunch,
      :autolaunch_base_deployment,
      Path.expand("../fixtures/base-deployment.json", __DIR__)
    )

    chain(feature)
    agent
  end

  defp chain("covered_calls"), do: CoveredCallsChain.install(%{usdc_balance: 100_000_000})
  defp chain("exposure"), do: ExposureChain.install()

  defp chain("earn"),
    do: EarnChain.install(%{balance: 40 * EarnChain.unit(), allowance: 10 * EarnChain.unit()})

  # A bid's chain, and a settlement chain on which the bidder's bid has only its
  # price to record.
  defp chain("agent_bids") do
    BidFixture.install([])
    q96 = 79_228_162_514_264_337_593_543_950_336

    TestAutolaunchBidSettlementChainClient.install(%{
      end_block: 90,
      claim_block: 95,
      currency: BidFixture.regent(),
      final_clearing_price_q96: 2 * q96,
      graduated?: false,
      exit: {:refused, :price_not_recorded},
      claim: {:refused, :claim_not_open},
      bid: %{
        start_block: 10,
        exited_block: 0,
        max_price_q96: 3 * q96,
        owner: BidFixture.wallet(),
        amount: 12 * 10 ** 18,
        tokens_filled: 0
      }
    })
  end

  # Robinhood Chain's double, on whose auction the bidder holds bid 7.
  defp chain("agent_robinhood_bids"), do: RobinhoodBidChain.install()

  # A launch's Base chain, and its treasury's verified report.
  defp chain("agent_launches") do
    LaunchFixture.install()
    TestAutolaunchTreasuryChainClient.seed_verified!(LaunchFixture.treasury())
  end

  # A saved bid of the bid fixture's bidder on `auction`, on chain as bid 7.
  defp bid_position!(auction) do
    Autolaunch.Bid
    |> Ash.Changeset.for_create(
      :project_lab,
      %{
        bid_id: "lab:doors:#{System.unique_integer([:positive])}",
        auction_id: auction.id,
        owner_address: BidFixture.wallet(),
        amount: "12",
        max_price: "0.00003",
        current_clearing_price: "0.00002",
        status: :returnable,
        auction_address: BidFixture.auction_address(),
        onchain_bid_id: "7"
      },
      actor: BidFixture.system()
    )
    |> Ash.create!()
  end

  defp keep_env(app, key) do
    old = Application.fetch_env(app, key)

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  defp markdown(path),
    do: build_conn() |> put_req_header("accept", "text/markdown") |> get(path) |> response(200)

  # The Agent access table: its column names, and each row by them.
  defp doors(markdown) do
    [_before, after_heading] = Regex.split(~r/^#+ Agent access\n/m, markdown, parts: 2)

    [head, _rule | rows] =
      after_heading
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, "| Action")))
      |> Enum.take_while(&String.starts_with?(&1, "|"))
      |> Enum.map(&cells/1)

    {head, Enum.map(rows, &(head |> Enum.zip(&1) |> Map.new()))}
  end

  defp cells(line), do: line |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)

  # regents-cli's commands, by the browser tool or operation each one runs.
  defp commands do
    for command <- @commands |> File.read!() |> Jason.decode!() |> Map.fetch!("commands"),
        into: %{},
        do: {command["webmcp"] || command["operation_id"], command}
  end

  # Whether the router serves a route such as `GET /api/v1/auctions/{id}`.
  defp served?(route) do
    [method, path] = String.split(route, " ")
    path = String.replace(path, ~r/\{[^}]+\}/, "x")
    Phoenix.Router.route_info(AutolaunchWeb.Router, method, path, "www.example.com") != :error
  end

  defp named?(text, name), do: Regex.match?(~r/\b#{name}\b/, text)

  # A browser tool's or a command's request, such as `GET /api/v1/auction-counts`,
  # with "x" for each value its path names, such as `{id}`.
  defp request(route, signer) do
    [method, path] = String.split(route, " ")
    path = String.replace(path, ~r/\{[^}]+\}/, "x")
    http(method |> String.downcase() |> String.to_existing_atom(), path, nil, signer)
  end

  # Whether an action's route is refused until Autolaunch opens; a tool only the
  # hosted server has has none.
  defp refused_before_opening?(nil, _agent), do: false

  defp refused_before_opening?(route, agent),
    do: request(route, agent).body["error"]["code"] == "prelaunch_read_only"

  # Rows this test's transaction has inserted, updated or deleted so far.
  defp writes do
    %{rows: [[count]]} =
      Autolaunch.Repo.query!(
        "select coalesce(sum(n_tup_ins + n_tup_upd + n_tup_del), 0)::bigint from pg_stat_xact_user_tables"
      )

    count
  end

  # A paired agent's signing wallet, paired with `account`'s person, or with a
  # new person's.
  defp paired_agent(account \\ TestSupport.register_creator!()) do
    agent = wallet()

    code =
      RegentAgents.issue_pairing_code!(
        actor: %RegentAgents.Person{privy_user_id: account.privy_user_id}
      )

    RegentAgents.pair_agent!(code.code, "Agent", :codex,
      actor: %RegentAgents.Agent{wallet: agent}
    )

    agent
  end

  # The tool's result, or its error: each its text decoded. An object also comes
  # as structured content; a list or `null` does not (`docs.md`, Hosted MCP).
  defp tool(caller, name, input \\ nil) do
    case json(mcp(caller, call(name, input)))["result"] do
      %{"isError" => false, "content" => [%{"text" => text}]} = result ->
        answer = Jason.decode!(text)
        assert result["structuredContent"] == if(is_map(answer), do: answer), name
        {:ok, answer}

      %{"isError" => true, "content" => [%{"text" => text}]} ->
        {:error, Jason.decode!(text)}
    end
  end

  defp listed(caller), do: json(mcp(caller, rpc("tools/list")))["result"]["tools"]

  defp tool_names(caller), do: Enum.map(listed(caller), & &1["name"])

  # A route's answer as `name`'s hosted tool gives it (`docs.md`, Hosted MCP).
  defp hosted(name, %{status: 200, body: body}) when name in @whole, do: {:ok, body}
  defp hosted(_name, route), do: answer(route)

  # A route's answer as a hosted tool gives it: its `data`, or its refusal.
  defp answer(%{status: 200, body: %{"data" => data}}), do: {:ok, data}

  defp answer(%{status: status, body: %{"error" => _} = body}) when status != 200,
    do: {:error, body}

  # The refusal codes `contract` documents for `GET path` answering 503.
  defp refusals(contract, path) do
    response = ["paths", path, "get", "responses", "503", "content", "application/json"]
    %{"$ref" => "#/components/schemas/" <> error} = get_in(contract, response ++ ["schema"])
    code = ["components", "schemas", error, "properties", "error", "properties", "code"]
    get_in(contract, code ++ ["enum"])
  end

  # An answer without the clock time each read of a series is stamped with.
  defp unclocked(%{} = map),
    do: for({k, v} <- map, k != "read_at", into: %{}, do: {k, unclocked(v)})

  defp unclocked(list) when is_list(list), do: Enum.map(list, &unclocked/1)
  defp unclocked({result, answer}), do: {result, unclocked(answer)}
  defp unclocked(value), do: value

  # A call to the hosted server by a paired agent's wallet, or by a connected
  # app's access token.
  defp mcp(caller, body) do
    conn(:post, "/mcp", Jason.encode!(body))
    |> Map.put(:remote_ip, from())
    |> put_req_header("content-type", "application/json")
    |> called_by(caller)
    |> @endpoint.call([])
  end

  # A paired agent's signed read of a route, from `address`.
  defp signed(agent, path, address \\ from()) do
    conn(:get, path, nil)
    |> Map.put(:remote_ip, address)
    |> called_by(agent)
    |> @endpoint.call([])
  end

  defp called_by(conn, {:app, token}),
    do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp called_by(conn, {:forged, agent}),
    do: conn |> called_by(agent) |> put_req_header("x-siwa-signature", "forged-proof")

  defp called_by(conn, agent) do
    conn
    |> put_req_header("x-siwa-signature", "fixture-proof")
    |> put_req_header("x-agent-wallet-address", agent)
  end

  # Claude's connector on, as config/runtime.exs switches it on, with a hosted
  # signer that registers each identity and signs as that identity's own wallet;
  # and an app connected by the person `subject` names, as consent leaves it.
  defp connected_app(subject) do
    origin = "http://127.0.0.1:4002"
    oauth = Application.fetch_env!(:autolaunch, Autolaunch.OAuth)
    agents = Application.fetch_env!(:regent_mcp_agents, :config)
    signer = [base_url: "https://siwa.test", key: @site_key]

    for {app, key, value} <- [
          {:autolaunch, Autolaunch.OAuth,
           Keyword.merge(oauth, enabled?: true, issuer: origin, resource: origin <> "/mcp")},
          {:regent_mcp_agents, :config,
           Keyword.merge(agents, enabled?: true, hosted_signer: signer)},
          {:regent_agents, :hosted_pairing, [:claude]},
          {:regent_mcp_agents, :req_options, plug: {Req.Test, RegentMCPAgents.HostedSigner}}
        ] do
      keep_env(app, key)
      Application.put_env(app, key, value)
    end

    keep_env(:regent_oauth, :site)
    keep_env(:boruta, Boruta.Oauth)
    :ok = RegentOAuth.configure(Autolaunch.OAuth)
    :ok = RegentMCPAgents.configure!()

    Req.Test.stub(RegentMCPAgents.HostedSigner, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      asked = Jason.decode!(body)
      wallet = "0x" <> binary_part(asked["identity_key"], 0, 40)

      case asked do
        %{"operation" => "register"} ->
          Req.Test.json(conn, %{"address" => wallet})

        %{"operation" => "sign", "request" => request} ->
          headers = Map.put(@signed, "x-agent-wallet-address", wallet)
          Req.Test.json(conn, Map.put(request, "headers", headers))
      end
    end)

    register =
      conn(:post, "/oauth/register", %{
        "client_name" => "Claude",
        "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"]
      })
      |> Map.put(:remote_ip, from())
      |> put_req_header("accept", "application/json")
      |> @endpoint.call([])

    client = Boruta.ClientsAdapter.get_client(json(register)["client_id"])

    {:ok, token} =
      RegentOAuth.AccessTokens.create(
        %{client: client, sub: subject, scope: RegentMCPAgents.identity_scope()},
        []
      )

    {:app, token.value}
  end

  # One HTTP request, anonymous or signed by `agent`, from an address of its own
  # so no case spends another's rate budget.
  defp http(method, path, body, agent \\ nil) do
    conn =
      conn(method, path, body && Jason.encode!(body))
      |> Map.put(:remote_ip, from())
      |> then(&if(body, do: put_req_header(&1, "content-type", "application/json"), else: &1))
      |> then(
        &if(agent,
          do:
            &1
            |> put_req_header("x-siwa-signature", "fixture-proof")
            |> put_req_header("x-agent-wallet-address", agent),
          else: &1
        )
      )
      |> @endpoint.call([])

    %{status: conn.status, body: json(conn)}
  end

  # A tool listed with no inputs is called without `input`.
  defp call(name, nil), do: rpc("tools/call", %{"name" => name, "arguments" => %{}})

  defp call(name, input),
    do: rpc("tools/call", %{"name" => name, "arguments" => %{"input" => input}})

  defp rpc(method, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

  defp initialize,
    do: %{
      "protocolVersion" => "2025-06-18",
      "capabilities" => %{},
      "clientInfo" => %{"name" => "t", "version" => "1"}
    }

  defp json(conn), do: conn.resp_body |> IO.iodata_to_binary() |> Jason.decode!()

  defp from, do: {10, 9, :rand.uniform(250), :rand.uniform(250)}

  defp wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end
