defmodule AutolaunchWeb.EarnMcpTest do
  @moduledoc """
  Earn on the hosted MCP server: earn_products, earn_quote, earn_positions and
  prepare_earn run the same operations as the HTTP routes the browser tools
  call, so each answers with the route's `data`, block included, and each
  refusal is the route's error, in the same code and words. Off, the tools are
  neither listed nor run; in prelaunch read-only mode the steps are neither.
  The chain is the Earn double (`Autolaunch.EarnChain`) and the sign-in
  service is stubbed: it vouches for the wallet a request names.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Plug.Test, only: [conn: 3]

  alias Autolaunch.{EarnChain, TestSupport}

  @moduletag :capture_log
  @unit EarnChain.unit()
  @tools ~w(earn_products earn_quote earn_positions prepare_earn)

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

    # Past the prelaunch gate, which refuses wallet steps on the HTTP route
    # until the site opens.
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)

    EarnChain.install(%{balance: 40 * @unit, allowance: 10 * @unit})
    %{from: {10, 3, :rand.uniform(250), :rand.uniform(250)}}
  end

  test "every tool answers as its route does, with the block it was read at", %{from: from} do
    {agent, wallet} = paired_agent()

    {:ok, products} = tool(from, agent, "earn_products", nil)
    assert products == http_data(from, :get, "/api/v1/earn/products")
    assert [%{"block" => %{"number" => 0x20}}] = products["products"]

    {:ok, positions} = tool(from, agent, "earn_positions", nil)
    assert positions == http_data(from, :get, "/api/agent/v1/earn/positions", nil, agent)
    assert positions["wallet"] == String.downcase(wallet)
    assert [%{"balance" => 40_000_000, "block" => %{"number" => 0x20}}] = positions["positions"]

    for input <- [
          %{product: "aave-usdc", kind: "deposit", amount: 10 * @unit},
          %{product: "aave-usdc", kind: "deposit", amount: 11 * @unit},
          %{product: "aave-usdc", kind: "withdraw", amount: 5 * @unit},
          %{product: "aave-usdc", kind: "withdraw", everything: true, signer: wallet}
        ] do
      {:ok, quote} = tool(from, agent, "earn_quote", input)
      assert quote == http_data(from, :post, "/api/agent/v1/earn/quote", input, agent)

      {:ok, prepared} = tool(from, agent, "prepare_earn", input)
      assert prepared == http_data(from, :post, "/api/agent/v1/earn/steps", input, agent)
      assert %{"block" => %{"number" => 0x20}, "steps" => [_ | _]} = prepared
    end
  end

  test "each refusal is the route's error, in the same code and words", %{from: from} do
    {agent, _wallet} = paired_agent()

    for input <- [
          %{product: "nope", kind: "deposit", amount: 1},
          %{product: "aave-usdc", kind: "borrow", amount: 1},
          %{product: "aave-usdc", kind: "deposit", amount: 0},
          %{product: "aave-usdc", kind: "deposit", amount: "1"},
          %{product: "aave-usdc", kind: "deposit", everything: true},
          %{product: "aave-usdc", kind: "withdraw", amount: 1, everything: true},
          %{
            product: "aave-usdc",
            kind: "withdraw",
            amount: 1,
            signer: "0x" <> String.duplicate("ab", 20)
          }
        ],
        {name, path} <- [
          {"earn_quote", "/api/agent/v1/earn/quote"},
          {"prepare_earn", "/api/agent/v1/earn/steps"}
        ] do
      route = http(from, :post, path, input, agent)
      assert route.status in [403, 404, 422], "#{path} #{inspect(input)} answered #{route.status}"
      assert tool(from, agent, name, input) == {:error, route.body}, "#{name} #{inspect(input)}"
    end

    EarnChain.put(%{unreadable: true})

    route = http(from, :get, "/api/v1/earn/products")
    assert route.status == 503 and route.body["error"]["code"] == "chain_unavailable"
    assert tool(from, agent, "earn_products", nil) == {:error, route.body}
  end

  test "an agent no person paired is refused its balances, preview and steps", %{from: from} do
    stranger = wallet()

    for {name, input} <- [
          {"earn_positions", nil},
          {"earn_quote", %{product: "aave-usdc", kind: "deposit", amount: 1}},
          {"prepare_earn", %{product: "aave-usdc", kind: "deposit", amount: 1}}
        ] do
      refused = mcp(from, stranger, call(name, input))
      assert refused.status == 403
      assert json(refused)["error"]["code"] == "agent_not_paired"
    end
  end

  test "with Earn on a paired agent lists the four tools; off, none is listed or run", %{
    from: from
  } do
    {agent, _wallet} = paired_agent()
    assert Enum.all?(@tools, &(&1 in tool_names(from, agent)))

    Application.put_env(:autolaunch, :earn, :off)
    refute Enum.any?(@tools, &(&1 in tool_names(from, agent)))

    for name <- @tools do
      assert %{"error" => _} =
               json(
                 mcp(from, agent, call(name, %{product: "aave-usdc", kind: "deposit", amount: 1}))
               )
    end
  end

  test "in prelaunch read-only mode the steps are neither listed nor run, while the preview is",
       %{
         from: from
       } do
    {agent, _wallet} = paired_agent()
    Application.put_env(:autolaunch, :prelaunch_read_only, true)
    input = %{product: "aave-usdc", kind: "deposit", amount: @unit}

    route = http(from, :post, "/api/agent/v1/earn/steps", input, agent)
    assert route.status == 503 and route.body["error"]["code"] == "prelaunch_read_only"

    listed = tool_names(from, agent)
    refute "prepare_earn" in listed
    assert Enum.all?(@tools -- ["prepare_earn"], &(&1 in listed))
    assert %{"error" => _} = json(mcp(from, agent, call("prepare_earn", input)))

    {:ok, quote} = tool(from, agent, "earn_quote", input)
    assert quote == http_data(from, :post, "/api/agent/v1/earn/quote", input, agent)
  end

  test "the guides name the hosted Earn tools only while Earn is open" do
    Application.put_env(:autolaunch, :earn, :off)

    for path <- ["/llms.txt", "/llms-full.txt", "/docs"] do
      refute build_conn() |> get(path) |> response(200) =~ "prepare_earn"
    end

    Application.put_env(:autolaunch, :earn, :on)

    for path <- ["/llms.txt", "/llms-full.txt", "/docs"] do
      assert build_conn() |> get(path) |> response(200) =~ "prepare_earn", path
    end
  end

  # A paired agent's signing wallet, and the one wallet of the person it acts for.
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

    {agent, account.wallet_address}
  end

  # The tool's result, or its error's text decoded: the route's error document.
  defp tool(from, agent, name, input) do
    case json(mcp(from, agent, call(name, input)))["result"] do
      %{"isError" => false, "structuredContent" => answer} ->
        {:ok, answer}

      %{"isError" => true, "content" => [%{"text" => text}]} ->
        {:error, Jason.decode!(text)}
    end
  end

  defp tool_names(from, agent),
    do: json(mcp(from, agent, rpc("tools/list")))["result"]["tools"] |> Enum.map(& &1["name"])

  defp mcp(from, agent, body) do
    conn(:post, "/mcp", Jason.encode!(body))
    |> Map.put(:remote_ip, from)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-siwa-signature", "fixture-proof")
    |> put_req_header("x-agent-wallet-address", agent)
    |> @endpoint.call([])
  end

  defp http_data(from, method, path, body \\ nil, agent \\ nil) do
    answer = http(from, method, path, body, agent)
    assert answer.status == 200, inspect(answer.body)
    answer.body["data"]
  end

  # One HTTP request from `from`: anonymous, or signed by `agent`.
  defp http(from, method, path, body \\ nil, agent \\ nil) do
    conn =
      conn(method, path, body && Jason.encode!(body))
      |> Map.put(:remote_ip, from)
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

  defp json(conn), do: conn.resp_body |> IO.iodata_to_binary() |> Jason.decode!()

  defp wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end
