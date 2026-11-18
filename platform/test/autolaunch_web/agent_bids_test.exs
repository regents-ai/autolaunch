defmodule AutolaunchWeb.AgentBidsTest do
  @moduledoc """
  Agent bids on a paired agent's two ways in: the signed routes the browser
  tools call and the hosted MCP tools give one answer for one input, refusals
  in the same code and words.

  A bid's steps are the auction page's for the same inputs and wallet, and a
  return and claim's are the bid card's. Only the person's own wallets and
  bids are prepared for, and only for the agent paired with them, while the
  person has a verified wallet. Every refusal is reached and named, with a
  status and code the contract documents, and every reason the reviews give has
  one code. Figures the page would refuse are refused before any treasury or
  chain read. A bid on an auction whose bidding has ended is refused. A read
  that fails, or a chain error nobody named, is refused as `bid_unavailable`.
  Off, or in prelaunch read-only mode, neither tool is listed or run, and off a
  call to either is answered as one to a tool that does not exist.

  The chains are the bid and settlement doubles, and the sign-in service is
  stubbed: it vouches for the wallet a request names.
  """
  use AutolaunchWeb.ConnCase, async: false
  use ExUnitProperties

  import Autolaunch.BidFixture,
    only: [auction_address: 0, bidder: 1, install: 1, regent: 0, system: 0, wallet: 0]

  import Autolaunch.DatabaseFaults, only: [lose_reads_of: 1, restore_reads_of: 1]
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Plug.Test, only: [conn: 3]

  alias Autolaunch.Actors.{Agent, ConnectedApp, Human}
  alias Autolaunch.AgentBid.Refused
  alias AutolaunchWeb.AgentBidAnswer

  alias Autolaunch.{
    Accounts,
    AgentBid,
    BidActions,
    BidSettlementActions,
    LabAbi,
    TestAutolaunchBidSettlementChainClient,
    TestAutolaunchTreasuryChainClient,
    TestSupport
  }

  @moduletag :capture_log
  @contract "../../contracts/agent-bids.openapiv3.yaml"
            |> Path.expand(__DIR__)
            |> YamlElixir.read_from_file!()
  @codes get_in(
           @contract,
           ~w(components schemas AgentBidError properties error properties code enum)
         )
  @schemas @contract["components"]["schemas"]
  @tools ~w(prepare_bid prepare_bid_settlement)
  @bid_path "/api/agent/v1/bids/steps"
  @settle_path "/api/agent/v1/bids/{bid}/steps"
  @other "0x2222222222222222222222222222222222222222"
  @safe "0x9999999999999999999999999999999999999999"
  # The launchpad and bid adapter the fixture Base Stocks deployment names.
  @launchpad "0x0f8955a7f09ec713bb71c30e07b512ecee69a044"
  @adapter "0x55565be42bacfab336ef1aefbd254b9cbb738688"
  @onchain_bid 7
  # A Permit2 allowance the wallet already holds for as long as Permit2 allows,
  # so a bid's steps carry no clock time.
  @permitted [permit2_amount: Integer.pow(2, 160) - 1, permit2_expiration: Integer.pow(2, 48) - 1]

  defmodule WatchedChain do
    @moduledoc false
    # The bid double, telling the test process of each read it answers.
    @behaviour Autolaunch.LabBidChainClient

    @impl true
    def snapshot(request) do
      send(self(), :chain_read)
      Autolaunch.TestAutolaunchBidChainClient.snapshot(request)
    end

    @impl true
    def balances(request) do
      send(self(), :chain_read)
      Autolaunch.TestAutolaunchBidChainClient.balances(request)
    end
  end

  defmodule StockRpc do
    @moduledoc false
    # Base's answers to a USDC bid's own reads: the stock's admission, the
    # wallet's USDC and its allowance, and the route's estimate. `put/1`
    # replaces any of them for the calling test.
    alias Autolaunch.LabAbi

    def put(words), do: Process.put(__MODULE__, Map.merge(words(), words))

    def post(_url, options) do
      %{method: method, params: params} = options[:json]
      {:ok, %{status: 200, body: %{"result" => answer(method, params)}}}
    end

    defp answer("eth_chainId", _params), do: "0x2105"
    defp answer("eth_getCode", _params), do: "0x6080"

    defp answer("eth_getBlockByNumber", _params),
      do: %{
        "number" => "0x96",
        "hash" => "0x" <> String.duplicate("ab", 32),
        "timestamp" => "0x6700"
      }

    defp answer("eth_call", [%{data: data}, _block]),
      do:
        "0x" <>
          Enum.map_join(
            Map.fetch!(words(), String.slice(data, 0, 10)),
            &Autolaunch.BaseRpcStub.hex_word/1
          )

    defp words do
      Process.get(__MODULE__, %{
        LabAbi.selector("stockAdmission(address)") => [
          1,
          18,
          0x2222222222222222222222222222222222222222
        ],
        LabAbi.selector("balanceOf(address)") => [100_000_000],
        LabAbi.selector("allowance(address,address)") => [100_000_000],
        LabAbi.selector("quoteExactIn(address,address,uint256)") => [Integer.pow(10, 21)]
      })
    end
  end

  setup :bidder

  setup %{account: account, auction: auction} do
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

    for key <- [:agent_bids, :prelaunch_read_only, :autolaunch_lab_http_client], do: keep_env(key)
    Application.put_env(:autolaunch, :agent_bids, :on)
    # Past the prelaunch gate, which refuses wallet steps until the site opens.
    Application.put_env(:autolaunch, :prelaunch_read_only, false)

    report = TestAutolaunchTreasuryChainClient.seed_verified!(@safe)
    Autolaunch.set_auction_treasury_security_report!(auction, report.id, actor: system())

    %{agent: paired_agent(account), report: report}
  end

  test "a bid's steps are the auction page's for the same inputs and wallet, alike on both ways in",
       %{agent: agent, auction: auction, wallet: wallet, opts: opts} do
    allowed = [token_allowance: Integer.pow(10, 30)]

    for {chain, input, named} <- [
          {@permitted, %{auction_id: auction.id, amount: "12.5", max_price: "3"},
           ~w(token_approval bid)},
          {@permitted, %{auction_id: auction.id, amount: "1", max_price: "4", signer: wallet},
           ~w(token_approval bid)},
          {allowed ++ @permitted, %{auction_id: auction.id, amount: "1", max_price: "3"}, ~w(bid)}
        ] do
      install(chain)
      {:ok, page} = BidActions.prepare(Map.delete(input, :signer), wallet, opts)
      {:ok, data} = answer(http(:post, @bid_path, input, agent))

      assert tool(agent, "prepare_bid", input) == {:ok, data}
      assert Enum.map(data["steps"], & &1["step"]) == named
      assert data["steps"] == plain(page.steps)
      assert data["facts"] == plain(page.facts)
      assert data["chain"] == plain(page.chain)

      assert %{"kind" => "bid", "signer" => ^wallet, "block" => 30_000_000} = data
      assert Enum.sort(Map.keys(data)) == Enum.sort(@schemas["AgentBidSteps"]["required"])
      assert data["auction"] == %{"id" => auction.id, "address" => auction_address()}
      # False while the steps still hold an approval, true once only the bid is left.
      assert data["approved"] == (named == ["bid"])
    end
  end

  test "a USDC bid on a Memestock auction goes through its bid adapter with the page's facts",
       %{agent: agent, wallet: wallet, opts: opts} do
    install(@permitted)
    stock_rpc()
    auction = memestock_auction!()

    for input <- [
          %{auction_id: auction.id, amount: "10", max_price: "3", pay_with: "USDC"},
          %{
            auction_id: auction.id,
            amount: "10",
            max_price: "3",
            pay_with: "USDC",
            slippage_percent: "12.5"
          }
        ] do
      {:ok, page} = BidActions.prepare(input, wallet, opts)
      {:ok, data} = answer(http(:post, @bid_path, input, agent))
      {:ok, by_tool} = tool(agent, "prepare_bid", input)

      # The adapter's deadline is the clock's, so each answer is compared
      # without the calldata that carries it.
      for answer <- [data, by_tool] do
        assert answer["facts"] == plain(page.facts)
        assert [%{"step" => "usdc_bid", "to" => @adapter, "value" => "0x0"}] = answer["steps"]
        assert answer["approved"]
      end

      minimum = hd(data["steps"])["data"] |> String.slice(138, 64) |> String.to_integer(16)

      assert {:ok, ^minimum} =
               Autolaunch.Stocks.Amounts.parse_units(data["facts"]["min_stock_out"], 18)
    end
  end

  test "a bid on an auction whose bidding has ended is refused, by the auction's record or the block, while the page still reviews it",
       %{agent: agent, report: report, wallet: wallet} do
    install(@permitted)

    for fields <- [
          %{state: :ended},
          %{state: :graduated},
          %{state: :failed},
          # The latest block, 30_000_000, at the end block and past it.
          %{state: :active, end_block: 30_000_000},
          %{state: :active, end_block: 29_999_999}
        ] do
      auction = base_auction!(fields, report)
      input = %{auction_id: auction.id, amount: "1", max_price: "3"}
      route = http(:post, @bid_path, input, agent)

      assert route.status == 409 and route.body["error"]["code"] == "bidding_ended",
             "#{inspect(fields)} answered #{inspect(route.body)}"

      refute Map.has_key?(route.body, "data")
      assert tool(agent, "prepare_bid", input) == {:error, route.body}
      assert documented?(@bid_path, 409, "bidding_ended")

      # The auction page still shows its review, with why it no longer bids.
      assert {:ok, %{blocked: :bidding_ended, steps: [_ | _]}} =
               BidActions.review(input, wallet)
    end

    open = base_auction!(%{state: :active, end_block: 30_000_001}, report)
    input = %{auction_id: open.id, amount: "1", max_price: "3"}
    assert {:ok, %{"steps" => [_ | _]}} = answer(http(:post, @bid_path, input, agent))
  end

  test "a bid's return and claim are the bid card's steps, alike on both ways in", context do
    %{agent: agent, auction: auction, wallet: wallet, opts: opts} = context
    position = position!(auction, wallet)

    for settlement <- [
          [
            graduated?: false,
            exit: exit_bid(5 * 10 ** 18, 0),
            claim: {:refused, :nothing_to_claim}
          ],
          [
            graduated?: true,
            exit: exit_bid(0, 1_200_000 * 10 ** 18),
            claim: %{data: claim_data(), tokens_claimed: 1_200_000 * 10 ** 18}
          ],
          [
            graduated?: true,
            exit: {:refused, :already_exited},
            claim: %{data: claim_data(), tokens_claimed: 10 ** 18}
          ],
          [
            graduated?: false,
            exit: {:refused, :price_not_recorded},
            claim: {:refused, :claim_not_open}
          ]
        ] do
      settle(settlement)
      {:ok, page} = BidSettlementActions.prepare(position.id, wallet, opts)
      {:ok, data} = answer(http(:post, settle_path(position.bid_id), %{}, agent))

      assert tool(agent, "prepare_bid_settlement", %{bid: position.bid_id}) == {:ok, data}
      assert data["steps"] == plain(page.steps)
      assert data["facts"] == plain(page.facts)

      assert %{"kind" => "settle", "signer" => ^wallet, "block" => 100, "bid" => bid} = data
      assert Enum.sort(Map.keys(data)) == Enum.sort(@schemas["AgentBidSettlement"]["required"])
      assert bid == position.bid_id
      assert data["auction"] == %{"id" => auction.id, "address" => auction_address()}
    end
  end

  test "only the person's own wallets are prepared for, and only their own bids are seen",
       context do
    %{agent: agent, auction: auction, wallet: wallet} = context
    install(@permitted)
    settle(graduated?: false, exit: exit_bid(1, 0), claim: {:refused, :nothing_to_claim})
    theirs = position!(auction, @other)
    mine = position!(auction, wallet)
    bid = %{auction_id: auction.id, amount: "1", max_price: "3"}

    for {path, tool, input, status, code} <- [
          {@bid_path, "prepare_bid", Map.put(bid, :signer, @other), 403, "wrong_signer"},
          {settle_path(mine.bid_id), "prepare_bid_settlement", %{signer: @other}, 403,
           "wrong_signer"},
          {settle_path(theirs.bid_id), "prepare_bid_settlement", %{}, 404, "not_your_bid"},
          {settle_path("lab:nobody"), "prepare_bid_settlement", %{}, 404, "not_your_bid"}
        ] do
      route = http(:post, path, input, agent)
      assert route.status == status and route.body["error"]["code"] == code, path
      assert tool(agent, tool, tool_input(path, input)) == {:error, route.body}, path
    end

    # Another person's agent, asking for the same bid with its owner's wallet.
    stranger = paired_agent(TestSupport.register_creator!())
    route = http(:post, settle_path(mine.bid_id), %{signer: wallet}, stranger)
    assert route.status == 403 and route.body["error"]["code"] == "wrong_signer"
    route = http(:post, settle_path(mine.bid_id), %{}, stranger)
    assert route.status == 404 and route.body["error"]["code"] == "not_your_bid"
  end

  test "the steps are prepared for the paired agent alone, a connected app calling as it included",
       %{account: account, agent: wallet} do
    {:ok, agent} = Autolaunch.Agents.resolve(wallet)
    app_as_agent = %{agent | connection: %{subject: account.privy_user_id}}
    person = %Human{human_account_id: account.id}
    app = %ConnectedApp{principal: %{subject: account.privy_user_id}}

    for {action, input} <- [
          {:prepare, %{auction_id: Ash.UUID.generate(), amount: "1", max_price: "3"}},
          {:settle, %{bid: "lab:1"}}
        ],
        actor <- [agent, app_as_agent, person, app, %Autolaunch.Actors.System{}, nil] do
      may? = Ash.can?(Ash.ActionInput.for_action(Autolaunch.AgentBid, action, input), actor)
      assert may? == actor in [agent, app_as_agent], "#{action} for #{inspect(actor)}"
    end
  end

  test "every refusal is reached, named alike on both ways in, in a status and code the contract documents",
       context do
    %{agent: agent, auction: auction, wallet: wallet} = context
    tiny = "0." <> String.duplicate("0", 79) <> "1"
    bid = %{auction_id: auction.id, amount: "1", max_price: "3"}
    usdc = Map.put(bid, :pay_with, "USDC")
    spacing = 792_281_625_142_643_375_935_439

    grid = [
      tick_spacing_q96: spacing,
      floor_price_q96: spacing,
      clearing_price_q96: spacing,
      prev_tick_price_q96: spacing
    ]

    no_report = base_auction!(%{state: :active}, nil)
    ended = base_auction!(%{state: :ended}, context.report)
    memestock = memestock_auction!()
    stock = %{usdc | auction_id: memestock.id}
    unread = position!(auction, wallet, nil)
    theirs = position!(auction, @other)
    mine = position!(auction, wallet)
    settle = settle_path(mine.bid_id)
    stock_rpc()

    bids =
      [
        {[], Map.put(bid, :amount, 1), "invalid_request"},
        {[], Map.put(bid, :bogus, "x"), "invalid_request"},
        {[], Map.delete(bid, :max_price), "invalid_request"},
        {[], %{bid | auction_id: "nope"}, "invalid_request"},
        {[], Map.put(bid, :pay_with, "usdc"), "invalid_request"},
        {[], %{bid | amount: "0"}, "invalid_amount"},
        {[], %{bid | max_price: "x"}, "invalid_decimal"},
        {[], %{bid | max_price: tiny}, "invalid_price"},
        {[], Map.put(usdc, :slippage_percent, "100"), "invalid_slippage"},
        {grid, %{bid | max_price: "0.000001"}, "price_below_admissible_tick"},
        {[], %{bid | auction_id: Ecto.UUID.generate()}, "auction_not_found"},
        {[], Map.put(bid, :signer, @other), "wrong_signer"},
        {[], Map.put(bid, :signer, "nope"), "wallet_required"},
        {[], %{bid | auction_id: ended.id}, "bidding_ended"},
        {[predecessor_source: ""], bid, "bid_preparation_unavailable"},
        {[], %{bid | auction_id: no_report.id}, "treasury_report_missing"},
        {{:treasury, threshold: 1}, bid, "treasury_security_changed"},
        {{:treasury, error: :treasury_configuration_drift}, bid, "treasury_configuration_drift"},
        {[currency: @other], bid, "auction_currency_changed"},
        {[], %{bid | amount: "1000"}, "amount_above_balance"},
        {[], usdc, "usdc_bids_unavailable"},
        {{:stock, "stockAdmission(address)", [0, 18, 0]}, stock, "stock_not_admitted"},
        {{:stock, "quoteExactIn(address,address,uint256)", [0]}, stock, "usdc_route_unavailable"},
        {[unavailable: :chain_unavailable], bid, "chain_unavailable"},
        {[unavailable: :price_history_long], bid, "price_history_long"},
        # A treasury whose verified source block is no longer Base's.
        {{:treasury, canonical?: false}, bid, "treasury_security_changed"},
        # A chain error nobody named.
        {[unavailable: {:closed, :econnreset}], bid, "bid_unavailable"}
      ]
      |> Enum.map(fn {chain, input, code} -> {chain, @bid_path, @bid_path, input, code} end)

    settlements =
      [
        {[], settle_path("bad id!"), %{}, "invalid_request"},
        {[], settle, %{bogus: "x"}, "invalid_request"},
        {[], settle, %{signer: 1}, "invalid_request"},
        {[], settle_path(unread.bid_id), %{}, "position_not_on_chain"},
        {[], settle_path(theirs.bid_id), %{}, "not_your_bid"},
        {[], settle, %{signer: "nope"}, "wallet_required"},
        {[exit: {:refused, :bid_not_found}], settle, %{}, "bid_not_found"},
        {[exit: {:refused, :auction_not_started}], settle, %{}, "auction_not_started"},
        {[exit: {:refused, :auction_not_ended}], settle, %{}, "auction_not_ended"},
        {[exit: {:refused, :settlement_reverted}], settle, %{}, "settlement_reverted"},
        {[exit: {:refused, :bid_needs_partial_exit_hints_unavailable}], settle, %{},
         "bid_needs_partial_exit_hints_unavailable"},
        {[claim: {:refused, :already_exited}], settle, %{}, "already_exited"},
        {[claim: {:refused, :claim_not_open}], settle, %{}, "claim_not_open"},
        {[claim: {:refused, :nothing_to_claim}], settle, %{}, "nothing_to_claim"},
        {[claim: {:refused, :bid_not_exited}], settle, %{}, "bid_not_exited"}
      ]
      |> Enum.map(fn {exit, path, input, code} ->
        {{:settle, exit}, @settle_path, path, input, code}
      end)

    reached =
      for {chain, documented, path, input, code} <- bids ++ settlements do
        chain(chain)
        route = http(:post, path, input, agent)
        named = "#{path} #{inspect(input)}"

        assert route.body["error"]["code"] == code, "#{named} answered #{inspect(route.body)}"
        assert route.body["error"]["message"] != ""

        assert tool(agent, tool(documented), tool_input(path, input)) == {:error, route.body},
               named

        assert documented?(documented, route.status, code), "#{code} at #{route.status}"
        code
      end

    # An agent nobody paired, on either route.
    for {documented, path, input} <- [{@bid_path, @bid_path, bid}, {@settle_path, settle, %{}}] do
      route = http(:post, path, input, random_wallet())
      assert route.status == 403 and route.body["error"]["code"] == "agent_not_paired"
      assert documented?(documented, 403, "agent_not_paired")
    end

    # Each code the contract lists is reached here, but the account read and
    # prelaunch refusals, each in its own test below.
    assert Enum.sort(Enum.uniq(["agent_not_paired" | reached])) ==
             Enum.sort(
               @codes -- ~w(authentication_required account_unavailable prelaunch_read_only)
             )
  end

  test "a paired agent whose person's account cannot be read prepares nothing",
       %{auction: auction} do
    install(@permitted)

    unread = %Agent{
      wallet_address: random_wallet(),
      privy_user_id: "did:privy:unread",
      pairing_id: Ecto.UUID.generate(),
      human_account_id: Ecto.UUID.generate()
    }

    assert {:error, %Ash.Error.Unknown{errors: [%Refused{reason: :authentication_required}]}} =
             Autolaunch.prepare_bid(%{auction_id: auction.id, amount: "1", max_price: "3"},
               actor: unread
             )

    assert {:error, %Ash.Error.Unknown{errors: [%Refused{reason: :authentication_required}]}} =
             Autolaunch.prepare_bid_settlement(%{bid: "lab:any"}, actor: unread)

    assert documented?(@bid_path, 401, "authentication_required")
  end

  test "a person whose wallet evidence has lapsed, or no longer holds together, is refused wallet_required on both actions, never not_your_bid for their own bid",
       %{account: account, agent: agent, auction: auction, wallet: wallet} do
    install(@permitted)
    settle(graduated?: false, exit: exit_bid(1, 0), claim: {:refused, :nothing_to_claim})
    mine = position!(auction, wallet)
    bid = %{auction_id: auction.id, amount: "1", max_price: "3"}

    # Lapsed: no primary wallet and none listed, as a sign-in that finds no
    # linked wallet leaves it. Not holding together: wallets listed but no
    # primary among them.
    for {primary, addresses} <- [{nil, []}, {nil, [wallet]}, {@other, [wallet]}] do
      {:ok, _account} = Accounts.refresh_verified(account, primary, addresses, actor: system())

      for {path, documented, input} <- [
            {@bid_path, @bid_path, bid},
            {@bid_path, @bid_path, Map.put(bid, :signer, wallet)},
            {settle_path(mine.bid_id), @settle_path, %{}},
            {settle_path(mine.bid_id), @settle_path, %{signer: wallet}}
          ] do
        named = "#{inspect({primary, addresses})} #{path} #{inspect(input)}"
        route = http(:post, path, input, agent)

        assert route.status == 409 and route.body["error"]["code"] == "wallet_required",
               "#{named} answered #{inspect(route.body)}"

        assert tool(agent, tool(documented), tool_input(path, input)) == {:error, route.body},
               named

        assert documented?(documented, 409, "wallet_required")
      end
    end
  end

  test "a read that fails, or a chain error nobody named, is logged by kind alone and refused as bid_unavailable alike on both ways in",
       %{agent: agent, auction: auction, wallet: wallet} do
    mine = position!(auction, wallet)
    bid = %{auction_id: auction.id, amount: "1", max_price: "3"}

    refused = fn path, documented, input ->
      {route, log} = with_log(fn -> http(:post, path, input, agent) end)

      assert route.status == 503 and route.body["error"]["code"] == "bid_unavailable",
             "#{path} answered #{inspect(route.body)}"

      assert documented?(documented, 503, "bid_unavailable")
      assert tool(agent, tool(documented), tool_input(path, input)) == {:error, route.body}
      refute log =~ wallet
      log
    end

    install(@permitted ++ [unavailable: {:closed, :econnreset}])
    assert refused.(@bid_path, @bid_path, bid) =~ "agent bid failed: unnamed"

    install(@permitted)
    settle(graduated?: false, exit: exit_bid(1, 0), claim: {:refused, :nothing_to_claim})
    lose_reads_of("auctions")

    for {path, documented, input} <- [
          {@bid_path, @bid_path, bid},
          {settle_path(mine.bid_id), @settle_path, %{}}
        ] do
      assert refused.(path, documented, input) =~ "agent bid connection_lost"
    end

    restore_reads_of("auctions")

    # Whatever else an operation hands the routes, a policy's refusal or a
    # raw Ash error, is answered the same way.
    for error <- [
          Ash.Error.Forbidden.exception([]),
          Ash.Error.Unknown.exception(
            errors: [Ash.Error.Unknown.UnknownError.exception(error: "x")]
          ),
          :unexpected
        ] do
      {answered, log} =
        with_log(fn -> AgentBidAnswer.send(conn(:post, "/", ""), {:error, error}) end)

      assert answered.status == 503
      assert Jason.decode!(answered.resp_body)["error"]["code"] == "bid_unavailable"
      assert log =~ "agent bid failed"
    end
  end

  test "each reason the reviews, the wallet and the account give has one code, which both ways in answer in a status the contract documents; anything else is bid_unavailable" do
    codes = %{
      authentication_required: :authentication_required,
      wallet_required: :wallet_required,
      wrong_signer: :wrong_signer,
      auction_not_found: :auction_not_found,
      invalid_amount: :invalid_amount,
      invalid_decimal: :invalid_decimal,
      invalid_price: :invalid_price,
      invalid_slippage: :invalid_slippage,
      price_below_admissible_tick: :price_below_admissible_tick,
      bidding_ended: :bidding_ended,
      bid_preparation_unavailable: :bid_preparation_unavailable,
      auction_currency_changed: :auction_currency_changed,
      amount_above_balance: :amount_above_balance,
      usdc_bids_unavailable: :usdc_bids_unavailable,
      stock_not_admitted: :stock_not_admitted,
      usdc_route_unavailable: :usdc_route_unavailable,
      not_your_bid: :not_your_bid,
      position_not_on_chain: :position_not_on_chain,
      bid_not_found: :bid_not_found,
      auction_not_started: :auction_not_started,
      auction_not_ended: :auction_not_ended,
      already_exited: :already_exited,
      claim_not_open: :claim_not_open,
      nothing_to_claim: :nothing_to_claim,
      bid_not_exited: :bid_not_exited,
      settlement_reverted: :settlement_reverted,
      bid_needs_partial_exit: :settlement_reverted,
      bid_needs_partial_exit_hints_unavailable: :bid_needs_partial_exit_hints_unavailable,
      price_history_long: :price_history_long,
      treasury_report_missing: :treasury_report_missing,
      treasury_not_verified: :treasury_report_missing,
      treasury_security_changed: :treasury_security_changed,
      treasury_source_reorged: :treasury_security_changed,
      treasury_safe_evidence_mismatch: :treasury_security_changed,
      treasury_evidence_invalid: :treasury_security_changed,
      treasury_evidence_hash_invalid: :treasury_security_changed,
      treasury_transfer_evidence_invalid: :treasury_security_changed,
      treasury_execution_evidence_invalid: :treasury_security_changed,
      treasury_execution_input_invalid: :treasury_security_changed,
      treasury_module_pagination_cycle: :treasury_security_changed,
      treasury_configuration_drift: :treasury_configuration_drift,
      chain_unavailable: :chain_unavailable,
      invalid_chain_response: :chain_unavailable,
      invalid_block_header: :chain_unavailable,
      transaction_missing: :chain_unavailable,
      wrong_chain: :chain_unavailable,
      treasury_observation_incomplete: :chain_unavailable,
      treasury_module_pagination_incomplete: :chain_unavailable,
      invalid_address: :bid_unavailable,
      lab_contract_missing: :bid_unavailable
    }

    assert Map.new(codes, fn {reason, _code} -> {reason, AgentBid.code(reason)} end) == codes

    for unexpected <- [:unnamed_reason, {:closed, :econnreset}, "text", nil, %{reason: :x}],
        do: assert(AgentBid.code(unexpected) == :bid_unavailable)

    for code <- Enum.uniq([:bid_unavailable | Map.values(codes)]) do
      answered = AgentBidAnswer.refuse(conn(:post, "/", ""), code)
      body = Jason.decode!(answered.resp_body)
      assert body == AgentBidAnswer.body(code) |> plain(), "#{code}"
      assert body["error"]["code"] == Atom.to_string(code)

      assert documented?(@bid_path, answered.status, body["error"]["code"]) or
               documented?(@settle_path, answered.status, body["error"]["code"]),
             "#{code} at #{answered.status}"
    end
  end

  property "any amount, price and slippage is answered or refused alike on both ways in, and figures the page refuses never reach the treasury or the chain",
           %{agent: agent, auction: auction} do
    install(@permitted)
    Application.put_env(:autolaunch, :autolaunch_bid_chain_client, WatchedChain)
    # A treasury read here refuses, so a review that reached it says so.
    TestAutolaunchTreasuryChainClient.install(error: :treasury_configuration_drift)

    # Mostly text, as the page's own box sends, and sometimes another JSON value.
    text =
      one_of([
        member_of([
          "1",
          "12.5",
          "0",
          "-1",
          "1e3",
          "1.",
          ".5",
          " 1",
          "NaN",
          "0x10",
          "1,5",
          "",
          "99.99",
          String.duplicate("9", 101),
          "0." <> String.duplicate("0", 79) <> "1",
          "1.0000000000000000001"
        ]),
        string(?0..?9, min_length: 1, max_length: 60),
        string(:printable, max_length: 120)
      ])

    other =
      one_of([
        integer(),
        float(),
        boolean(),
        constant(nil),
        list_of(integer(), max_length: 2)
      ])

    figure = frequency([{5, text}, {1, other}])

    check all(
            amount <- figure,
            max_price <- figure,
            slippage <- one_of([constant(:none), figure]),
            usdc? <- boolean(),
            max_runs: 50
          ) do
      body =
        %{auction_id: auction.id, amount: amount, max_price: max_price}
        |> then(&if(slippage == :none, do: &1, else: Map.put(&1, :slippage_percent, slippage)))
        |> then(&if(usdc?, do: Map.put(&1, :pay_with, "USDC"), else: &1))

      route = http(:post, @bid_path, body, agent)
      assert tool(agent, "prepare_bid", body) == answer(route)
      assert route.body["error"]["code"] in @codes
      assert documented?(@bid_path, route.status, route.body["error"]["code"])
      refute_received :chain_read

      cond do
        refused_figures?(body) -> assert route.status == 422, inspect(body)
        usdc? -> assert route.body["error"]["code"] == "usdc_bids_unavailable"
        true -> assert route.body["error"]["code"] == "treasury_configuration_drift"
      end
    end
  end

  test "in prelaunch read-only mode neither tool is listed or run, and both routes wait",
       %{agent: agent, auction: auction, wallet: wallet} do
    install(@permitted)
    mine = position!(auction, wallet)
    Application.put_env(:autolaunch, :prelaunch_read_only, true)

    for {path, documented} <- [{@bid_path, @bid_path}, {settle_path(mine.bid_id), @settle_path}] do
      route = http(:post, path, %{}, agent)
      assert route.status == 503 and route.body["error"]["code"] == "prelaunch_read_only"
      assert documented?(documented, 503, "prelaunch_read_only")
    end

    refute Enum.any?(@tools, &(&1 in tool_names(agent)))

    for {name, input} <- [
          {"prepare_bid", %{auction_id: auction.id, amount: "1", max_price: "3"}},
          {"prepare_bid_settlement", %{bid: mine.bid_id}}
        ] do
      assert %{"error" => _} = json(mcp(agent, call(name, input)))
    end
  end

  test "switched on a paired agent lists both tools; off, neither is listed, and a call to either is answered as one to no tool",
       %{agent: agent, auction: auction, wallet: wallet} do
    install(@permitted)
    mine = position!(auction, wallet)
    listed = listed(agent)
    assert Enum.all?(@tools, &(&1 in Enum.map(listed, fn tool -> tool["name"] end)))

    for %{"name" => name, "annotations" => annotations} <- listed, name in @tools do
      assert annotations["readOnlyHint"] == true, name
    end

    Application.put_env(:autolaunch, :agent_bids, :off)
    refute Enum.any?(@tools, &(&1 in tool_names(agent)))

    # Off, a call to either, well formed or not, is answered exactly as one to
    # a tool that does not exist, in no words of agent bids.
    for name <- @tools,
        arguments <- [
          %{"input" => %{auction_id: auction.id, amount: "1", max_price: "3"}},
          %{"input" => %{bid: mine.bid_id}},
          %{"input" => "not an object"},
          %{"input" => %{bogus: "x"}},
          %{"input" => %{auction_id: 1, amount: 1, max_price: [3], signer: false}},
          %{"input" => %{}},
          %{},
          "not an object"
        ] do
      called = mcp(agent, rpc("tools/call", %{"name" => name, "arguments" => arguments}))

      nothing =
        mcp(agent, rpc("tools/call", %{"name" => "no_such_tool", "arguments" => arguments}))

      said = called.resp_body |> IO.iodata_to_binary() |> String.replace(name, "no_such_tool")

      assert {called.status, said} == {nothing.status, IO.iodata_to_binary(nothing.resp_body)},
             "#{name} #{inspect(arguments)}"

      refute said =~ ~r/bid|auction|signer|wallet|steps/i
    end
  end

  # Whether the contract documents `code` for `path` answering `status`.
  defp documented?(path, status, code) do
    response = get_in(@contract, ["paths", path, "post", "responses", Integer.to_string(status)])
    code in @codes and is_map(response) and response["description"] =~ ~r/\b#{code}\b/
  end

  # Whether the page's own parsers refuse a body's figures, as its review does
  # before it reads the treasury or the chain. A USDC bid on an auction that
  # takes none is refused for that, after its slippage and before its amount.
  defp refused_figures?(body) do
    figures = Map.delete(body, :auction_id)

    with true <- Enum.all?(figures, fn {_name, value} -> is_binary(value) end),
         {:ok, _price} <- BidActions.price_q96(body.max_price, 18),
         {:ok, _paid} <- paid(body) do
      false
    else
      _refused -> true
    end
  end

  defp paid(%{pay_with: "USDC"} = body),
    do: Autolaunch.BidSlippage.parse(Map.get(body, :slippage_percent, "5"))

  defp paid(body), do: BidActions.atomic_amount(body.amount, 18)

  # The chain a refusal case reads: the bid double with parts replaced, the
  # treasury double's, a USDC read's, or the settlement double's.
  defp chain({:treasury, overrides}) do
    install(@permitted)
    TestAutolaunchTreasuryChainClient.install(overrides)
  end

  defp chain({:stock, signature, words}) do
    install(@permitted)
    Process.delete(StockRpc)
    StockRpc.put(%{LabAbi.selector(signature) => words})
  end

  defp chain({:settle, overrides}) do
    settle(
      Keyword.merge(
        [
          graduated?: true,
          exit: {:refused, :already_exited},
          claim: %{data: claim_data(), tokens_claimed: 1}
        ],
        overrides
      )
    )
  end

  defp chain(overrides) do
    TestAutolaunchTreasuryChainClient.install()
    install(@permitted ++ overrides)
  end

  defp stock_rpc, do: Application.put_env(:autolaunch, :autolaunch_lab_http_client, StockRpc)

  defp tool(@bid_path), do: "prepare_bid"
  defp tool(@settle_path), do: "prepare_bid_settlement"

  # A route's body as its tool's input: a settlement's also names its bid.
  defp tool_input(@bid_path, input), do: input

  defp tool_input("/api/agent/v1/bids/" <> rest, input),
    do: Map.put(input, :bid, rest |> String.replace_suffix("/steps", "") |> URI.decode())

  defp settle_path(bid),
    do: "/api/agent/v1/bids/#{URI.encode(bid, &URI.char_unreserved?/1)}/steps"

  # A Base auction raising the bound REGENT at an address of its own, with
  # `report` bound as its treasury's, or none.
  defp base_auction!(fields, report) do
    address = random_wallet()

    auction =
      %{
        chain_id: 8453,
        kind: :agent,
        origin: :site,
        auction_address: address,
        title: "Agent bid auction",
        creator_human_account_id: TestSupport.register_creator!().id,
        creator_address: "0x1414141414141414141414141414141414141414",
        featured: false,
        current_clearing_price: "0",
        required_currency_raised: "1000",
        contracts_version: :v2
      }
      |> Map.merge(fields)
      |> Autolaunch.record_launch_auction!(actor: system())
      |> Autolaunch.set_auction_bid_terms!(address, regent(), "REGENT", 18, "2.5",
        actor: system()
      )

    if report,
      do: Autolaunch.set_auction_treasury_security_report!(auction, report.id, actor: system()),
      else: auction
  end

  # A Memestock auction on Base sent to the launchpad its deployment admits.
  defp memestock_auction! do
    address = "0x5555555555555555555555555555555555555555"

    %{
      contracts_version: :v2,
      kind: :stocks,
      origin: :site,
      chain_id: 8453,
      auction_address: address,
      title: "Memestock auction",
      creator_human_account_id: TestSupport.register_creator!().id,
      creator_address: "0x1414141414141414141414141414141414141414",
      featured: false,
      state: :active,
      current_clearing_price: "0",
      required_currency_raised: "1000",
      treasury_address: @launchpad
    }
    |> Autolaunch.record_launch_auction!(actor: system())
    |> Autolaunch.set_auction_bid_terms!(address, regent(), "STOCK", 18, "2.5", actor: system())
  end

  # A saved bid of `owner`'s on the fixture auction, with its on-chain id or none.
  defp position!(auction, owner, onchain \\ Integer.to_string(@onchain_bid)) do
    Autolaunch.Bid
    |> Ash.Changeset.for_create(
      :project_lab,
      %{
        bid_id: "lab:agent:#{System.unique_integer([:positive])}",
        auction_id: auction.id,
        owner_address: owner,
        amount: "12",
        max_price: "0.00003",
        current_clearing_price: "0.00002",
        status: :returnable,
        auction_address: auction_address(),
        onchain_bid_id: onchain
      },
      actor: system()
    )
    |> Ash.create!()
  end

  # The settlement double, reading the bidder's bid on the fixture auction.
  defp settle(overrides) do
    TestAutolaunchBidSettlementChainClient.install(
      Map.merge(
        %{
          end_block: 90,
          claim_block: 95,
          currency: regent(),
          final_clearing_price_q96: 2 * 79_228_162_514_264_337_593_543_950_336,
          bid: %{
            start_block: 10,
            exited_block: 0,
            max_price_q96: 3 * 79_228_162_514_264_337_593_543_950_336,
            owner: wallet(),
            amount: 12 * 10 ** 18,
            tokens_filled: 0
          }
        },
        Map.new(overrides)
      )
    )
  end

  defp exit_bid(refund, filled),
    do: %{
      signature: "exitBid(uint256)",
      data: LabAbi.selector("exitBid(uint256)") <> word(@onchain_bid),
      hints: nil,
      tokens_filled: filled,
      currency_refunded: refund
    }

  defp claim_data, do: LabAbi.selector("claimTokens(uint256)") <> word(@onchain_bid)

  defp word(value), do: value |> Integer.to_string(16) |> String.pad_leading(64, "0")

  # A paired agent's signing wallet, paired with `account`'s person.
  defp paired_agent(account) do
    agent = random_wallet()

    code =
      RegentAgents.issue_pairing_code!(
        actor: %RegentAgents.Person{privy_user_id: account.privy_user_id}
      )

    RegentAgents.pair_agent!(code.code, "Agent", :codex,
      actor: %RegentAgents.Agent{wallet: agent}
    )

    agent
  end

  defp keep_env(key) do
    old = Application.fetch_env(:autolaunch, key)

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:autolaunch, key, value)
        :error -> Application.delete_env(:autolaunch, key)
      end
    end)
  end

  # The tool's result, or its error's text decoded: the route's error document.
  defp tool(agent, name, input) do
    case json(mcp(agent, call(name, input)))["result"] do
      %{"isError" => false, "structuredContent" => answer} -> {:ok, answer}
      %{"isError" => true, "content" => [%{"text" => text}]} -> {:error, Jason.decode!(text)}
    end
  end

  defp listed(agent), do: json(mcp(agent, rpc("tools/list")))["result"]["tools"]

  defp tool_names(agent), do: Enum.map(listed(agent), & &1["name"])

  defp mcp(agent, body) do
    conn(:post, "/mcp", Jason.encode!(body))
    |> Map.put(:remote_ip, from())
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-siwa-signature", "fixture-proof")
    |> put_req_header("x-agent-wallet-address", agent)
    |> @endpoint.call([])
  end

  # One signed request from an address of its own.
  defp http(method, path, body, agent) do
    conn =
      conn(method, path, Jason.encode!(body))
      |> Map.put(:remote_ip, from())
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-siwa-signature", "fixture-proof")
      |> put_req_header("x-agent-wallet-address", agent)
      |> @endpoint.call([])

    %{status: conn.status, body: json(conn)}
  end

  # A route's answer as a hosted tool gives it: its `data`, or its refusal.
  defp answer(%{status: 200, body: %{"data" => data}}), do: {:ok, data}

  defp answer(%{status: status, body: %{"error" => _} = body}) when status != 200,
    do: {:error, body}

  defp call(name, input),
    do: rpc("tools/call", %{"name" => name, "arguments" => %{"input" => input}})

  defp rpc(method, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

  defp plain(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp json(conn), do: conn.resp_body |> IO.iodata_to_binary() |> Jason.decode!()

  defp from, do: {10, 8, :rand.uniform(250), :rand.uniform(250)}

  defp random_wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end
