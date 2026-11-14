defmodule AutolaunchWeb.NearFundingRoutesTest do
  @moduledoc """
  The NEAR funding routes for a signed, paired agent against the 1Click
  service's recorded answers (`Autolaunch.TestNearIntents`): the USDC goes to
  the person's own wallet whatever the body says, a funding is read only for
  its own person and with its status read now, and every answer and refusal is
  one the API contract documents.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.{TestNearIntents, TestSupport}
  alias RegentAgents.Person

  @moduletag :capture_log
  @contract "../../../contracts/api-contract.openapiv3.yaml"
            |> Path.expand(__DIR__)
            |> YamlElixir.read_from_file!()

  setup do
    start_supervised!(
      {Oban,
       AshOban.config(
         Application.fetch_env!(:autolaunch, :ash_domains),
         Application.fetch_env!(:autolaunch, Oban)
       )}
    )

    TestNearIntents.install()

    # Past the prelaunch gate, which refuses agent writes until the site opens.
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)

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

    %{auction: TestSupport.project_auction(state: :active)}
  end

  defp address, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

  # A paired agent acting for a new account whose one wallet is returned.
  defp paired_agent do
    privy = "did:privy:near-#{:erlang.unique_integer([:positive])}"
    wallet = address()

    Autolaunch.Accounts.register_verified!(privy, wallet, [wallet],
      actor: %Autolaunch.Actors.System{}
    )

    {:ok, issued} = RegentAgents.issue_pairing_code(actor: %Person{privy_user_id: privy})
    agent = address()
    signed = fn -> build_conn() |> put_req_header("x-agent-wallet-address", agent) end

    assert signed.()
           |> send_json("POST", "/api/agents/v1/pair", %{
             "code" => issued.code,
             "name" => "Agent",
             "harness" => "codex"
           })
           |> json_response(201)

    {wallet, signed}
  end

  defp send_json(conn, method, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> dispatch(@endpoint, method, path, Jason.encode!(body))
  end

  # The answer's body, once the contract is seen to document its status for
  # this route (and, for a refusal it gives a schema, its code).
  defp documented(conn, path, method) do
    response =
      get_in(@contract, ["paths", path, method, "responses", Integer.to_string(conn.status)])

    assert response,
           "#{method} #{path} answered #{conn.status}, which the contract does not document"

    body = Jason.decode!(conn.resp_body)

    with %{"error" => %{"code" => code}} <- body,
         %{"$ref" => "#/components/schemas/" <> name} <-
           get_in(response, ["content", "application/json", "schema"]) do
      codes = get_in(@contract, ["components", "schemas", name, "properties", "error"])
      assert code in codes["properties"]["code"]["enum"]
    end

    body
  end

  @quote "/api/agent/v1/auctions/{id}/near-funding/quote"
  @start "/api/agent/v1/auctions/{id}/near-funding"
  @show "/api/agent/v1/near-fundings/{id}"

  test "an agent prices, starts and reads a funding for its person's own wallet", %{
    auction: auction
  } do
    {wallet, signed} = paired_agent()

    body =
      signed.()
      |> send_json("POST", "/api/agent/v1/auctions/#{auction.id}/near-funding/quote", %{
        "usdc_amount" => 5_000_000
      })
      |> documented(@quote, "post")

    assert body["data"] == %{
             "usdc_amount" => 5_000_000,
             "near_amount" => "1.652",
             "near_amount_raw" => "1651313840569386417635746",
             "time_estimate_s" => 24,
             "recipient" => wallet
           }

    # A recipient named in the body is not a field the route reads.
    conn =
      send_json(signed.(), "POST", "/api/agent/v1/auctions/#{auction.id}/near-funding", %{
        "usdc_amount" => 5_000_000,
        "refund_to" => "person.near",
        "recipient" => address()
      })

    assert conn.status == 201
    %{"data" => funding} = documented(conn, @start, "post")

    assert %{
             "recipient" => ^wallet,
             "refund_to" => "person.near",
             "state" => "pending_deposit",
             "near_amount" => "1.652"
           } = funding

    assert funding["deposit_address"] == TestNearIntents.deposit_address()

    TestNearIntents.put(%{
      status: %{state: :processing, origin_tx: "near-tx", destination_tx: nil}
    })

    read =
      signed.()
      |> get("/api/agent/v1/near-fundings/#{funding["id"]}")
      |> documented(@show, "get")

    assert %{"state" => "processing", "origin_tx" => "near-tx"} = read["data"]
  end

  test "refusals name their reason, and another person's funding is not found", %{
    auction: auction
  } do
    {_wallet, signed} = paired_agent()
    start = "/api/agent/v1/auctions/#{auction.id}/near-funding"

    refusals = [
      {"POST", "/api/agent/v1/auctions/#{Ash.UUID.generate()}/near-funding/quote", @quote,
       %{"usdc_amount" => 1}, 404, "unknown_auction"},
      {"POST", "/api/agent/v1/auctions/#{auction.id}/near-funding/quote", @quote,
       %{"usdc_amount" => 0}, 422, "invalid_amount"},
      {"POST", start, @start, %{"usdc_amount" => 1.5, "refund_to" => "person.near"}, 422,
       "invalid_amount"},
      {"POST", start, @start, %{"usdc_amount" => 1, "refund_to" => "0xNotNear"}, 422,
       "invalid_refund_account"}
    ]

    for {method, path, documented_path, body, status, code} <- refusals do
      conn = send_json(signed.(), method, path, body)
      assert conn.status == status, "#{path} #{inspect(body)} answered #{conn.status}"
      assert documented(conn, documented_path, "post")["error"]["code"] == code
    end

    %{"data" => %{"id" => id}} =
      signed.()
      |> send_json("POST", start, %{"usdc_amount" => 1, "refund_to" => "person.near"})
      |> json_response(201)

    {_other_wallet, stranger} = paired_agent()

    for path <- ["/api/agent/v1/near-fundings/#{id}", "/api/agent/v1/near-fundings/not-an-id"] do
      conn = get(stranger.(), path)
      assert conn.status == 404
      assert documented(conn, @show, "get")["error"]["code"] == "not_found"
    end

    TestNearIntents.put(%{unavailable: true})
    conn = get(signed.(), "/api/agent/v1/near-fundings/#{id}")
    assert conn.status == 503
    assert documented(conn, @show, "get")["error"]["code"] == "near_unavailable"

    assert build_conn() |> get("/api/agent/v1/near-fundings/#{id}") |> json_response(401)
  end
end
