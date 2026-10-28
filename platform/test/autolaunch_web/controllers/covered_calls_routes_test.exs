defmodule AutolaunchWeb.CoveredCallsRoutesTest do
  @moduledoc """
  The covered-call HTTP routes against a stubbed Base chain: off, every route
  is an address with nothing at it; on, the public book and quote answer
  anyone, the signed-in person reads only their own wallet, and a paired
  agent's steps are built only for a wallet of the account it acts for.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.{BaseRpcStub, LabAbi, TestSupport}
  alias Autolaunch.CoveredCalls.Terms
  alias RegentAgents.Person

  @moduletag :capture_log
  @fixture Path.expand("../../fixtures/covered-calls-deployment.json", __DIR__)
  @contract "0xc0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0"
  @stock "0xb200000000000000000000d9192b6b456483c2e8"
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @seller "0x5e11e75e11e75e11e75e11e75e11e75e11e75e11"
  @now 1_793_000_000
  @token 100_000_000
  @routes [
    {:get, "/api/v1/covered-calls/AMZNc"},
    {:post, "/api/v1/covered-calls/AMZNc/quote"},
    {:get, "/api/v1/me/covered-calls/AMZNc"},
    {:get, "/api/agent/v1/covered-calls/AMZNc/positions"},
    {:post, "/api/agent/v1/covered-calls/AMZNc/steps"}
  ]

  defp switch(state) do
    previous =
      for key <- [:covered_calls, :autolaunch_base_covered_calls_deployment],
          do: {key, Application.get_env(:autolaunch, key)}

    on_exit(fn -> Enum.each(previous, &restore/1) end)

    Application.put_env(:autolaunch, :covered_calls, state)
    Application.put_env(:autolaunch, :autolaunch_base_covered_calls_deployment, @fixture)
  end

  defp restore({key, nil}), do: Application.delete_env(:autolaunch, key)
  defp restore({key, value}), do: Application.put_env(:autolaunch, key, value)

  # Past the prelaunch gate, which refuses wallet steps until the site opens.
  defp open_site do
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
  end

  defp expiry, do: hd(Terms.expiries(@now))

  # One open listing: ten tokens at a $250 strike and a $5 premium, two sold.
  defp listing,
    do: [word(@seller), expiry(), 0, 10 * @token, 2 * @token, 0, 250_000_000, 5_000_000, 0, 0]

  defp chain(funds \\ %{}) do
    funds = Map.merge(%{balance: 0, allowance: 0, held: 0, claimable: 0}, funds)

    answers = %{
      LabAbi.selector("listingCount()") => [1],
      LabAbi.selector("listings(uint256)") => listing(),
      LabAbi.selector("multiplier()") => [10 ** 18],
      LabAbi.selector("effectiveAt()") => [0],
      LabAbi.selector("unit()") => [@token],
      LabAbi.selector("usdc()") => [word(@usdc)],
      LabAbi.selector("latestRoundData()") => [7, 230 * 10 ** 8, @now - 600, @now - 600, 7],
      LabAbi.selector("held(uint256,address)") => [funds.held],
      LabAbi.selector("claimable(uint256,address)") => [funds.claimable],
      LabAbi.selector("balanceOf(address)") => [funds.balance],
      LabAbi.selector("allowance(address,address)") => [funds.allowance]
    }

    BaseRpcStub.install(:autolaunch_lab_http_client, fn data, _state ->
      "0x" <>
        Enum.map_join(Map.fetch!(answers, String.slice(data, 0, 10)), &BaseRpcStub.hex_word/1)
    end)

    BaseRpcStub.put(%{
      blocks: %{
        "latest" => %{
          "number" => "0x40",
          "hash" => BaseRpcStub.safe_hash(),
          "timestamp" => BaseRpcStub.uint(@now)
        }
      }
    })
  end

  defp word("0x" <> hex), do: String.to_integer(hex, 16)

  defp send_json(conn, method, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> dispatch(@endpoint, method, path, Jason.encode!(body))
  end

  # A paired agent acting for a new account whose one wallet is returned.
  defp paired_agent do
    privy = "did:privy:covered-#{System.unique_integer([:positive])}"
    wallet = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

    Autolaunch.Accounts.register_verified!(privy, wallet, [wallet],
      actor: %Autolaunch.Actors.System{}
    )

    {:ok, issued} = RegentAgents.issue_pairing_code(actor: %Person{privy_user_id: privy})
    agent = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

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

  test "COVERED_CALLS_OFF_IS_NOT_FOUND: every covered-call route answers as an unknown address while covered calls are off",
       %{conn: conn} do
    switch(:off)
    open_site()
    unknown = conn |> get("/api/v1/nothing-here") |> json_response(404)

    for {method, path} <- @routes,
        do: assert(build_conn() |> send_json(method, path, %{}) |> json_response(404) == unknown)
  end

  test "COVERED_CALLS_ADVERTISED_ONLY_WHEN_ON: tools, routes, guides and the tools handed to the page follow the switch" do
    tools =
      ~w(autolaunch_covered_call_listings autolaunch_covered_call_quote autolaunch_my_covered_calls autolaunch_covered_call_prepare)

    open_site()

    for {state, offered?} <- [off: false, on: true] do
      switch(state)
      capabilities = build_conn() |> get("/capabilities") |> json_response(200)
      names = Enum.map(capabilities["tools"], & &1["name"])

      [prepare] = Enum.filter(capabilities["tools"], &(&1["name"] == "prepare_agent_request"))
      operations = prepare["input_schema"]["properties"]["operation"]["enum"]
      paths = build_conn() |> get("/openapi.json") |> json_response(200) |> Map.fetch!("paths")
      guide = build_conn() |> get("/llms-full.txt") |> response(200)
      home = build_conn() |> get("/") |> html_response(200)

      assert Enum.all?(tools, &(&1 in names)) == offered?
      assert Enum.any?(tools, &(&1 in names)) == offered?
      assert "autolaunch_covered_call_prepare" in operations == offered?
      assert Map.has_key?(paths, "/api/v1/covered-calls/{symbol}") == offered?
      assert guide =~ "autolaunch_covered_call_prepare" == offered?
      assert home =~ ~s(id="agent-feature-tools") == offered?
      assert home =~ "#{length(capabilities["tools"])} Agent Tools"
    end
  end

  test "the public book shows each listing's stage and what is left, and the quote suggests a premium",
       %{conn: conn} do
    switch(:on)
    chain()

    book = conn |> get("/api/v1/covered-calls/AMZNc") |> json_response(200)

    assert get_resp_header(
             conn |> get("/api/v1/covered-calls/AMZNc"),
             "access-control-allow-origin"
           ) == ["*"]

    assert %{"symbol" => "AMZNc", "contract" => @contract, "unit" => @token, "now" => @now} =
             book["data"]

    assert [listing] = book["data"]["listings"]
    assert listing["stage"] == "open"
    assert listing["available"] == 8 * @token
    assert listing["seller"] == @seller

    quote =
      conn
      |> send_json("POST", "/api/v1/covered-calls/AMZNc/quote", %{
        "strike_per_token" => 250_000_000,
        "expiry" => expiry()
      })
      |> json_response(200)

    assert %{"spot_per_token" => 230_000_000, "suggested_premium_per_token" => premium} =
             quote["data"]

    assert premium > 0 and premium < 20_000_000
  end

  test "the public routes refuse an unknown market, an expiry that is not a Friday close and unknown fields",
       %{conn: conn} do
    switch(:on)
    chain()

    assert conn |> get("/api/v1/covered-calls/NOPEc") |> json_response(404) |> code() ==
             "unknown_market"

    quote = fn body ->
      send_json(build_conn(), "POST", "/api/v1/covered-calls/AMZNc/quote", body)
    end

    assert quote.(%{"strike_per_token" => 250_000_000, "expiry" => expiry() + 3_600})
           |> json_response(422)
           |> code() == "not_a_weekly_expiry"

    assert quote.(%{"strike_per_token" => 250_000_000, "expiry" => expiry(), "x" => 1})
           |> json_response(422)
           |> code() == "invalid_request"

    assert quote.(%{"strike_per_token" => "250", "expiry" => expiry()})
           |> json_response(422)
           |> code() == "invalid_request"
  end

  test "a signed agent's steps are built only for a wallet of the account it acts for" do
    switch(:on)
    open_site()
    {wallet, signed} = paired_agent()
    chain(%{balance: 100_000_000, allowance: 0})

    fill = %{"kind" => "fill", "listing_id" => 1, "amount" => @token}

    steps = fn body ->
      send_json(signed.(), "POST", "/api/agent/v1/covered-calls/AMZNc/steps", body)
    end

    stranger = "0x" <> String.duplicate("ab", 20)

    assert steps.(Map.put(fill, "signer", stranger)) |> json_response(403) |> code() ==
             "wrong_signer"

    prepared = steps.(fill) |> json_response(200)

    assert %{"kind" => "fill", "signer" => ^wallet, "approved" => false} = prepared["data"]
    assert prepared["data"]["blocked"]["code"] == "approve_first"
    assert [approve, buy] = prepared["data"]["steps"]
    assert approve["to"] == @usdc and buy["to"] == @contract

    assert buy["data"] ==
             LabAbi.selector("fill(uint256,uint256)") <>
               BaseRpcStub.hex_word(1) <> BaseRpcStub.hex_word(@token)

    assert prepared["data"]["facts"]["premium"] == 5_000_000

    chain(%{balance: 100_000_000, allowance: 5_000_000})
    prepared = steps.(Map.put(fill, "signer", wallet)) |> json_response(200)
    assert %{"approved" => true, "blocked" => nil} = prepared["data"]

    assert steps.(%{fill | "kind" => "borrow"}) |> json_response(422) |> code() ==
             "invalid_request"

    assert steps.(Map.put(fill, "actor", wallet)) |> json_response(422) |> code() ==
             "invalid_request"

    assert steps.(%{"kind" => "fill", "listing_id" => 9, "amount" => 0})
           |> json_response(422)
           |> code() == "invalid_request"

    chain(%{balance: 10 * @token, allowance: 0})

    listed =
      steps.(%{
        "kind" => "list",
        "amount" => 10 * @token,
        "strike_per_token" => 250_000_000,
        "premium_per_token" => 5_000_000,
        "expiry" => expiry()
      })
      |> json_response(200)

    assert [%{"to" => @stock}, %{"to" => @contract}] = listed["data"]["steps"]
    assert listed["data"]["blocked"]["code"] == "approve_first"

    holdings =
      signed.() |> get("/api/agent/v1/covered-calls/AMZNc/positions") |> json_response(200)

    assert %{"wallet" => ^wallet, "sold" => [], "holdings" => []} = holdings["data"]
  end

  test "the signed-in route needs a sign-in and reads only the signed-in wallet", %{conn: conn} do
    switch(:on)
    chain(%{held: 3 * @token})

    assert conn |> get("/api/v1/me/covered-calls/AMZNc") |> json_response(401) |> code() ==
             "authentication_required"

    account = TestSupport.register_creator!()
    conn = init_test_session(build_conn(), %{human_account_id: account.id})
    mine = conn |> get("/api/v1/me/covered-calls/AMZNc") |> json_response(200)
    wallet = String.downcase(account.wallet_address)

    assert %{"wallet" => ^wallet, "holdings" => [%{"listing_id" => 1, "held" => held}]} =
             mine["data"]

    assert held == 3 * @token
  end

  defp code(body), do: body["error"]["code"]
end
