defmodule AutolaunchWeb.ExposureRoutesTest do
  @moduledoc """
  The Isolated Exposure to After-hours Stocks HTTP routes against a stubbed Base chain: off,
  every route is an address with nothing at it and nothing advertises them; on,
  the public reads answer anyone, a week's terms are served as the exact bytes
  its fingerprint names, and a paired agent's steps are built only for a wallet
  of the account it acts for.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.ExposureChain
  alias RegentAgents.Person

  @moduletag :capture_log
  @week ExposureChain.week()
  # The page itself is checked in AutolaunchWeb.ExposureLiveTest.
  @routes [
    {:get, "/stock/isolated-afters/terms/#{ExposureChain.terms_hash()}"},
    {:get, "/assets/js/exposure.css"},
    {:get, "/api/v1/after-hour-stocks"},
    {:get, "/api/v1/after-hour-stocks/#{@week}"},
    {:get, "/api/v1/me/after-hour-stocks/#{@week}"},
    {:get, "/api/agent/v1/after-hour-stocks/#{@week}/holdings"},
    {:post, "/api/agent/v1/after-hour-stocks/#{@week}/steps"}
  ]
  @tools ~w(autolaunch_after_hour_stocks_list autolaunch_after_hour_stocks_week autolaunch_my_after_hour_stocks autolaunch_after_hour_stocks_prepare)

  # Past the prelaunch gate, which refuses wallet steps until the site opens.
  defp open_site do
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
  end

  defp off do
    previous = Application.get_env(:autolaunch, :exposure)
    on_exit(fn -> Application.put_env(:autolaunch, :exposure, previous) end)
    Application.put_env(:autolaunch, :exposure, :off)
  end

  defp send_json(conn, method, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> dispatch(@endpoint, method, path, Jason.encode!(body))
  end

  defp code(body), do: body["error"]["code"]

  # A paired agent acting for a new account whose one wallet is returned.
  defp paired_agent do
    privy = "did:privy:exposure-#{System.unique_integer([:positive])}"
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

  test "EXPOSURE_OFF_IS_NOT_FOUND: every route answers as an unknown address while switched off" do
    open_site()
    off()

    for {method, path} <- @routes do
      answer = build_conn() |> send_json(method, path, %{})
      assert answer.status == 404, "#{path} answered #{answer.status}"
    end
  end

  test "EXPOSURE_ADVERTISED_ONLY_WHEN_ON: tools, routes, guides and the page's tools follow the switch" do
    open_site()

    for {state, offered?} <- [off: false, on: true] do
      if state == :on, do: ExposureChain.install(), else: off()

      capabilities = build_conn() |> get("/capabilities.json") |> json_response(200)
      names = Enum.map(capabilities["tools"], & &1["name"])
      paths = build_conn() |> get("/openapi.json") |> json_response(200) |> Map.fetch!("paths")
      guide = build_conn() |> get("/llms-full.txt") |> response(200)
      home = build_conn() |> get("/") |> html_response(200)

      assert Enum.all?(@tools, &(&1 in names)) == offered?
      assert Enum.any?(@tools, &(&1 in names)) == offered?
      assert Map.has_key?(paths, "/api/v1/after-hour-stocks/{week}") == offered?
      assert guide =~ "Isolated Exposure to After-hours Stocks" == offered?
      assert home =~ ~s(/assets/js/exposure.css) == offered?
    end
  end

  test "the public reads give this week and the weeks that opened, with tokens, values, prices and schedule" do
    ExposureChain.install(%{
      weeks: %{
        (@week - 1) => %{
          status: 2,
          end_reason: 1,
          prices: List.duplicate(250 * ExposureChain.wad(), 11),
          pools: %{}
        }
      }
    })

    list =
      build_conn() |> get("/api/v1/after-hour-stocks") |> json_response(200) |> Map.fetch!("data")

    assert %{"current_week" => @week, "opening_paused" => false} = list
    assert list["factory"] == ExposureChain.factory()

    assert [%{"week" => @week, "current" => true}, %{"week" => past, "current" => false}] =
             list["weeks"]

    assert past == @week - 1

    week =
      build_conn()
      |> get("/api/v1/after-hour-stocks/#{@week}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert week["series"] == ExposureChain.series()

    assert %{"opened" => true, "status" => "active", "prices_applied" => 2, "prices_waiting" => 0} =
             week

    assert week["price"] == 256 * ExposureChain.wad()
    assert week["after_hours"]["ledger"] == 131 * ExposureChain.wad()
    assert week["market_hours"]["ledger"] == 125 * ExposureChain.wad()
    assert week["after_hours"]["symbol"] == "AMZNc-AH-1120"
    assert week["after_hours"]["pool"]["usdc_per_token"] == 2_640_000
    assert length(week["schedule"]) == 11

    assert [
             %{
               "kind" => "close",
               "price" => 250_000_000_000_000_000_000,
               "feed_round_id" => close
             },
             %{"kind" => "open", "after_hours" => 131_000_000_000_000_000_000}
           ] = week["prices"]

    # The last week's eleven prices came first; its last close is this week's first.
    assert close == Bitwise.bsl(ExposureChain.phase(), 64) + 11
    assert %{"kind" => "close", "index" => 2} = week["next"]
    assert week["next"]["applies_at"] == week["next"]["at"] + 3_600
    assert week["terms_url"] =~ "/stock/isolated-afters/terms/#{ExposureChain.terms_hash()}"

    ended = build_conn() |> get("/api/v1/after-hour-stocks/#{@week - 1}") |> json_response(200)
    assert %{"status" => "ended", "end_reason" => "maturity", "next" => nil} = ended["data"]

    for {path, status, code} <- [
          {"/api/v1/after-hour-stocks/#{@week - 2}", 404, "unknown_week"},
          {"/api/v1/after-hour-stocks/#{@week + 1}", 404, "unknown_week"},
          {"/api/v1/after-hour-stocks/soon", 422, "invalid_request"}
        ] do
      assert build_conn() |> get(path) |> json_response(status) |> code() == code
    end
  end

  test "a week not open yet is read at the address it will open at, with the terms it would open with" do
    ExposureChain.install(%{week: %{opened: false}, paused: true})

    week =
      build_conn()
      |> get("/api/v1/after-hour-stocks/#{@week}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert %{"opened" => false, "status" => "unopened", "opening_paused" => true, "prices" => []} =
             week

    assert week["series"] == ExposureChain.series()
    assert week["after_hours"]["address"] == nil
    assert week["after_hours"]["symbol"] == "AMZNc-AH-1120"
    assert week["deposit_cap"] == 40_000_000
    assert week["deposited"] == 0
  end

  # A node that answers, but not as Base or not with a block or a figure.
  defmodule OddNode do
    def post(url, options) do
      case {Application.fetch_env!(:autolaunch, :exposure_odd_node), options[:json]} do
        {:wrong_chain, %{method: "eth_chainId"}} ->
          answer("0x1")

        {:invalid_block_header, %{method: "eth_getBlockByNumber"}} ->
          answer(%{"number" => "0x20"})

        {:invalid_chain_response, %{method: "eth_call"}} ->
          answer("0x")

        _other ->
          ExposureChain.post(url, options)
      end
    end

    defp answer(result), do: {:ok, %{status: 200, body: %{"result" => result}}}
  end

  test "a node that answers oddly is a chain that can't be read just now, never a server error" do
    ExposureChain.install()
    Application.put_env(:autolaunch, :autolaunch_lab_http_client, OddNode)
    on_exit(fn -> Application.delete_env(:autolaunch, :exposure_odd_node) end)

    for fault <- [:wrong_chain, :invalid_block_header, :invalid_chain_response] do
      Application.put_env(:autolaunch, :exposure_odd_node, fault)

      answer = build_conn() |> get("/api/v1/after-hour-stocks/#{@week}")
      assert answer |> json_response(503) |> code() == Atom.to_string(fault)
    end
  end

  test "a week's terms are served as the exact bytes its fingerprint names" do
    ExposureChain.install()

    terms = build_conn() |> get("/stock/isolated-afters/terms/#{ExposureChain.terms_hash()}")
    assert terms.status == 200

    assert "0x" <> Base.encode16(ExKeccak.hash_256(terms.resp_body), case: :lower) ==
             ExposureChain.terms_hash()

    missing = build_conn() |> get("/stock/isolated-afters/terms/0x" <> String.duplicate("ab", 32))
    assert missing |> json_response(404) |> code() == "unknown_terms"
  end

  test "every terms file the site serves is named by the keccak256 of its own bytes" do
    for path <- Path.wildcard(Application.app_dir(:autolaunch, "priv/exposure_terms/0x*.md")) do
      hash = "0x" <> Base.encode16(ExKeccak.hash_256(File.read!(path)), case: :lower)
      assert Path.basename(path, ".md") == hash
    end
  end

  test "a signed agent's steps are built only for a wallet of the account it acts for" do
    ExposureChain.install()
    open_site()
    {wallet, signed} = paired_agent()

    steps = fn body ->
      send_json(signed.(), "POST", "/api/agent/v1/after-hour-stocks/#{@week}/steps", body)
    end

    stranger = "0x" <> String.duplicate("ab", 20)
    deposit = %{"kind" => "deposit", "amount" => 1_000_000}

    assert steps.(Map.put(deposit, "signer", stranger)) |> json_response(403) |> code() ==
             "wrong_signer"

    prepared = steps.(deposit) |> json_response(200)

    assert %{"kind" => "deposit", "week" => @week, "signer" => ^wallet, "approved" => false} =
             prepared["data"]

    assert prepared["data"]["blocked"]["code"] == "approve_first"
    assert Enum.map(prepared["data"]["steps"], & &1["step"]) == ["stock_approval", "deposit"]

    assert Enum.map(prepared["data"]["steps"], & &1["to"]) == [
             ExposureChain.stock(),
             ExposureChain.factory()
           ]

    assert steps.(Map.put(deposit, "extra", 1)) |> json_response(422) |> code() ==
             "invalid_request"

    assert steps.(%{"kind" => "deposit", "amount" => "1"}) |> json_response(422) |> code() ==
             "invalid_request"

    settle = steps.(%{"kind" => "settle"}) |> json_response(200)
    assert [%{"step" => "settle", "to" => series}] = settle["data"]["steps"]
    assert series == ExposureChain.series()

    assert %{"due" => 0, "ends" => false, "next" => %{"kind" => "close", "index" => 2}} =
             settle["data"]["facts"]

    holdings =
      signed.()
      |> get("/api/agent/v1/after-hour-stocks/#{@week}/holdings")
      |> json_response(200)

    assert %{"week" => @week, "wallet" => ^wallet, "stock" => 50_000_000, "usdc" => 0} =
             holdings["data"]

    # Buying a token: the agent names it and the USDC to spend; a token it can't name is refused.
    buy =
      steps.(%{"kind" => "buy", "leg" => "overnight", "amount" => 10_000_000})
      |> json_response(200)

    assert Enum.map(buy["data"]["steps"], & &1["step"]) == ["usdc_approval", "buy"]
    assert buy["data"]["blocked"]["code"] == "not_enough_usdc"
    assert buy["data"]["facts"]["minimum"] == 2_587_200

    assert steps.(%{"kind" => "buy", "amount" => 1}) |> json_response(422) |> code() ==
             "leg_required"

    assert steps.(%{"kind" => "buy", "leg" => "afternoon", "amount" => 1})
           |> json_response(422)
           |> code() ==
             "invalid_request"

    # A week not open yet takes a deposit, and nothing that needs its tokens.
    ExposureChain.put(%{week: %{opened: false}})

    assert steps.(deposit) |> json_response(200) |> get_in(["data", "steps"]) |> length() == 2

    assert steps.(%{"kind" => "redeem", "overnight" => 1, "session" => 1})
           |> json_response(409)
           |> code() == "week_not_open"
  end
end
