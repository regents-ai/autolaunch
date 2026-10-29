defmodule AutolaunchWeb.ExposureRoutesTest do
  @moduledoc """
  The After-hours Exposure HTTP routes against a stubbed Base chain: off,
  every route is an address with nothing at it and nothing advertises them; on,
  the public reads answer anyone, a series' terms are served as the exact bytes
  its fingerprint names, and a paired agent's steps are built only for a wallet
  of the account it acts for.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.ExposureChain
  alias RegentAgents.Person

  @moduletag :capture_log
  @series ExposureChain.series()
  # The page itself is checked in AutolaunchWeb.ExposureLiveTest.
  @routes [
    {:get, "/after-hour-stocks/terms/#{ExposureChain.terms_hash()}"},
    {:get, "/assets/js/exposure.css"},
    {:get, "/api/v1/after-hour-stocks"},
    {:get, "/api/v1/after-hour-stocks/#{ExposureChain.series()}"},
    {:get, "/api/v1/me/after-hour-stocks/#{ExposureChain.series()}"},
    {:get, "/api/agent/v1/after-hour-stocks/#{ExposureChain.series()}/holdings"},
    {:post, "/api/agent/v1/after-hour-stocks/#{ExposureChain.series()}/steps"}
  ]
  @tools ~w(autolaunch_after_hour_stocks_list autolaunch_after_hour_stocks_series autolaunch_my_after_hour_stocks autolaunch_after_hour_stocks_prepare)

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

      capabilities = build_conn() |> get("/capabilities") |> json_response(200)
      names = Enum.map(capabilities["tools"], & &1["name"])
      paths = build_conn() |> get("/openapi.json") |> json_response(200) |> Map.fetch!("paths")
      guide = build_conn() |> get("/llms-full.txt") |> response(200)
      home = build_conn() |> get("/") |> html_response(200)

      assert Enum.all?(@tools, &(&1 in names)) == offered?
      assert Enum.any?(@tools, &(&1 in names)) == offered?
      assert Map.has_key?(paths, "/api/v1/after-hour-stocks/{series}") == offered?
      assert guide =~ "After-hours Exposure" == offered?
      assert home =~ ~s(/assets/js/exposure.css) == offered?
    end
  end

  test "the public reads give the series' tokens, values, prices and schedule" do
    ExposureChain.install()

    [listed] =
      build_conn()
      |> get("/api/v1/after-hour-stocks")
      |> json_response(200)
      |> Map.fetch!("data")

    series =
      build_conn()
      |> get("/api/v1/after-hour-stocks/#{@series}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert listed["address"] == series["address"]
    assert series["status"] == "active"
    assert series["price"] == 256 * ExposureChain.wad()
    assert series["after_hours"]["ledger"] == 131 * ExposureChain.wad()
    assert series["market_hours"]["ledger"] == 125 * ExposureChain.wad()
    assert series["after_hours"]["symbol"] == "AMZNc-AH-1106"
    assert series["after_hours"]["pool"]["usdc_per_token"] == 2_640_000
    assert length(series["schedule"]) == 11
    assert [%{"kind" => "close", "price" => _}, %{"kind" => "open"}] = series["prints"]
    assert series["next"]["kind"] == "close"
    assert series["terms_url"] =~ "/after-hour-stocks/terms/#{ExposureChain.terms_hash()}"

    unknown =
      build_conn() |> get("/api/v1/after-hour-stocks/0x1234567890123456789012345678901234567890")

    assert unknown |> json_response(404) |> code() == "unknown_series"
  end

  test "a series' terms are served as the exact bytes its fingerprint names" do
    ExposureChain.install()

    terms = build_conn() |> get("/after-hour-stocks/terms/#{ExposureChain.terms_hash()}")
    assert terms.status == 200

    assert "0x" <> Base.encode16(ExKeccak.hash_256(terms.resp_body), case: :lower) ==
             ExposureChain.terms_hash()

    missing = build_conn() |> get("/after-hour-stocks/terms/0x" <> String.duplicate("ab", 32))
    assert missing |> json_response(404) |> code() == "unknown_terms"
  end

  test "every terms file the site serves is named by the keccak256 of its own bytes" do
    for path <- Path.wildcard(Application.app_dir(:autolaunch, "priv/exposure_terms/*.md")) do
      hash = "0x" <> Base.encode16(ExKeccak.hash_256(File.read!(path)), case: :lower)
      assert Path.basename(path, ".md") == hash
    end
  end

  test "a signed agent's steps are built only for a wallet of the account it acts for" do
    ExposureChain.install()
    open_site()
    {wallet, signed} = paired_agent()

    steps = fn body ->
      send_json(signed.(), "POST", "/api/agent/v1/after-hour-stocks/#{@series}/steps", body)
    end

    stranger = "0x" <> String.duplicate("ab", 20)
    mint = %{"kind" => "mint", "amount" => 1_000_000}

    assert steps.(Map.put(mint, "signer", stranger)) |> json_response(403) |> code() ==
             "wrong_signer"

    prepared = steps.(mint) |> json_response(200)
    assert %{"kind" => "mint", "signer" => ^wallet, "approved" => false} = prepared["data"]
    assert prepared["data"]["blocked"]["code"] == "approve_first"
    assert Enum.map(prepared["data"]["steps"], & &1["step"]) == ["stock_approval", "mint"]

    assert steps.(Map.put(mint, "extra", 1)) |> json_response(422) |> code() == "invalid_request"

    assert steps.(%{"kind" => "mint", "amount" => "1"}) |> json_response(422) |> code() ==
             "invalid_request"

    holdings =
      signed.()
      |> get("/api/agent/v1/after-hour-stocks/#{@series}/holdings")
      |> json_response(200)

    assert %{"wallet" => ^wallet, "stock" => 50_000_000} = holdings["data"]
  end
end
