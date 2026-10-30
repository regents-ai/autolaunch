defmodule AutolaunchWeb.CoveredCallsMcpTest do
  @moduledoc """
  Covered calls on the hosted MCP server: covered_call_book, covered_call_quote,
  covered_call_positions and prepare_covered_call run the same operations as
  the HTTP routes the browser tools call, so each answers with the route's
  `data`, and each refusal is the route's error, in the same code and words.
  Off, the tools are neither listed nor run. Positions and steps are for the
  paired agent's own person and only that person's wallets; an agent no person
  paired is refused. The chain is the covered-call double
  (`Autolaunch.CoveredCallsChain`) and the sign-in service is stubbed: it
  vouches for the wallet a request names.
  """
  use AutolaunchWeb.ConnCase, async: false
  use ExUnitProperties

  import Plug.Test, only: [conn: 3]

  alias Autolaunch.CoveredCalls.Terms
  alias Autolaunch.{CoveredCallsChain, TestSupport}

  @moduletag :capture_log
  @unit CoveredCallsChain.unit()
  @expiry hd(Terms.expiries(CoveredCallsChain.now()))
  @tools ~w(covered_call_book covered_call_quote covered_call_positions prepare_covered_call)

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

    %{from: {10, 2, :rand.uniform(250), :rand.uniform(250)}}
  end

  test "the public reads answer as their routes do, refusals included", %{from: from} do
    CoveredCallsChain.install()
    {agent, _wallet} = paired_agent()

    # Each reading names its own moment; everything else is the same.
    {:ok, book} = tool(from, agent, "covered_call_book", %{symbol: "AMZNc"})

    assert Map.delete(book, "read_at") ==
             Map.delete(http_data(from, :get, "/api/v1/covered-calls/AMZNc"), "read_at")

    quote = %{strike_per_token: 260_000_000, expiry: @expiry}

    assert tool(from, agent, "covered_call_quote", Map.put(quote, :symbol, "AMZNc")) ==
             {:ok, http_data(from, :post, "/api/v1/covered-calls/AMZNc/quote", quote)}

    for {name, input, method, path, body} <- [
          {"covered_call_book", %{symbol: "NOPEc"}, :get, "/api/v1/covered-calls/NOPEc", nil},
          {"covered_call_quote", %{symbol: "AMZNc", strike_per_token: 1, expiry: @expiry + 60},
           :post, "/api/v1/covered-calls/AMZNc/quote",
           %{strike_per_token: 1, expiry: @expiry + 60}},
          {"covered_call_quote", %{symbol: "AMZNc", strike_per_token: "1", expiry: @expiry},
           :post, "/api/v1/covered-calls/AMZNc/quote", %{strike_per_token: "1", expiry: @expiry}}
        ] do
      assert tool(from, agent, name, input) == {:error, http(from, method, path, body).body}
    end
  end

  property "a suggested premium answers through the hosted tool as through the route, whatever the strike and expiry",
           %{from: from} do
    CoveredCallsChain.install()
    {agent, _wallet} = paired_agent()

    check all(
            strike <- integer(1..1_000_000_000_000),
            expiry <- member_of([@expiry, @expiry + 3_600, @expiry - 7 * 86_400]),
            max_runs: 15
          ) do
      body = %{strike_per_token: strike, expiry: expiry}
      route = http(from, :post, "/api/v1/covered-calls/AMZNc/quote", body)
      answer = tool(from, agent, "covered_call_quote", Map.put(body, :symbol, "AMZNc"))

      assert answer ==
               if(route.status == 200, do: {:ok, route.body["data"]}, else: {:error, route.body})
    end
  end

  test "an agent's own covered calls answer as the signed route does", %{from: from} do
    CoveredCallsChain.install(%{held: 3 * @unit})
    {agent, wallet} = paired_agent()

    {:ok, mcp} = tool(from, agent, "covered_call_positions", %{symbol: "AMZNc"})

    route =
      http(from, :get, "/api/agent/v1/covered-calls/AMZNc/positions", nil, agent).body["data"]

    # Each reading names its own moment; everything else is the same.
    assert Map.delete(mcp, "read_at") == Map.delete(route, "read_at")
    assert mcp["wallet"] == String.downcase(wallet)
    assert [%{"held" => 300_000_000}] = mcp["holdings"]
  end

  test "every kind of step answers as the signed route does", %{from: from} do
    CoveredCallsChain.install(%{usdc_balance: 100_000_000})
    {agent, wallet} = paired_agent()

    for input <- [
          %{
            kind: "list",
            amount: 10 * @unit,
            strike_per_token: 250_000_000,
            premium_per_token: 5_000_000,
            expiry: @expiry
          },
          %{kind: "fill", listing_id: 1, amount: @unit},
          %{kind: "cancel", listing_id: 1},
          %{kind: "exercise", listing_id: 1, amount: @unit},
          %{kind: "claim", listing_id: 1},
          %{kind: "collect_strike", listing_id: 1, signer: wallet}
        ] do
      {:ok, mcp} = tool(from, agent, "prepare_covered_call", Map.put(input, :symbol, "AMZNc"))

      assert mcp ==
               http_data(from, :post, "/api/agent/v1/covered-calls/AMZNc/steps", input, agent)

      assert %{"kind" => kind, "signer" => signer, "steps" => [_ | _]} = mcp
      assert kind == input.kind and signer == String.downcase(wallet)
    end
  end

  test "a wallet that isn't the person's own is refused, as on the signed route", %{from: from} do
    CoveredCallsChain.install()
    {agent, _wallet} = paired_agent()

    input = %{
      kind: "fill",
      listing_id: 1,
      amount: @unit,
      signer: "0x" <> String.duplicate("ab", 20)
    }

    route = http(from, :post, "/api/agent/v1/covered-calls/AMZNc/steps", input, agent)
    assert route.status == 403
    assert route.body["error"]["code"] == "wrong_signer"

    assert tool(from, agent, "prepare_covered_call", Map.put(input, :symbol, "AMZNc")) ==
             {:error, route.body}
  end

  test "an agent no person paired is refused its covered calls and steps", %{from: from} do
    CoveredCallsChain.install()
    stranger = wallet()

    for {name, input} <- [
          {"covered_call_positions", %{symbol: "AMZNc"}},
          {"prepare_covered_call", %{symbol: "AMZNc", kind: "claim", listing_id: 1}}
        ] do
      refused = mcp(from, stranger, call(name, input))
      assert refused.status == 403
      assert json(refused)["error"]["code"] == "agent_not_paired"
    end
  end

  test "with covered calls on a paired agent lists the four tools; off, none is listed or run", %{
    from: from
  } do
    CoveredCallsChain.install()
    {agent, _wallet} = paired_agent()
    assert Enum.all?(@tools, &(&1 in tool_names(from, agent)))

    Application.put_env(:autolaunch, :covered_calls, :off)

    assert tool_names(from, agent) == ["autolaunch_auction_counts"]

    for name <- @tools do
      assert %{"error" => _} = json(mcp(from, agent, call(name, %{symbol: "AMZNc"})))
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
  defp http(from, method, path, body, agent \\ nil) do
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

  defp call(name, input),
    do: rpc("tools/call", %{"name" => name, "arguments" => %{"input" => input}})

  defp rpc(method, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

  defp json(conn), do: conn.resp_body |> IO.iodata_to_binary() |> Jason.decode!()

  defp wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end
