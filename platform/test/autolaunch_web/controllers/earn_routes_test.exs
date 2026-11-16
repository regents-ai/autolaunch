defmodule AutolaunchWeb.EarnRoutesTest do
  @moduledoc """
  Earn's HTTP routes against the chain double: the products answer anyone
  with every documented field and the block they were read at; a signed,
  paired agent previews and prepares steps only for a wallet of the account it
  acts for, and gets its steps only once the site is open; the signed-in
  person reads only their own wallet.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.{BaseRpcStub, EarnChain, TestSupport}
  alias RegentAgents.Person
  alias RegentChain.{BuilderCode, Call}

  @moduletag :capture_log
  @schemas "../../../contracts/earn.openapiv3.yaml"
           |> Path.expand(__DIR__)
           |> YamlElixir.read_from_file!()
           |> get_in(["components", "schemas"])
  @unit EarnChain.unit()

  setup do
    EarnChain.install()
  end

  # Past the prelaunch gate, which refuses wallet steps until the site opens.
  defp open_site do
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
  end

  defp send_json(conn, method, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> dispatch(@endpoint, method, path, Jason.encode!(body))
  end

  defp address, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

  # A new agent's requests, each verified as signed with its own key.
  defp signed_agent do
    agent = address()

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

    fn -> build_conn() |> put_req_header("x-agent-wallet-address", agent) end
  end

  # A paired agent acting for a new account whose one wallet is returned.
  defp paired_agent do
    privy = "did:privy:earn-#{System.unique_integer([:positive])}"
    wallet = address()

    Autolaunch.Accounts.register_verified!(privy, wallet, [wallet],
      actor: %Autolaunch.Actors.System{}
    )

    {:ok, issued} = RegentAgents.issue_pairing_code(actor: %Person{privy_user_id: privy})
    signed = signed_agent()

    assert signed.()
           |> send_json("POST", "/api/agents/v1/pair", %{
             "code" => issued.code,
             "name" => "Agent",
             "harness" => "codex"
           })
           |> json_response(201)

    {wallet, signed}
  end

  defp code(body), do: body["error"]["code"]

  # The field names the contract documents for `schema`, through its `allOf` parts.
  defp documented(%{"allOf" => parts}), do: parts |> Enum.flat_map(&documented/1) |> Enum.sort()
  defp documented(%{"$ref" => "#/components/schemas/" <> name}), do: documented(@schemas[name])
  defp documented(%{"properties" => properties}), do: properties |> Map.keys() |> Enum.sort()
  defp documented(name) when is_binary(name), do: documented(@schemas[name])

  test "the products answer anyone with every documented field, read at the latest block", %{
    conn: conn
  } do
    EarnChain.put(%{cap: 500_000_000, accrued: 7 * @unit})
    answer = conn |> get("/api/v1/earn/products") |> json_response(200)

    assert [product] = answer["data"]["products"]
    assert Enum.sort(Map.keys(product)) == documented("EarnProduct")
    assert Enum.sort(Map.keys(product["block"])) == documented("EarnBlock")

    assert %{
             "id" => "aave-usdc",
             "chain_id" => 8453,
             "market" => "Aave V3 on Base",
             "pool" => "0xa238dd80c259a72e81d7e4664a9801593f98d1c5",
             "asset_address" => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
             "market_token" => "0x4e65fe4dba92790696d040ac24aa414708f5c0ab",
             "decimals" => 6,
             "status" => "open",
             "rate_now" => %{"yearly_percent" => "4.68"},
             "supplied" => 300_000_000_000_000,
             "available" => 50_000_000_000_000,
             "supply_cap" => 500_000_000,
             # 500M cap less 300M supplied and 7 owed to the treasury.
             "capacity" => 199_999_993_000_000
           } = product

    assert product["block"]["number"] == 0x20 and product["block"]["timestamp"] == EarnChain.now()
    assert product["risks"] != []

    assert conn |> get("/api/v1/earn/products?product=aave-usdc") |> json_response(422) |> code() ==
             "invalid_request"

    EarnChain.put(%{unreadable: true})

    assert build_conn() |> get("/api/v1/earn/products") |> json_response(503) |> code() ==
             "chain_unavailable"
  end

  test "a node that answers for another network or with what isn't a block, or no deployment to read Earn on, is refused with its own code" do
    healthy = %{chain_id: "0x2105", blocks: BaseRpcStub.state().blocks}

    for {answer, code} <- [
          {%{chain_id: "0x1"}, "wrong_chain"},
          {%{chain_id: "not a number"}, "invalid_chain_response"},
          {%{blocks: %{"latest" => %{"number" => "0x20"}}}, "invalid_block_header"}
        ] do
      BaseRpcStub.put(answer)
      refused = build_conn() |> get("/api/v1/earn/products") |> json_response(503)
      assert code(refused) == code, inspect(answer)
      BaseRpcStub.put(healthy)
    end

    run_id = Application.fetch_env!(:autolaunch, :autolaunch_base_deployment_id)
    on_exit(fn -> Application.put_env(:autolaunch, :autolaunch_base_deployment_id, run_id) end)
    Application.delete_env(:autolaunch, :autolaunch_base_deployment_id)

    refused = build_conn() |> get("/api/v1/earn/products") |> json_response(503)
    assert code(refused) == "earn_unavailable"
  end

  test "a paired agent previews before the site opens, and gets its steps only once it has" do
    {wallet, signed} = paired_agent()
    request = %{"product" => "aave-usdc", "kind" => "deposit", "amount" => 250 * @unit}

    quote =
      signed.() |> send_json("POST", "/api/agent/v1/earn/quote", request) |> json_response(200)

    assert Enum.sort(Map.keys(quote["data"])) == documented("EarnQuote")

    assert %{
             "signer" => ^wallet,
             "amount" => 250_000_000,
             "everything" => false,
             "approved" => false,
             "blocked" => nil,
             "market" => %{"status" => "open", "capacity" => nil},
             "wallet" => %{"usdc" => 1_000_000_000, "position" => "none"}
           } = quote["data"]

    refused =
      signed.() |> send_json("POST", "/api/agent/v1/earn/steps", request) |> json_response(503)

    assert code(refused) == "prelaunch_read_only"

    open_site()

    prepared =
      signed.() |> send_json("POST", "/api/agent/v1/earn/steps", request) |> json_response(200)

    assert Enum.sort(Map.keys(prepared["data"])) ==
             documented(@schemas["EarnStepsEnvelope"]["properties"]["data"])

    assert [approval, supply] = prepared["data"]["steps"]
    assert approval["step"] == "usdc_approval" and supply["step"] == "supply"

    assert supply["data"] ==
             BuilderCode.append(
               Call.encode("supply(address,uint256,address,uint16)", [
                 EarnChain.usdc(),
                 250 * @unit,
                 wallet,
                 0
               ])
             )

    assert prepared["data"]["chain"]["chain_id"] == 8453
  end

  test "a paired agent's steps are for its person's own wallets, with blocked reasons and refusals in its words" do
    open_site()
    {wallet, signed} = paired_agent()

    steps = fn body -> signed.() |> send_json("POST", "/api/agent/v1/earn/steps", body) end
    withdraw = %{"product" => "aave-usdc", "kind" => "withdraw", "everything" => true}

    EarnChain.put(%{balance: 40 * @unit})
    everything = steps.(withdraw) |> json_response(200)
    assert %{"everything" => true, "amount" => 40_000_000, "blocked" => nil} = everything["data"]

    assert [%{"step" => "withdraw", "data" => data}] = everything["data"]["steps"]

    assert data ==
             BuilderCode.append(
               Call.encode("withdraw(address,uint256,address)", [
                 EarnChain.usdc(),
                 2 ** 256 - 1,
                 wallet
               ])
             )

    over =
      steps.(%{withdraw | "everything" => false} |> Map.put("amount", 41 * @unit))
      |> json_response(200)

    assert over["data"]["blocked"]["code"] == "over_balance"
    assert [%{"step" => "withdraw"}] = over["data"]["steps"]

    stranger = "0x" <> String.duplicate("ab", 20)

    assert steps.(Map.put(withdraw, "signer", stranger)) |> json_response(403) |> code() ==
             "wrong_signer"

    assert steps.(%{withdraw | "kind" => "borrow"}) |> json_response(422) |> code() ==
             "invalid_request"

    assert steps.(Map.put(withdraw, "extra", 1)) |> json_response(422) |> code() ==
             "invalid_request"

    assert steps.(Map.put(withdraw, "amount", "1")) |> json_response(422) |> code() ==
             "invalid_request"

    assert steps.(Map.delete(withdraw, "kind")) |> json_response(422) |> code() ==
             "invalid_request"

    assert steps.(%{"product" => "aave-usdc", "kind" => "deposit", "amount" => 0})
           |> json_response(422)
           |> code() == "invalid_request"

    assert steps.(%{"product" => "aave-usdc", "kind" => "deposit", "everything" => true})
           |> json_response(422)
           |> code() == "invalid_amount"

    assert steps.(%{"product" => "nope", "kind" => "deposit", "amount" => 1})
           |> json_response(404)
           |> code() == "unknown_product"

    positions = signed.() |> get("/api/agent/v1/earn/positions") |> json_response(200)

    assert %{
             "wallet" => ^wallet,
             "positions" => [%{"position" => "held", "balance" => 40_000_000} = held]
           } =
             positions["data"]

    assert held["product"]["id"] == "aave-usdc" and held["block"]["number"] == 0x20
  end

  test "an agent nobody paired gets no preview, steps or balances" do
    open_site()
    signed = signed_agent()
    request = %{"product" => "aave-usdc", "kind" => "deposit", "amount" => 1}

    for {method, path, body} <- [
          {"POST", "/api/agent/v1/earn/quote", request},
          {"POST", "/api/agent/v1/earn/steps", request},
          {"GET", "/api/agent/v1/earn/positions", nil}
        ] do
      refused = if body, do: send_json(signed.(), method, path, body), else: get(signed.(), path)
      assert refused |> json_response(403) |> code() == "agent_not_paired"
    end
  end

  test "the signed-in route needs a sign-in and reads only the signed-in wallet", %{conn: conn} do
    assert conn |> get("/api/v1/me/earn") |> json_response(401) |> code() ==
             "authentication_required"

    EarnChain.put(%{balance: 1})
    account = TestSupport.register_creator!()

    mine =
      init_test_session(build_conn(), %{human_account_id: account.id}) |> get("/api/v1/me/earn")

    wallet = String.downcase(account.wallet_address)

    assert %{"wallet" => ^wallet, "positions" => [%{"position" => "held", "balance" => 1}]} =
             json_response(mine, 200)["data"]
  end
end
