defmodule AutolaunchWeb.McpAgentTest do
  @moduledoc """
  The hosted MCP server at /mcp says who is calling as the agent access spec
  (4.3) sets out, through this site's own endpoint, router and actions, as the
  template's is:

  - every request carries an agent's signature or a connected app's token, never
    both, and a signature the sign-in service refuses is refused;
  - an agent no person paired is refused `agent_not_paired`, as on every signed
    route here; a paired agent lists and runs autolaunch_auction_counts, whose
    answer is the API's;
  - a query string, a page from another site, a batch, a body that is not JSON
    and any other method or address are refused in the site's shape, before any
    signature is checked;
  - input a tool cannot take gets the code HTTP gives it;
  - one address gets the API's 120 requests a minute, and requests with a token
    600;
  - a paired agent's answer is replaced when its pairing ended during the
    request.

  A connected app's own calls are in AutolaunchWeb.ClaudeConnectorTest. The
  sign-in service is stubbed: it vouches for the wallet a request names when the
  request carries the fixture proof. Each test calls from its own address, so it
  spends its own rate budgets, not the rest of the suite's.
  """
  use AutolaunchWeb.ConnCase, async: false
  use ExUnitProperties

  import Plug.Test, only: [conn: 3]

  alias Autolaunch.Actors.Agent
  alias Autolaunch.TestSupport
  alias AutolaunchWeb.Plugs.AgentAccess

  @moduletag :capture_log

  setup do
    test = self()

    Req.Test.stub(RegentAgents.Broker, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      headers = Jason.decode!(body)["headers"]
      send(test, :asked_sign_in_service)

      if headers["x-siwa-signature"] == "fixture-proof" do
        wallet = headers["x-agent-wallet-address"]

        Req.Test.json(conn, %{
          code: "http_envelope_valid",
          data: %{
            verified: true,
            walletAddress: wallet,
            agentBook: nil,
            agentRegistration: nil,
            principal: %{
              kind: "wallet",
              wallet_address: wallet,
              chain_id: 8453,
              audience: "autolaunch"
            }
          }
        })
      else
        conn
        |> put_status(401)
        |> Req.Test.json(%{
          error: %{
            code: "http_signature_invalid",
            message: "Signature invalid",
            hint: "Sign again"
          }
        })
      end
    end)

    %{from: {10, :rand.uniform(250), :rand.uniform(250), :rand.uniform(250)}}
  end

  test "a signature and a token together are refused, and a token alone while connecting apps is off",
       %{from: from} do
    both = mcp(call("autolaunch_auction_counts"), from: from, proof: wallet(), token: "a-token")
    assert both.status == 401
    assert error(both)["code"] == "ambiguous_credentials"

    token = mcp(call("autolaunch_auction_counts"), from: from, token: "a-token")
    assert token.status == 401
    assert error(token)["code"] == "delegated_access_not_enabled"
    assert get_resp_header(token, "www-authenticate") == []
  end

  test "a signature the sign-in service refuses is refused, even for a read", %{from: from} do
    refused =
      mcp(call("autolaunch_auction_counts"), from: from, proof: wallet(), signature: "forged")

    assert refused.status == 401
    assert error(refused)["code"] == "http_signature_invalid"
  end

  test "an agent no person paired is refused, as on every signed route here", %{from: from} do
    refused = mcp(rpc("tools/list"), from: from, proof: wallet())
    assert refused.status == 403
    assert error(refused)["code"] == "agent_not_paired"
    assert error(refused)["hint"] =~ "Pair New Agent"
  end

  test "a paired agent lists and reads the auction counts, with the API's answer", %{from: from} do
    agent = paired_wallet()

    listed = mcp(rpc("tools/list"), from: from, proof: agent)
    assert listed.status == 200
    assert get_resp_header(listed, "cache-control") == ["private, no-store"]
    assert Enum.map(result(listed)["tools"], & &1["name"]) == ["autolaunch_auction_counts"]

    read = mcp(call("autolaunch_auction_counts"), from: from, proof: agent)
    assert %{"isError" => false, "structuredContent" => counts} = result(read)

    assert counts ==
             build_conn()
             |> get("/api/v1/auction-counts")
             |> json_response(200)
             |> Map.get("data")
  end

  test "every request needs a signature or a token, from the first one on", %{from: from} do
    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "t", "version" => "1"}
      }
    }

    for body <- [initialize, rpc("tools/list"), call("autolaunch_auction_counts")] do
      refused = mcp(body, from: from)
      assert refused.status == 401
      assert error(refused)["code"] == "agent_auth_required"
      assert get_resp_header(refused, "www-authenticate") == []
    end
  end

  property "a query string or a page from another site is refused before any signature is checked",
           %{from: from} do
    check all(
            query <- string(:alphanumeric, min_length: 1, max_length: 20),
            host <- string(:alphanumeric, min_length: 1, max_length: 20),
            credential <- member_of([[], [proof: wallet()], [token: "a-token"]]),
            max_runs: 20
          ) do
      queried = mcp(call("autolaunch_auction_counts"), [from: from, query: query] ++ credential)
      assert queried.status == 400
      assert error(queried)["code"] == "unsupported_query"

      foreign =
        mcp(
          call("autolaunch_auction_counts"),
          [from: from, origin: "https://#{host}.example"] ++ credential
        )

      assert foreign.status == 403
      assert error(foreign)["code"] == "origin_not_allowed"
      refute_received :asked_sign_in_service
    end
  end

  test "this site's own page, or no page, may call it", %{from: from} do
    agent = paired_wallet()
    read = call("autolaunch_auction_counts")

    null = mcp(read, from: from, origin: "null", proof: agent)
    assert error(null)["code"] == "origin_not_allowed"

    own = mcp(read, from: from, origin: AutolaunchWeb.PublicDocuments.url(""), proof: agent)
    assert %{"isError" => false} = result(own)

    none = mcp(read, from: from, proof: agent)
    assert %{"isError" => false} = result(none)
  end

  test "one call a request: a batch is refused, and the 2026-07-28 profile reads", %{from: from} do
    agent = paired_wallet()

    batch = mcp([call("autolaunch_auction_counts"), rpc("tools/list")], from: from, proof: agent)
    assert batch.status == 400
    assert error(batch)["code"] == "batch_not_supported"

    read =
      mcp(profile(call("autolaunch_auction_counts")),
        from: from,
        proof: agent,
        profile: "autolaunch_auction_counts"
      )

    assert %{"isError" => false, "structuredContent" => %{"revstake" => _}} = result(read)
  end

  test "input a tool cannot take is refused with the HTTP code, never a placeholder", %{
    from: from
  } do
    agent = paired_wallet()

    for input <- [%{chain: "base"}, "base", [1]] do
      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               result(mcp(call("autolaunch_auction_counts", input), from: from, proof: agent))

      refute text =~ "%{"
      assert Jason.decode!(text)["error"]["code"] == "invalid_request"
    end
  end

  test "only POST /mcp is served; anything else answers in the site's shape", %{from: from} do
    for {method, path} <- [
          {:options, "/mcp"},
          {:put, "/mcp"},
          {:get, "/mcp"},
          {:post, "/mcp/anything"}
        ] do
      answer =
        conn(method, path, "{}")
        |> Map.put(:remote_ip, from)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> @endpoint.call([])

      assert answer.status in [404, 405]
      assert %{"code" => _, "message" => _, "hint" => _} = error(answer)
    end

    form =
      conn(:post, "/mcp", "jsonrpc=2.0&method=tools%2Flist")
      |> Map.put(:remote_ip, from)
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("accept", "application/json")
      |> put_req_header("x-siwa-signature", "fixture-proof")
      |> put_req_header("x-agent-wallet-address", wallet())
      |> @endpoint.call([])

    assert form.status == 415
    assert %{"code" => "unsupported_media_type", "hint" => hint} = error(form)
    assert hint =~ AutolaunchWeb.PublicDocuments.url("/docs")

    {413, _headers, body} =
      assert_error_sent(413, fn ->
        conn(:post, "/mcp", Jason.encode!(%{"padding" => String.duplicate("a", 20_000)}))
        |> Map.put(:remote_ip, from)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> @endpoint.call([])
      end)

    assert Jason.decode!(body)["error"]["hint"] =~ AutolaunchWeb.PublicDocuments.url("/docs")
  end

  test "a GET for an event stream is answered 405, and a body that is not JSON 415, whatever it accepts",
       %{from: from} do
    stream =
      conn(:get, "/mcp", nil)
      |> Map.put(:remote_ip, from)
      |> put_req_header("accept", "text/event-stream")
      |> @endpoint.call([])

    assert stream.status == 405
    assert get_resp_header(stream, "allow") == ["POST"]
    assert %{"code" => "method_not_allowed"} = error(stream)

    form =
      conn(:post, "/mcp", "jsonrpc=2.0&method=tools%2Flist")
      |> Map.put(:remote_ip, from)
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("accept", "text/event-stream")
      |> @endpoint.call([])

    assert form.status == 415
    assert %{"code" => "unsupported_media_type"} = error(form)
  end

  test "one address gets 120 requests a minute here, as on the API", %{from: from} do
    statuses = for _ <- 1..121, do: mcp(rpc("tools/list"), from: from).status
    assert Enum.take(statuses, 120) |> Enum.uniq() == [401]
    assert List.last(statuses) == 429
  end

  test "requests with a token share 600 a minute from one address, Claude's servers among them",
       %{from: from} do
    statuses =
      for _ <- 1..601, do: mcp(rpc("tools/list"), from: from, token: "not-a-token").status

    assert Enum.take(statuses, 600) |> Enum.uniq() == [401]
    assert List.last(statuses) == 429
    assert mcp(rpc("tools/list"), from: from).status == 401
  end

  test "a paired agent's answer is replaced when its pairing ended during the request" do
    agent = paired_wallet()
    {:ok, actor, _account} = Autolaunch.Agents.resolve(agent)

    [paired] =
      RegentAgents.list_my_agents!(
        actor: %RegentAgents.Person{privy_user_id: actor.privy_user_id}
      )

    :ok =
      RegentAgents.unpair_agent!(paired,
        actor: %RegentAgents.Person{privy_user_id: actor.privy_user_id}
      )

    answered =
      conn(:get, "/", nil)
      |> AgentAccess.recheck_before_send(actor)
      |> send_resp(200, ~s({"data": "the person's"}))

    assert answered.status == 403
    assert %{"code" => "agent_not_paired"} = error(answered)

    # Still paired with the same person: the answer leaves as it is.
    still = paired_wallet()
    {:ok, %Agent{} = current, _account} = Autolaunch.Agents.resolve(still)

    kept =
      conn(:get, "/", nil)
      |> AgentAccess.recheck_before_send(current)
      |> send_resp(200, ~s({"data": "the person's"}))

    assert kept.status == 200
  end

  defp mcp(body, opts) do
    path = if opts[:query], do: "/mcp?" <> opts[:query], else: "/mcp"

    conn(:post, path, Jason.encode!(body))
    |> Map.put(:remote_ip, Keyword.fetch!(opts, :from))
    |> then(&if(opts[:origin], do: put_req_header(&1, "origin", opts[:origin]), else: &1))
    |> then(&if(opts[:profile], do: profile_headers(&1, body, opts[:profile]), else: &1))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> then(
      &if(opts[:proof],
        do:
          &1
          |> put_req_header("x-siwa-signature", opts[:signature] || "fixture-proof")
          |> put_req_header("x-agent-wallet-address", opts[:proof]),
        else: &1
      )
    )
    |> then(
      &if(opts[:token],
        do: put_req_header(&1, "authorization", "Bearer " <> opts[:token]),
        else: &1
      )
    )
    |> @endpoint.call([])
  end

  # A tool listed with no inputs is called with empty arguments; one given input
  # takes it under `input`.
  defp call(name), do: rpc("tools/call", %{"name" => name, "arguments" => %{}})

  defp call(name, input),
    do: rpc("tools/call", %{"name" => name, "arguments" => %{"input" => input}})

  defp rpc(method, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

  # A call as the 2026-07-28 profile sends it: its version and capabilities in
  # `_meta`, and the same version, method and tool in the headers.
  defp profile(%{"params" => params} = call) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    %{call | "params" => Map.put(params, "_meta", meta)}
  end

  defp profile_headers(conn, %{"method" => method}, name) do
    conn
    |> put_req_header("mcp-protocol-version", "2026-07-28")
    |> put_req_header("mcp-method", method)
    |> put_req_header("mcp-name", name)
  end

  defp result(conn), do: json(conn)["result"]
  defp error(conn), do: json(conn)["error"]
  defp json(conn), do: conn.resp_body |> IO.iodata_to_binary() |> Jason.decode!()

  # An agent's wallet, paired with a person's account here.
  defp paired_wallet do
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

  defp wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end
