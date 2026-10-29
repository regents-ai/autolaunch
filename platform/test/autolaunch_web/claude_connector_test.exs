defmodule AutolaunchWeb.ClaudeConnectorTest do
  @moduledoc """
  The Claude connector through this site's own endpoint, router, sign-in and
  agent records, as the template's is: off, nothing about agents changes; on,
  one connected account pairs one hosted agent, checks in, and loses access when
  it disconnects; with the agent permission, a paired app works here as its
  agent. The hosted signer and the SIWA service are stubbed; the rest is the
  site's.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Plug.Test, only: [conn: 3]

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.System, as: SystemActor
  alias RegentAgents.Harness

  @moduletag :capture_log
  @wallet "0x2222222222222222222222222222222222222222"
  @site_key String.duplicate("k", 32)
  @signed %{
    "x-siwa-signature" => "sig1=:c2lnbmVk:",
    "x-siwa-signature-input" =>
      ~s|sig1=("@method" "@path");created=1;expires=2;nonce="n";keyid="k"|,
    "x-siwa-receipt" => "receipt",
    "x-key-id" => "k",
    "x-timestamp" => "1",
    "x-agent-wallet-address" => @wallet,
    "x-agent-chain-id" => "8453"
  }
  # Every request the hosted signer may be asked to sign for this site.
  @agent_scopes "regent.identity.manage " <> Autolaunch.OAuth.agent_scope()
  @signable [
    {"GET", "/api/agents/v1/whoami"},
    {"GET", "/api/agents/v1/me"},
    {"POST", "/api/agents/v1/pair"}
  ]

  setup do
    test = self()

    # The SIWA service verifies every signed request as the one hosted wallet's.
    Req.Test.stub(RegentAgents.Broker, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:verify, conn.req_headers, body, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "code" => "http_envelope_valid",
        "data" => %{
          "verified" => true,
          "principal" => %{
            "kind" => "wallet",
            "wallet_address" => @wallet,
            "chain_id" => 8453,
            "audience" => "autolaunch"
          },
          "agentRegistration" => nil,
          "agentBook" => nil
        }
      })
    end)

    # Each test calls from its own address, so it spends its own rate budgets.
    Process.put(:from, {10, 1, :rand.uniform(250), :rand.uniform(250)})
    :ok
  end

  describe "with the connector off, as config/test.exs and production leave it" do
    test "its sign-in is not found, /mcp takes no app's token, and Claude is neither offered nor shown" do
      for token <- ["any-token", nil] do
        refused = post_mcp(rpc("ping"), token)
        assert refused.status == 401
        assert get_resp_header(refused, "www-authenticate") == []
      end

      assert endpoint(conn(:get, "/.well-known/oauth-authorization-server", nil)).status == 404
      assert endpoint(conn(:post, "/oauth/register", %{})).status == 404
      refute :claude in Harness.offered()

      claude =
        endpoint(conn(:get, "/agents/claude", nil) |> put_req_header("accept", "text/html"))

      assert claude.status == 404

      guide = build_conn() |> get("/llms.txt") |> response(200)
      refute guide =~ "/agents/claude"
      assert guide =~ "/mcp"
      refute build_conn() |> get("/sitemap.xml") |> response(200) =~ "/agents/claude"
    end

    test "an agent's sign-in and pairing work as before, and a Claude pairing is refused" do
      subject = "did:privy:connector-off-#{System.unique_integer([:positive])}"
      sign_in!(subject)

      whoami = signed(:get, "/api/agents/v1/whoami")
      assert whoami.status == 200
      assert Jason.decode!(whoami.resp_body)["data"]["status"] == "not_paired"

      refused = pair_request(code!(subject), "claude")
      assert refused.status in 400..499
      assert agents(subject) == []

      paired = pair_request(code!(subject), "codex")
      assert paired.status in 200..201, paired.resp_body
      assert [%{harness: :codex, wallet: @wallet}] = agents(subject)
    end
  end

  describe "with the connector on" do
    setup :connector_on

    test "Claude is offered in the pairing box, and its page and guide lines are shown" do
      assert :claude in Harness.offered()

      claude = build_conn() |> put_req_header("accept", "text/markdown") |> get("/agents/claude")
      assert response(claude, 200) =~ "/mcp"

      assert build_conn() |> get("/agents/claude") |> html_response(200) =~ "Pair New Agent"

      for path <- ["/llms.txt", "/agents.md"] do
        assert build_conn() |> get(path) |> response(200) =~ "/agents/claude"
      end

      assert build_conn() |> get("/sitemap.xml") |> response(200) =~ "/agents/claude"
    end

    test "pair_identity makes one paired agent of the authorizing account, from that account's own code only" do
      subject = subject!()
      %{access: token} = connect!(subject)

      # Another account's code is refused before anything is signed.
      other = subject!()
      assert %{"isError" => true} = tool(token, "pair_identity", pair_args(code!(other)))
      assert signer_asks() == []
      assert agents(subject) == [] and agents(other) == []

      arguments = pair_args(code!(subject))
      assert %{"isError" => false} = tool(token, "pair_identity", arguments)

      # The POST the hosted signer signed is verified with its exact body.
      assert [%{"operation" => "sign", "request" => signed}] =
               for({_, _, %{"operation" => "sign"} = ask} <- signer_asks(), do: ask)

      assert {signed["method"], signed["path"]} == {"POST", "/api/agents/v1/pair"}
      assert Jason.decode!(signed["body"]) == arguments
      assert_received {:verify, _headers, _raw, payload}
      assert payload["body_digest"] == Siwa.content_digest_for_body(signed["body"])

      assert [%{harness: :claude, wallet: @wallet, name: "Claude"}] = agents(subject)
    end

    test "a first request with no token is asked to connect, so the app starts its sign-in" do
      for body <- [rpc("initialize", %{"protocolVersion" => "2025-06-18"}), rpc("tools/list")] do
        refused = post_mcp(body, nil)
        assert refused.status == 401
        assert json(refused)["error"]["code"] == "connection_required"

        assert get_resp_header(refused, "www-authenticate") ==
                 [RegentOAuth.challenge(Enum.join(RegentOAuth.scopes(), " "))]
      end
    end

    test "pair_identity takes what the library takes, and input it cannot take gets the library's pairing refusal" do
      subject = subject!()
      %{access: token} = connect!(subject)

      listed = json(post_mcp(rpc("tools/list"), token))["result"]["tools"]

      schema =
        Enum.find(listed, &(&1["name"] == "pair_identity"))["inputSchema"]["properties"]["input"]

      assert schema["properties"]["harness"]["enum"] == RegentMCPAgents.hosted_names()
      assert Enum.sort(schema["required"]) == ["code", "harness", "name"]

      for args <- [
            %{pair_args("A-CODE") | "name" => String.duplicate("n", 101)},
            %{pair_args("A-CODE") | "code" => String.duplicate("c", 129)},
            %{pair_args("A-CODE") | "harness" => "codex"},
            Map.delete(pair_args("A-CODE"), "name")
          ] do
        assert %{"isError" => true, "content" => [%{"text" => text}]} =
                 tool(token, "pair_identity", args)

        refute text =~ "%{"
        assert Jason.decode!(text)["error"]["code"] == "invalid_request"
      end

      assert agents(subject) == []
    end

    test "a signer that asks for a wait gives pair_identity the seconds to wait" do
      subject = subject!()
      %{access: token} = connect!(subject)

      Req.Test.stub(RegentMCPAgents.HostedSigner, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case Jason.decode!(body) do
          %{"operation" => "register"} ->
            Req.Test.json(conn, %{"address" => @wallet})

          %{"operation" => "sign"} ->
            conn
            |> put_resp_header("retry-after", "45")
            |> put_status(429)
            |> Req.Test.json(%{})
        end
      end)

      assert %{"isError" => true, "content" => [%{"text" => text}]} =
               tool(token, "pair_identity", pair_args(code!(subject)))

      assert %{"code" => "too_many_requests", "retry_after" => 45} = Jason.decode!(text)["error"]
      assert agents(subject) == []
    end

    test "a connected app lists and runs only its identity tools, never the auction counts" do
      subject = subject!()
      %{access: token} = connect!(subject)

      listed = json(post_mcp(rpc("tools/list"), token))["result"]["tools"]
      assert Enum.sort(Enum.map(listed, & &1["name"])) == Enum.sort(RegentMCPAgents.Tools.names())

      assert %{"error" => _} = json(post_mcp(counts_call(), token))
      assert signer_asks() == []
    end

    test "the hosted signer signs only the identity requests, as the account's one identity, and the connection's token stays here" do
      subject = subject!()
      %{access: token} = connect!(subject)

      assert %{"isError" => false} = tool(token, "register_identity")
      assert %{"isError" => false} = tool(token, "get_identity")
      assert %{"isError" => false} = tool(token, "pair_identity", pair_args(code!(subject)))

      # A call may also leave arguments out.
      assert %{"isError" => false} =
               json(post_mcp(rpc("tools/call", %{"name" => "check_in"}), token))["result"]

      assert %{"error" => _} = json(post_mcp(rpc("tools/call", %{"name" => "post"}), token))

      key = RegentMCPAgents.identity_key("autolaunch", subject)
      asked = signer_asks()

      for {auth, raw, ask} <- asked do
        assert auth == ["Bearer " <> @site_key]
        assert ask["identity_key"] == key
        refute raw =~ token
      end

      signed = for {_, _, %{"operation" => "sign", "request" => r}} <- asked, do: r
      assert length(signed) == 3
      assert Enum.map(signed, &{&1["method"], &1["path"]}) -- @signable == []

      for _ <- signed do
        assert_received {:verify, headers, raw, _payload}
        refute raw =~ token
        refute Enum.any?(headers, fn {_name, value} -> value =~ token end)
      end
    end

    test "reconnecting or refreshing keeps the one hosted identity and the one agent" do
      subject = subject!()
      first = connect!(subject)

      assert %{"isError" => false} =
               tool(first.access, "pair_identity", pair_args(code!(subject)))

      [%{id: agent_id}] = agents(subject)

      again = connect!(subject)
      assert {200, %{"access_token" => refreshed}} = refresh(first.client_id, first.refresh)

      for token <- [again.access, refreshed] do
        assert %{"structuredContent" => %{"paired" => true, "identity_id" => id}} =
                 tool(token, "get_identity")

        assert id == RegentMCPAgents.identity_key("autolaunch", subject)
        assert %{"isError" => false} = tool(token, "check_in")
      end

      assert [%{id: ^agent_id}] = agents(subject)
    end

    test "only a check-in moves when the agent was last in touch" do
      subject = subject!()
      %{client_id: client, access: token, refresh: refresh_token} = connect!(subject)
      assert %{"isError" => false} = tool(token, "pair_identity", pair_args(code!(subject)))
      [%{last_contact_at: paired_at}] = agents(subject)

      assert post_mcp(rpc("initialize", %{"protocolVersion" => "2025-06-18"}), token).status ==
               200

      assert post_mcp(rpc("ping"), token).status == 200
      assert {200, %{"access_token" => refreshed}} = refresh(client, refresh_token)
      assert %{"isError" => false} = tool(refreshed, "get_identity")
      assert %{"isError" => false} = tool(refreshed, "register_identity")
      assert [%{last_contact_at: ^paired_at}] = agents(subject)

      assert %{"isError" => false} = tool(refreshed, "check_in")
      assert [%{last_contact_at: checked_in}] = agents(subject)
      assert DateTime.after?(checked_in, paired_at)
    end

    test "unpairing on the Account page holds: a check-in is refused and pairs nothing again" do
      subject = subject!()
      %{access: token} = connect!(subject)
      assert %{"isError" => false} = tool(token, "pair_identity", pair_args(code!(subject)))
      [agent] = agents(subject)

      :ok = RegentAgents.unpair_agent!(agent, actor: person(subject))

      assert %{"isError" => true} = tool(token, "check_in")
      assert %{"structuredContent" => %{"paired" => false}} = tool(token, "get_identity")
      assert agents(subject) == []
    end

    test "disconnecting at Connected apps revokes the app's tokens: its next call is asked to sign in" do
      subject = subject!()
      account = account(subject)
      %{client_id: client, access: token, refresh: refresh_token} = connect!(subject)
      assert %{"isError" => false} = tool(token, "register_identity")

      csrf = Plug.CSRFProtection.get_csrf_token()

      revoked =
        build_conn()
        |> init_test_session(%{
          human_account_id: account.id,
          _csrf_token: Plug.CSRFProtection.dump_state()
        })
        |> put_req_header("accept", "text/html")
        |> post("/oauth/connections/revoke", %{"client_id" => client, "_csrf_token" => csrf})

      assert revoked.status == 303
      assert get_resp_header(revoked, "location") == ["/oauth/connections"]

      refused = post_mcp(rpc("tools/call", %{"name" => "check_in", "arguments" => %{}}), token)
      assert refused.status == 401
      assert [_challenge] = get_resp_header(refused, "www-authenticate")
      assert {400, %{"error" => "invalid_grant"}} = refresh(client, refresh_token)
    end
  end

  describe "with the connector on and the agent permission" do
    setup :connector_on

    test "a paired account's app lists the auction counts and reads them as its agent" do
      subject = subject!()
      %{access: token} = connect!(subject, @agent_scopes)
      assert %{"isError" => false} = tool(token, "pair_identity", pair_args(code!(subject)))
      assert "autolaunch_auction_counts" in tool_names(token)
      assert %{"isError" => false, "structuredContent" => counts} = counts(token)

      assert counts ==
               build_conn()
               |> get("/api/v1/auction-counts")
               |> json_response(200)
               |> Map.fetch!("data")
    end

    test "a token without the agent permission stays the app, paired or not" do
      subject = subject!()
      %{access: token} = connect!(subject)
      assert %{"isError" => false} = tool(token, "pair_identity", pair_args(code!(subject)))
      refute "autolaunch_auction_counts" in tool_names(token)
    end

    test "another account's token never acts as the first account's paired agent" do
      paired = subject!()
      other = subject!()
      %{access: first} = connect!(paired, @agent_scopes)
      assert %{"isError" => false} = tool(first, "pair_identity", pair_args(code!(paired)))

      # The hosted signer answers every account with the same wallet, paired to the first.
      %{access: token} = connect!(other, @agent_scopes)
      refute "autolaunch_auction_counts" in tool_names(token)
      assert %{"error" => _} = json(post_mcp(counts_call(), token))
    end

    test "unpairing takes the auction counts away on the next call" do
      subject = subject!()
      %{access: token} = connect!(subject, @agent_scopes)
      assert %{"isError" => false} = tool(token, "pair_identity", pair_args(code!(subject)))
      assert %{"isError" => false} = counts(token)

      [agent] = agents(subject)
      :ok = RegentAgents.unpair_agent!(agent, actor: person(subject))
      refute "autolaunch_auction_counts" in tool_names(token)
    end

    test "working as its agent never moves when the agent was last in touch" do
      subject = subject!()
      %{access: token} = connect!(subject, @agent_scopes)
      assert %{"isError" => false} = tool(token, "pair_identity", pair_args(code!(subject)))
      [%{last_contact_at: paired_at}] = agents(subject)

      assert post_mcp(rpc("ping"), token).status == 200
      assert "autolaunch_auction_counts" in tool_names(token)
      assert %{"isError" => false} = counts(token)
      assert [%{last_contact_at: ^paired_at}] = agents(subject)
    end

    test "the hosted signer is asked for the account's address once, not on every call" do
      subject = subject!()
      %{access: token} = connect!(subject, @agent_scopes)
      for _ <- 1..3, do: post_mcp(rpc("ping"), token)
      assert Enum.count(signer_asks(), &match?({_, _, %{"operation" => "register"}}, &1)) <= 1
    end

    test "while the hosted signer is down, it is asked once for many calls" do
      subject = subject!()
      %{access: token} = connect!(subject, @agent_scopes)
      test = self()

      Req.Test.stub(RegentMCPAgents.HostedSigner, fn conn ->
        send(test, :signer_down)
        conn |> put_status(503) |> Req.Test.json(%{})
      end)

      for _ <- 1..5 do
        refused = post_mcp(rpc("ping"), token)
        assert refused.status == 503
        assert json(refused)["error"]["code"] == "identity_unavailable"
      end

      assert down_asks() == 1
    end
  end

  # Switches the connector on for one test as config/runtime.exs does with
  # AUTOLAUNCH_CLAUDE_CONNECTOR_ENABLED=true, and starts its sign-in store in
  # this test's transaction; everything is put back after. RegentMCPAgents'
  # boot check (`configure!/0`) is left out: at the pinned elixir-utils it knows
  # only the patchbay, keyfleet and ash-template audiences, so it refuses
  # "autolaunch", and the switch stays off in production until it knows this one.
  defp connector_on(_context) do
    origin = "http://127.0.0.1:4002"

    put_env(
      :autolaunch,
      Autolaunch.OAuth,
      Keyword.merge(Application.fetch_env!(:autolaunch, Autolaunch.OAuth),
        enabled?: true,
        issuer: origin,
        resource: origin <> "/mcp"
      )
    )

    put_env(
      :regent_mcp_agents,
      :config,
      Keyword.merge(Application.fetch_env!(:regent_mcp_agents, :config),
        enabled?: true,
        hosted_signer: [base_url: "https://siwa.test", key: @site_key]
      )
    )

    put_env(:regent_agents, :hosted_pairing, [:claude])
    put_env(:regent_mcp_agents, :req_options, plug: {Req.Test, RegentMCPAgents.HostedSigner})
    for key <- [RegentOAuth.Repo, :site, :prefix], do: keep_env(:regent_oauth, key)
    keep_env(:boruta, Boruta.Oauth)

    :ok = RegentOAuth.configure(Autolaunch.OAuth)

    Application.put_env(
      :regent_oauth,
      RegentOAuth.Repo,
      Keyword.put(
        Application.fetch_env!(:regent_oauth, RegentOAuth.Repo),
        :pool,
        Ecto.Adapters.SQL.Sandbox
      )
    )

    start_supervised!(RegentOAuth.Repo)
    oauth = Ecto.Adapters.SQL.Sandbox.start_owner!(RegentOAuth.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(oauth) end)

    test = self()

    # The hosted signer registers the identity and signs what it is asked to, as
    # the one hosted wallet.
    Req.Test.stub(RegentMCPAgents.HostedSigner, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      asked = Jason.decode!(body)
      send(test, {:signer, get_req_header(conn, "authorization"), body, asked})

      case asked do
        %{"operation" => "register"} ->
          Req.Test.json(conn, %{"address" => @wallet})

        %{"operation" => "sign", "request" => r} ->
          Req.Test.json(conn, Map.put(r, "headers", @signed))
      end
    end)

    :ok
  end

  defp put_env(app, key, value) do
    keep_env(app, key)
    Application.put_env(app, key, value)
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

  # A person with a verified account on this site, as their sign-in leaves it.
  defp sign_in!(subject) do
    wallet = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
    Accounts.register_verified!(subject, wallet, [wallet], actor: %SystemActor{})
  end

  defp subject! do
    subject = "did:privy:connector-#{System.unique_integer([:positive])}"
    sign_in!(subject)
    subject
  end

  defp account(subject), do: Accounts.get_by_privy_did!(subject, actor: %SystemActor{})

  # An app connected by `subject`, as consent leaves it: its client id and the
  # plain access and refresh tokens it holds.
  defp connect!(subject, scope \\ "regent.identity.manage") do
    register =
      conn(:post, "/oauth/register", %{
        "client_name" => "Claude",
        "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"]
      })
      |> put_req_header("accept", "application/json")
      |> endpoint()

    assert register.status == 201, register.resp_body
    client = Boruta.ClientsAdapter.get_client(json(register)["client_id"])

    {:ok, token} =
      RegentOAuth.AccessTokens.create(
        %{client: client, sub: subject, scope: scope},
        refresh_token: true
      )

    %{client_id: client.id, access: token.value, refresh: token.refresh_token}
  end

  defp refresh(client_id, refresh_token) do
    conn =
      conn(:post, "/oauth/token", %{
        "grant_type" => "refresh_token",
        "client_id" => client_id,
        "refresh_token" => refresh_token,
        "resource" => RegentOAuth.resource()
      })
      |> put_req_header("accept", "application/json")
      |> endpoint()

    {conn.status, json(conn)}
  end

  # AshAi takes a tool's arguments as its action's input. A call as tools/list
  # lists the tool: one with no inputs is sent empty arguments; one with inputs
  # takes them under `input`.
  defp tool(token, name),
    do: json(post_mcp(rpc("tools/call", %{"name" => name, "arguments" => %{}}), token))["result"]

  defp tool(token, name, input) do
    call = rpc("tools/call", %{"name" => name, "arguments" => %{"input" => input}})
    json(post_mcp(call, token))["result"]
  end

  defp counts(token), do: tool(token, "autolaunch_auction_counts")

  defp counts_call,
    do: rpc("tools/call", %{"name" => "autolaunch_auction_counts", "arguments" => %{}})

  defp post_mcp(body, token) do
    conn =
      conn(:post, "/mcp", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    endpoint(conn)
  end

  defp endpoint(conn), do: conn |> Map.put(:remote_ip, Process.get(:from)) |> @endpoint.call([])

  defp rpc(method, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

  # An agent's signed request, verified by the stubbed SIWA service.
  defp signed(method, path, body \\ nil) do
    conn = conn(method, path, body)
    conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn

    conn
    |> put_req_header("x-siwa-signature", "fixture-proof")
    |> endpoint()
  end

  defp pair_request(code, harness),
    do:
      signed(
        :post,
        "/api/agents/v1/pair",
        Jason.encode!(%{code: code, name: "Fixture", harness: harness})
      )

  defp pair_args(code), do: %{"code" => code, "name" => "Claude", "harness" => "claude"}

  defp person(subject), do: %RegentAgents.Person{privy_user_id: subject}

  defp code!(subject), do: RegentAgents.issue_pairing_code!(actor: person(subject)).code

  defp agents(subject), do: RegentAgents.list_my_agents!(actor: person(subject))

  defp signer_asks do
    receive do
      {:signer, auth, raw, asked} -> [{auth, raw, asked} | signer_asks()]
    after
      0 -> []
    end
  end

  defp tool_names(token) do
    json(post_mcp(rpc("tools/list"), token))["result"]["tools"]
    |> Enum.map(& &1["name"])
  end

  defp down_asks do
    receive do
      :signer_down -> 1 + down_asks()
    after
      0 -> 0
    end
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
end
