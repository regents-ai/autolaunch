defmodule AutolaunchWeb.AgentContractTest do
  @moduledoc """
  The served API contract (`contracts/api-contract.openapiv3.yaml`, copied to
  `cli/docs` for the regents command line) says what the agent routes answer.
  Each case drives a route through the site's real plugs, with the sign-in
  service stubbed, and checks the contract documents the status it answered and
  the code or status it named.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias RegentAgents.Person

  @moduletag :capture_log
  @contract "../../../contracts/api-contract.openapiv3.yaml"
            |> Path.expand(__DIR__)
            |> YamlElixir.read_from_file!()

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

    :ok
  end

  defp agent do
    <<a, b, c>> = :crypto.strong_rand_bytes(3)
    wallet = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
    %{build_conn() | remote_ip: {10, a, b, c}} |> put_req_header("x-agent-wallet-address", wallet)
  end

  defp pair(conn, code, harness \\ "codex", name \\ "Agent") do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/api/agents/v1/pair",
      Jason.encode!(%{"code" => code, "name" => name, "harness" => harness})
    )
  end

  defp code_for(privy_user_id) do
    {:ok, issued} = RegentAgents.issue_pairing_code(actor: %Person{privy_user_id: privy_user_id})
    issued.code
  end

  # The schema the contract documents for `path` and `method` answering `status`.
  defp documented(path, method, status) do
    response = get_in(@contract, ["paths", path, method, "responses", Integer.to_string(status)])
    assert response, "#{method} #{path} answered #{status}, which the contract does not document"
    resolve(get_in(response, ["content", "application/json", "schema"]))
  end

  defp resolve(%{"$ref" => "#/components/schemas/" <> name}),
    do: resolve(get_in(@contract, ["components", "schemas", name]))

  defp resolve(schema), do: schema

  defp assert_refusal(conn, path, method) do
    code = json_response(conn, conn.status)["error"]["code"]
    schema = documented(path, method, conn.status)
    assert code in get_in(schema, ["properties", "error", "properties", "code", "enum"])
  end

  test "AGENT_ROUTES_ANSWER_AS_THE_CONTRACT_SAYS: whoami, check-in and pairing answer only what the contract documents" do
    conn = agent() |> get("/api/agents/v1/whoami")
    assert %{"status" => "not_paired"} = json_response(conn, 200)["data"]
    whoami = documented("/api/agents/v1/whoami", "get", 200)
    status = resolve(whoami["properties"]["data"])["properties"]["status"]
    assert "not_paired" in status["enum"]

    assert_refusal(agent() |> get("/api/agents/v1/me"), "/api/agents/v1/me", "get")

    person = "did:privy:contract-#{System.unique_integer([:positive])}"
    code = code_for(person)
    assert agent() |> pair(code) |> json_response(201)

    assert_refusal(agent() |> pair(code), "/api/agents/v1/pair", "post")
    assert_refusal(agent() |> pair(code_for(person), "chatgpt"), "/api/agents/v1/pair", "post")

    assert_refusal(
      agent() |> pair(code_for(person), "codex", "line\nbreak"),
      "/api/agents/v1/pair",
      "post"
    )

    for _ <- 2..100, do: assert(agent() |> pair(code_for(person)) |> json_response(201))
    assert_refusal(agent() |> pair(code_for(person)), "/api/agents/v1/pair", "post")
  end
end
