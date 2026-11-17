defmodule AutolaunchWeb.AgentCheckInTest do
  @moduledoc """
  An agent's status and check-in on Autolaunch, through the shared agent requests
  this site mounts (`RegentAgents.HTTP`) and its own agent routes
  (`AutolaunchWeb.Plugs.AgentAccess`), with the sign-in service stubbed. An agent
  paired by a signed-in person is told it is paired; one whose pairing names no
  Regent account is told it is not paired; and a person's account that could not
  be read just now is 503 `account_unavailable`.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.DatabaseFaults

  alias Autolaunch.TestSupport
  alias RegentAgents.Person

  @moduletag :capture_log
  @wallet "0x2222222222222222222222222222222222222222"

  # The sign-in service verifies each signed request as this agent's key.
  defp siwa_verifies do
    Req.Test.stub(RegentAgents.Broker, &Req.Test.json(&1, verified(@wallet)))
  end

  # The sign-in service's answer for a request it verified as `wallet`'s.
  defp verified(wallet) do
    %{
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
    }
  end

  @siwa [
    secret: "agent-check-in-test-only",
    audience: "autolaunch",
    wallet_audiences: ["autolaunch"],
    authorities: ["www.example.com"]
  ]

  # The sign-in service checks what this site sent it as it does on
  # siwa.regents.sh (`Siwa.RequestAuth`), and answers a refusal as it does.
  defp siwa_checks_signatures do
    Req.Test.stub(RegentAgents.Broker, fn broker ->
      {:ok, body, broker} = Plug.Conn.read_body(broker)
      sent = Jason.decode!(body)
      opts = Keyword.put(@siwa, :replay_store, fn _key, _expires -> :ok end)

      case Siwa.RequestAuth.verify_authenticated_request(sent, opts) do
        {:ok, _verified} ->
          Req.Test.json(broker, verified(sent["headers"]["x-agent-wallet-address"]))

        {:error, reason} ->
          {status, code, message} = Siwa.Contract.refusal(reason)
          error = %{"code" => code, "message" => message, "hint" => "Sign the request again."}
          broker |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => error})
      end
    end)
  end

  # An agent's own key, and the receipt the sign-in service gave it.
  defp signing_agent do
    {:ok, signer} = Siwa.LocalSigner.new()

    {:ok, receipt} =
      Siwa.Receipt.create(
        %{
          "typ" => "siwa_wallet_receipt",
          "verified" => "wallet_signature",
          "jti" => "check-in-#{System.unique_integer([:positive])}",
          "sub" => signer.address,
          "aud" => "autolaunch",
          "chain_id" => 8453,
          "nonce" => "check-in",
          "key_id" => signer.address
        },
        @siwa
      )

    %{signer: signer, receipt: receipt.token}
  end

  # The agent's signed headers for `method path` with `body`, nil for none.
  defp sign(agent, method, path, body) do
    request = %{
      method: method,
      path: path,
      authority: "www.example.com",
      body: body,
      headers: %{}
    }

    {:ok, signed} =
      Siwa.RequestAuth.sign_authenticated_request(request, agent.receipt, agent.signer, @siwa)

    signed.headers
  end

  # The library signs an empty body as none; an agent's own signer may instead
  # sign the empty body's digest, as a request sent with `--body ''` does.
  defp sign_empty_digest(agent, method, path) do
    headers =
      agent
      |> sign(method, path, "{}")
      |> Map.put("content-digest", Siwa.RequestAuth.content_digest_for_body(""))

    {:ok, message} =
      Siwa.RequestAuth.signing_message(%{
        method: method,
        path: path,
        authority: "www.example.com",
        headers: headers
      })

    {:ok, "0x" <> signature} = Siwa.LocalSigner.sign_message(agent.signer, message)
    signature = signature |> Base.decode16!(case: :mixed) |> Base.encode64()
    Map.put(headers, "x-siwa-signature", "sig1=:#{signature}:")
  end

  defp with_headers(headers),
    do:
      Enum.reduce(headers, build_conn(), fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)

  # Each request stands for one the agent signed; the stub above verifies it.
  defp post_json(conn, path, body),
    do: conn |> put_req_header("content-type", "application/json") |> post(path, body)

  test "AGENT_CHECK_IN_NAMES_THE_SHARED_ACCOUNT: a paired agent is told it is paired and checks in",
       %{conn: conn} do
    siwa_verifies()
    account = TestSupport.register_creator!()

    assert %{"data" => %{"status" => "not_paired", "next_step" => next_step}} =
             conn |> get("/api/agents/v1/whoami") |> json_response(200)

    assert next_step =~ "Pair New Agent"

    {:ok, code} =
      RegentAgents.issue_pairing_code(actor: %Person{privy_user_id: account.privy_user_id})

    body = Jason.encode!(%{"code" => code.code, "name" => "Sol", "harness" => "codex"})

    assert %{"data" => %{"name" => "Sol", "wallet" => @wallet}} =
             conn |> post_json("/api/agents/v1/pair", body) |> json_response(201)

    assert %{"data" => %{"status" => "paired", "next_step" => nil, "allowed" => allowed}} =
             conn |> get("/api/agents/v1/whoami") |> json_response(200)

    assert allowed == Application.fetch_env!(:regent_agents, :allowed)["paired"]

    assert %{"data" => %{"wallet" => @wallet, "account" => checked_in_account}} =
             conn |> get("/api/agents/v1/me") |> json_response(200)

    assert checked_in_account["wallet_address"] == account.wallet_address
  end

  # Pairs this agent's key with `privy_user_id`, whether or not that person has
  # an account.
  defp pair!(conn, privy_user_id) do
    {:ok, code} = RegentAgents.issue_pairing_code(actor: %Person{privy_user_id: privy_user_id})
    body = Jason.encode!(%{"code" => code.code, "name" => "Sol", "harness" => "codex"})
    conn |> post_json("/api/agents/v1/pair", body) |> json_response(201)
  end

  test "AGENT_PAIRING_WITHOUT_ACCOUNT_IS_NOT_PAIRED: a pairing that names no Regent account is agent_not_paired",
       %{conn: conn} do
    siwa_verifies()
    pair!(conn, "did:privy:no-account-#{System.unique_integer([:positive])}")

    for path <- ["/api/agents/v1/me", "/api/agents/v1/whoami"] do
      {403, _headers, body} = assert_error_sent(403, fn -> get(conn, path) end)
      assert %{"error" => %{"code" => "agent_not_paired", "hint" => hint}} = Jason.decode!(body)
      assert hint =~ "Pair New Agent", path
    end

    for path <- ["/api/agent/v1/positions", "/api/v1/account/points"] do
      assert %{"error" => %{"code" => "agent_not_paired", "hint" => hint}} =
               conn |> get(path) |> json_response(403)

      assert hint =~ "Pair New Agent", path
    end
  end

  test "AGENT_PERSON_UNREAD_IS_503: a person's account that can't be read is account_unavailable",
       %{conn: conn} do
    siwa_verifies()
    account = TestSupport.register_creator!()
    pair!(conn, account.privy_user_id)
    lose_reads_of("account_ens_identities")

    for path <- ["/api/agents/v1/me", "/api/agents/v1/whoami"] do
      {503, _headers, body} = assert_error_sent(503, fn -> get(conn, path) end)
      assert %{"error" => %{"code" => "account_unavailable"}} = Jason.decode!(body), path
    end

    assert %{"error" => %{"code" => "account_unavailable"}} =
             conn |> get("/api/agent/v1/positions") |> json_response(503)
  end

  # An agent with its own key, paired by a signed request with a person who has
  # an account; the sign-in service checks every signature it is sent.
  defp paired_signing_agent! do
    siwa_checks_signatures()
    agent = signing_agent()
    account = TestSupport.register_creator!()

    {:ok, code} =
      RegentAgents.issue_pairing_code(actor: %Person{privy_user_id: account.privy_user_id})

    body = Jason.encode!(%{"code" => code.code, "name" => "Sol", "harness" => "codex"})

    assert %{"data" => %{"name" => "Sol"}} =
             agent
             |> sign("POST", "/api/agents/v1/pair", body)
             |> with_headers()
             |> post_json("/api/agents/v1/pair", body)
             |> json_response(201)

    agent
  end

  # A draft save sends `body` as JSON under `headers`, whatever they signed.
  @draft "/api/agent/v1/drafts/revstake"
  defp save_draft(headers, body),
    do:
      headers
      |> with_headers()
      |> put_req_header("content-type", "application/json")
      |> patch(@draft, body)

  defp read_draft(agent),
    do: agent |> sign("GET", @draft, nil) |> with_headers() |> get(@draft) |> json_response(200)

  test "SIGNED_EMPTY_BODY_IS_NO_BODY: a signed GET with the empty body's digest or none answers alike; a digest for a body that never arrives is refused" do
    agent = paired_signing_agent!()

    for path <- ["/api/agents/v1/whoami", @draft] do
      no_digest = agent |> sign("GET", path, nil) |> with_headers() |> get(path)
      empty_digest = agent |> sign_empty_digest("GET", path) |> with_headers() |> get(path)
      assert json_response(no_digest, 200) == json_response(empty_digest, 200), path

      missing_body = agent |> sign("GET", path, ~s({"name":"Sol"})) |> with_headers() |> get(path)

      assert %{"error" => %{"code" => "http_body_binding_invalid"}} =
               json_response(missing_body, 401),
             path
    end
  end

  describe "a signed draft save, with writes open" do
    # Read-only mode refuses a save before its signature is checked.
    setup do
      previous = Application.get_env(:autolaunch, :prelaunch_read_only)
      Application.put_env(:autolaunch, :prelaunch_read_only, false)
      on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)
    end

    test "SIGNED_EMPTY_SAVE_IS_NO_BODY: a zero-byte JSON save answers alike with the empty body's digest or none" do
      agent = paired_signing_agent!()

      no_digest = agent |> sign("PATCH", @draft, nil) |> save_draft("")
      empty_digest = agent |> sign_empty_digest("PATCH", @draft) |> save_draft("")

      # The route's own answer for a save with nothing in it, never a sign-in refusal.
      assert %{"error" => %{"code" => "invalid_draft"}} = json_response(no_digest, 422)
      assert json_response(no_digest, 422) == json_response(empty_digest, 422)
    end

    test "SIGNED_BODY_NEEDS_ITS_DIGEST: a save whose body its signature does not name is refused" do
      agent = paired_signing_agent!()
      body = ~s({"name":"Sol"})

      unsigned_body = agent |> sign("PATCH", @draft, nil) |> save_draft(body)

      # A body makes its content-digest a header every signature must carry.
      assert %{"error" => %{"code" => "http_headers_missing"}} =
               json_response(unsigned_body, 401)

      assert %{"data" => nil} = read_draft(agent)

      # The same bytes under a signature that names them are saved.
      assert %{"data" => %{"name" => "Sol"}} =
               agent |> sign("PATCH", @draft, body) |> save_draft(body) |> json_response(200)
    end

    test "SIGNED_EMPTY_DIGEST_HAS_NO_BYTES: a save signed with the empty body's digest that carries bytes is refused" do
      agent = paired_signing_agent!()

      smuggled = agent |> sign_empty_digest("PATCH", @draft) |> save_draft(~s({"name":"Sol"}))

      assert %{"error" => %{"code" => "http_body_binding_invalid"}} =
               json_response(smuggled, 401)

      assert %{"data" => nil} = read_draft(agent)
    end
  end

  test "AGENT_SIWA_DOWN_IS_503: while the sign-in service can't be reached a paired call says so",
       %{conn: conn} do
    siwa_verifies()
    account = TestSupport.register_creator!()
    pair!(conn, account.privy_user_id)
    Req.Test.stub(RegentAgents.Broker, &Req.Test.transport_error(&1, :econnrefused))

    for path <- ["/api/agents/v1/whoami", "/api/agent/v1/positions"] do
      assert %{"error" => %{"code" => "siwa_request_failed"}} =
               conn |> get(path) |> json_response(503),
             path
    end
  end

  test "AGENT_PERSON_READ_FAILED_IS_500: a person's account read that fails for another reason is a real error",
       %{conn: conn} do
    siwa_verifies()
    account = TestSupport.register_creator!()
    pair!(conn, account.privy_user_id)
    # Renamed for this case's sandboxed transaction only: 42P01, not a lost connection.
    Autolaunch.Repo.query!(
      "ALTER TABLE autolaunch_app.account_ens_identities RENAME TO account_ens_identities_unread"
    )

    for path <- ["/api/agents/v1/me", "/api/agents/v1/whoami", "/api/agent/v1/positions"] do
      {500, _headers, _body} = assert_error_sent(500, fn -> get(conn, path) end)
    end
  end
end
