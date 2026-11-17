defmodule AutolaunchWeb.AgentDoorsTest do
  @moduledoc """
  Every way in an agent has, as the guides' Agent access table names it and as
  the site serves it:

  - the table has one row per action offered while its switch is on, and each
    cell is what that way in serves: the page's tools, the hosted MCP server's
    tools as a paired agent lists them, the routes and regents-cli's commands;
  - one read through each way in gets the same answer;
  - each hosted tool that reads the market, a person's drafts, positions,
    Points or Exposure, or saves a draft, answers as its route does, refusals
    included, in the same code and words;
  - the guides and the server's own instructions name every hosted tool a
    paired agent is served and no other.

  A connected app's own tools are in AutolaunchWeb.ClaudeConnectorTest. The
  sign-in service is stubbed: it vouches for the wallet a request names.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Plug.Test, only: [conn: 3]

  alias Autolaunch.{ExposureChain, SharedReading, TestAutolaunchTreasuryChainClient, TestSupport}
  alias Autolaunch.Points.Board
  alias AutolaunchWeb.{Capabilities, MarketAnswer, ToolManifest}

  @moduletag :capture_log
  @commands Path.expand("../../../cli/commands.json", __DIR__)
  @features ~w(covered_calls exposure earn)
  @who %{"public" => "Yes", "signed_agent" => "Signed agent", "paired_agent" => "Paired agent"}
  @requires %{"none" => "Yes", "siwa" => "Signed agent", "siwa_and_pairing" => "Paired agent"}
  @safe "0x9999999999999999999999999999999999999999"

  setup do
    Req.Test.stub(RegentAgents.Broker, fn broker ->
      {:ok, body, broker} = Plug.Conn.read_body(broker)
      wallet = Jason.decode!(body)["headers"]["x-agent-wallet-address"]

      Req.Test.json(broker, %{
        "code" => "http_envelope_valid",
        "data" => %{
          "verified" => true,
          "principal" => %{
            "kind" => "wallet",
            "wallet_address" => wallet,
            "chain_id" => 8453,
            "audience" => "autolaunch"
          },
          "agentRegistration" => nil,
          "agentBook" => nil
        }
      })
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

    for on <- [[], ["covered_calls"], ["exposure"], ["earn"], @features],
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

      # The auction counts tool gives its answer's data (`docs.md`, Hosted MCP).
      hosted =
        if operation == "autolaunch_auction_counts", do: by_page.body["data"], else: by_page.body

      assert tool(agent, operation) == {:ok, hosted}
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
      assert tool(agent, name, input) == answer(route), "#{name} #{inspect(input)}"
    end

    for {id, amount, max_price, status} <- [
          {active.id, "10", "4", 200},
          {active.id, "0", "4", 422},
          {active.id, "10", "x", 422},
          {unknown, "1", "1", 404}
        ] do
      body = %{amount: amount, max_price: max_price}
      route = http(:post, "/api/v1/auctions/#{id}/bid-quote", body)
      assert route.status == status, inspect(body)
      assert tool(agent, "autolaunch_bid_quote", Map.put(body, :id, id)) == answer(route)
    end
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

      assert tool(agent, read) == answer(http(:get, path, nil, agent))

      assert http(:patch, path, %{name: "Route", symbol: "RT"}, agent).status == 200
      assert {:ok, %{"data" => %{"name" => "Route"}}} = tool(agent, read)
      assert tool(agent, read) == answer(http(:get, path, nil, agent))

      assert {:ok, saved} = tool(agent, save, %{name: " Tool ", description: ""})
      assert {:ok, saved} == answer(http(:get, path, nil, agent))
      assert saved["data"]["name"] == "Tool"

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

      assert {:error, %{"error" => refusal}} =
               tool(agent, "autolaunch_#{kind}_draft_save", %{name: "Shut"})

      assert Map.take(refusal, ~w(code message)) ==
               Map.take(route.body["error"], ~w(code message))

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
      assert tool(agent, name) == {:ok, route.body}
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
      assert tool(agent, name) == {:error, route.body}
    end
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

  # A browser tool's or a command's request, such as `GET /api/v1/auction-counts`.
  defp request(route, signer) do
    [method, path] = String.split(route, " ")
    http(method |> String.downcase() |> String.to_existing_atom(), path, nil, signer)
  end

  # A paired agent's signing wallet.
  defp paired_agent do
    account = TestSupport.register_creator!()
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

  # The tool's result, or its error's text decoded: the route's error document.
  defp tool(agent, name, input \\ nil) do
    case json(mcp(agent, call(name, input)))["result"] do
      %{"isError" => false, "structuredContent" => answer} -> {:ok, answer}
      %{"isError" => true, "content" => [%{"text" => text}]} -> {:error, Jason.decode!(text)}
    end
  end

  defp tool_names(agent),
    do: json(mcp(agent, rpc("tools/list")))["result"]["tools"] |> Enum.map(& &1["name"])

  defp answer(%{status: 200, body: body}), do: {:ok, body}
  defp answer(%{body: body}), do: {:error, body}

  # An answer without the clock time each read of a series is stamped with.
  defp unclocked(%{} = map),
    do: for({k, v} <- map, k != "read_at", into: %{}, do: {k, unclocked(v)})

  defp unclocked(list) when is_list(list), do: Enum.map(list, &unclocked/1)
  defp unclocked({result, answer}), do: {result, unclocked(answer)}
  defp unclocked(value), do: value

  defp mcp(agent, body) do
    conn(:post, "/mcp", Jason.encode!(body))
    |> Map.put(:remote_ip, from())
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-siwa-signature", "fixture-proof")
    |> put_req_header("x-agent-wallet-address", agent)
    |> @endpoint.call([])
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
