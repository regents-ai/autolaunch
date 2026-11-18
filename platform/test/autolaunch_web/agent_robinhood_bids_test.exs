defmodule AutolaunchWeb.AgentRobinhoodBidsTest do
  @moduledoc """
  Agent bids on Robinhood Chain on a paired agent's two ways in: the signed
  routes the browser tools call and the hosted MCP tools give one answer for
  one input, refusals in the same code and words.

  A bid's steps are the auction page's for the same inputs and wallet, and a
  return and claim's are the bid's row's. Only the person's own wallets and
  bids are prepared for, and only for the agent paired with them, while the
  person has a verified wallet; another person's bid and a bid that does not
  exist are answered alike, as is a bid number past what the auction can hold,
  before anything is read; a bid's id as the positions give it is taken as it
  is. Every refusal is reached and named, with a status and code the contract
  documents, and every reason the reviews give has one code. A slippage,
  amount or price text the page refuses is refused before Robinhood Chain is
  read. A bid on an auction whose bidding has not started or has ended, or on a
  hidden one, is refused; a bid on a hidden auction still settles. A read that
  fails, a raise, or a reason nobody named, is refused as `bid_unavailable`. Both
  routes spend the person's one budget. Off, or in prelaunch read-only mode,
  neither tool is listed or run, and off a call to either is answered as one to
  a tool that does not exist.

  Robinhood Chain is `Autolaunch.RobinhoodBidChain`, and the sign-in service
  is stubbed: it vouches for the wallet a request names.
  """
  use AutolaunchWeb.ConnCase, async: false
  use ExUnitProperties

  import Autolaunch.BidFixture, only: [bidder: 1, system: 0]
  import Autolaunch.DatabaseFaults, only: [lose_reads_of: 1, restore_reads_of: 1]
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Plug.Test, only: [conn: 3]

  alias Autolaunch.Accounts.RequestRateLimiter
  alias Autolaunch.Actors.{Agent, ConnectedApp, Human}
  alias Autolaunch.AgentRobinhoodBid.Refused
  alias Autolaunch.Robinhood.{Lab, StockBidActions, StockBidSettlementActions}
  alias Autolaunch.Stocks.Amounts
  alias AutolaunchWeb.AgentRobinhoodBidAnswer
  alias RegentChain.Address

  alias Autolaunch.{
    Accounts,
    AgentRobinhoodBid,
    BaseRpcStub,
    LabAbi,
    RobinhoodBidChain,
    TestSupport
  }

  @moduletag :capture_log
  @contract "../../contracts/agent-robinhood-bids.openapiv3.yaml"
            |> Path.expand(__DIR__)
            |> YamlElixir.read_from_file!()
  @codes get_in(
           @contract,
           ~w(components schemas AgentRobinhoodBidError properties error properties code enum)
         )
  @schemas @contract["components"]["schemas"]
  @tools ~w(prepare_robinhood_bid prepare_robinhood_bid_settlement)
  @bid_path "/api/agent/v1/robinhood/bids/steps"
  @settle_path "/api/agent/v1/robinhood/bids/{bid}/steps"
  @other "0x2222222222222222222222222222222222222222"
  # A stock no stock list here holds.
  @unlisted "0x5555555555555555555555555555555555555555"
  @q96 79_228_162_514_264_337_593_543_950_336

  setup :bidder

  setup %{account: account} do
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

    for key <- [:agent_robinhood_bids, :prelaunch_read_only], do: keep_env(key)
    Application.put_env(:autolaunch, :agent_robinhood_bids, :on)
    # Past the prelaunch gate, which refuses wallet steps until the site opens.
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    RobinhoodBidChain.install()

    %{
      agent: paired_agent(account),
      listed: robinhood_auction!(%{state: :active}, RobinhoodBidChain.auction()),
      mine: RobinhoodBidChain.auction() <> ":7"
    }
  end

  test "a bid's steps are the auction page's for the same inputs and wallet, alike on both ways in",
       %{agent: agent, listed: listed, wallet: wallet, opts: opts} do
    bid = %{auction_id: listed.id, usdg_amount: "12.5", max_price: "3"}
    {:ok, deployment} = Lab.current()
    usdg = Lab.address!(deployment, :usdg)
    adapter = Lab.address!(deployment, :bid_adapter)

    for {chain, input, named} <- [
          {[], bid, ~w(usdg_approval usdg_bid)},
          {[],
           %{bid | max_price: "3.3"} |> Map.merge(%{slippage_percent: "12.5", signer: wallet}),
           ~w(usdg_approval usdg_bid)},
          {[usdg_allowance: 10 ** 8], bid, ~w(usdg_bid)},
          # An allowance of exactly the amount, and one unit short of it.
          {[usdg_allowance: 12_500_000], bid, ~w(usdg_bid)},
          {[usdg_allowance: 12_499_999], bid, ~w(usdg_approval usdg_bid)}
        ] do
      RobinhoodBidChain.put(chain)
      {:ok, page} = StockBidActions.prepare(page_request(input), wallet, opts)
      {:ok, data} = answer(http(:post, @bid_path, input, agent))

      assert tool(agent, "prepare_robinhood_bid", input) == {:ok, data}
      assert Enum.map(data["steps"], & &1["step"]) == named
      assert data["steps"] == plain(page.steps)
      assert data["facts"] == plain(page.facts)
      assert data["chain"] == plain(page.chain)
      assert %{"chain_id" => 4_663, "name" => "Robinhood Chain"} = data["chain"]

      assert %{"kind" => "bid", "signer" => ^wallet, "block" => 100} = data

      assert Enum.sort(Map.keys(data)) ==
               Enum.sort(@schemas["AgentRobinhoodBidSteps"]["required"])

      assert data["auction"] == %{"id" => listed.id, "address" => RobinhoodBidChain.auction()}
      # False while the steps still hold an approval, true once only the bid is left.
      assert data["approved"] == (named == ["usdg_bid"])

      # The approval is to the deployment's USDG for its bid adapter, and the bid
      # to that adapter: addresses the deployment description names.
      for step <- data["steps"] do
        assert step["to"] == %{"usdg_approval" => usdg, "usdg_bid" => adapter}[step["step"]]
      end

      for %{"step" => "usdg_approval", "data" => approval} <- data["steps"] do
        assert String.starts_with?(
                 approval,
                 LabAbi.selector("approve(address,uint256)") <> BaseRpcStub.address_word(adapter)
               )
      end
    end
  end

  test "a bid on an auction whose bidding has ended is refused, by the auction's record before Robinhood Chain is read or by its clock, while the page still reviews it",
       %{agent: agent, listed: listed, wallet: wallet} do
    for state <- [:ended, :graduated, :failed] do
      auction = robinhood_auction!(%{state: state}, random_wallet())
      input = %{auction_id: auction.id, usdg_amount: "1", max_price: "3"}
      flush_reads()
      route = http(:post, @bid_path, input, agent)

      assert route.status == 409 and route.body["error"]["code"] == "bidding_ended", "#{state}"
      refute_received {:robinhood_read, _method}
      assert tool(agent, "prepare_robinhood_bid", input) == {:error, route.body}
    end

    input = %{auction_id: listed.id, usdg_amount: "1", max_price: "3"}

    # The auction's clock at the latest block, at its end block and past it.
    for clock <- [90, 91] do
      RobinhoodBidChain.put(clock: clock)
      route = http(:post, @bid_path, input, agent)

      assert route.status == 409 and route.body["error"]["code"] == "bidding_ended",
             "clock #{clock} answered #{inspect(route.body)}"

      refute Map.has_key?(route.body, "data")
      assert tool(agent, "prepare_robinhood_bid", input) == {:error, route.body}
      assert documented?(@bid_path, 409, "bidding_ended")

      # The auction page still shows its review, with why it no longer bids.
      assert {:ok, %{blocked: :bidding_ended, steps: [_ | _]}} =
               StockBidActions.review(page_request(input), wallet)
    end

    RobinhoodBidChain.put(clock: 89)
    assert {:ok, %{"steps" => [_ | _]}} = answer(http(:post, @bid_path, input, agent))
  end

  test "a bid while even the auction clock's next step is before its start block is refused as auction_not_started with no steps, while the page still reviews it",
       %{agent: agent, listed: listed, wallet: wallet} do
    input = %{auction_id: listed.id, usdg_amount: "1", max_price: "3"}

    # The auction starts at block 10 of its own clock, which never runs back:
    # a bid sent at 8 lands at 8 or 9 at the earliest, which it refuses.
    for clock <- [1, 8] do
      RobinhoodBidChain.put(clock: clock)
      route = http(:post, @bid_path, input, agent)

      assert route.status == 409 and route.body["error"]["code"] == "auction_not_started",
             "clock #{clock} answered #{inspect(route.body)}"

      refute Map.has_key?(route.body, "data")
      assert tool(agent, "prepare_robinhood_bid", input) == {:error, route.body}
      assert documented?(@bid_path, 409, "auction_not_started")

      assert {:ok, %{blocked: :auction_not_started, steps: [_ | _]}} =
               StockBidActions.review(page_request(input), wallet)
    end

    # One step before the start the bid may land at the start, which takes it,
    # so it is not refused; from the start block the auction takes the bid.
    for clock <- [9, 10] do
      RobinhoodBidChain.put(clock: clock)
      assert {:ok, %{"steps" => [_ | _]}} = answer(http(:post, @bid_path, input, agent))
      assert {:ok, %{blocked: nil}} = StockBidActions.review(page_request(input), wallet)
    end
  end

  test "a bid's return and claim are the bid's row's steps, alike on both ways in", context do
    %{agent: agent, listed: listed, mine: mine, wallet: wallet, opts: opts} = context

    for {chain, named} <- [
          {[exit: {:exited, 0, 12 * 10 ** 18}, claim: {:reverted, "NotGraduated()"}], ~w(exit)},
          {[
             graduated: true,
             exit: {:exited, 1_200_000 * 10 ** 18, 0},
             claim: {:claimed, 1_200_000 * 10 ** 18}
           ], ~w(exit claim)},
          {[
             graduated: true,
             exit: {:reverted, "BidAlreadyExited()"},
             claim: {:claimed, 10 ** 18}
           ], ~w(claim)},
          # Bidding open, the price past the bid's maximum and not recorded yet.
          {[
             graduated: true,
             final_price: 4 * @q96,
             exit: {:reverted, "AuctionIsNotOver()"},
             claim: {:reverted, "NotClaimable()"}
           ], ~w(record)}
        ] do
      RobinhoodBidChain.put(chain)

      {:ok, page} =
        StockBidSettlementActions.prepare(
          %{auction: RobinhoodBidChain.auction(), bid_id: "7"},
          wallet,
          opts
        )

      {:ok, data} = answer(http(:post, settle_path(mine), %{}, agent))

      assert tool(agent, "prepare_robinhood_bid_settlement", %{bid: mine}) == {:ok, data}
      assert Enum.map(data["steps"], & &1["step"]) == named
      assert data["steps"] == plain(page.steps)
      assert data["facts"] == plain(page.facts)
      assert data["chain"] == plain(page.chain)

      assert %{"kind" => "settle", "signer" => ^wallet, "block" => 100, "bid" => ^mine} = data

      assert Enum.sort(Map.keys(data)) ==
               Enum.sort(@schemas["AgentRobinhoodBidSettlement"]["required"])

      assert data["auction"] == %{"id" => listed.id, "address" => RobinhoodBidChain.auction()}
    end
  end

  test "only the person's own wallets are prepared for, and another person's bid is answered as one that does not exist",
       context do
    %{account: account, agent: agent, listed: listed, mine: mine, wallet: wallet} = context
    bid = %{auction_id: listed.id, usdg_amount: "1", max_price: "3"}

    for {path, tool, input} <- [
          {@bid_path, "prepare_robinhood_bid", Map.put(bid, :signer, @other)},
          {settle_path(mine), "prepare_robinhood_bid_settlement", %{signer: @other}}
        ] do
      route = http(:post, path, input, agent)
      assert route.status == 403 and route.body["error"]["code"] == "wrong_signer", path
      assert tool(agent, tool, tool_input(path, input)) == {:error, route.body}, path
    end

    # Another person's bid, a number the auction holds no bid at, and a bid on
    # an auction the site does not list.
    theirs = Map.put(RobinhoodBidChain.bid(), :owner, @other)

    answers =
      for {chain, id} <- [
            {[bid: theirs], mine},
            {[], RobinhoodBidChain.auction() <> ":9"},
            {[], random_wallet() <> ":7"}
          ] do
        RobinhoodBidChain.put(chain)
        route = http(:post, settle_path(id), %{}, agent)
        assert route.status == 404 and route.body["error"]["code"] == "not_your_bid", id
        assert tool(agent, "prepare_robinhood_bid_settlement", %{bid: id}) == {:error, route.body}
        route.body
      end

    assert [_one] = Enum.uniq(answers)

    # An auction the site lists on another chain, at that chain's address,
    # holds no Robinhood bid, known before Robinhood Chain is read.
    flush_reads()
    other_chain = http(:post, settle_path(context.auction.auction_address <> ":7"), %{}, agent)
    assert other_chain.status == 404 and other_chain.body == hd(answers)
    refute_received {:robinhood_read, _method}

    # A bid another of the person's own wallets placed is theirs to settle.
    second = "0x3333333333333333333333333333333333333334"

    {:ok, _account} =
      Accounts.refresh_verified(account, wallet, [wallet, second], actor: system())

    RobinhoodBidChain.put(bid: Map.put(RobinhoodBidChain.bid(), :owner, second))
    assert {:ok, %{"signer" => ^wallet}} = answer(http(:post, settle_path(mine), %{}, agent))

    # Another person's agent, asking for the bid with its owner's wallet, then
    # with its own person's.
    RobinhoodBidChain.put([])
    stranger = paired_agent(TestSupport.register_creator!())
    route = http(:post, settle_path(mine), %{signer: wallet}, stranger)
    assert route.status == 403 and route.body["error"]["code"] == "wrong_signer"
    assert http(:post, settle_path(mine), %{}, stranger).body == hd(answers)
  end

  test "a bid another of the person's wallets placed, kept in its checksummed letter case, is theirs to settle, alike on the bid's row and on both ways in",
       %{account: account, agent: agent, mine: mine, wallet: wallet, opts: opts} do
    {:ok, bytes} = Address.decode("0xabcdef0123456789abcdef0123456789abcdef01")
    second = Address.checksum(bytes)
    assert second != String.downcase(second)

    {:ok, _account} =
      Accounts.refresh_verified(account, wallet, [wallet, second], actor: system())

    # The auction records its owner as a number, which reads back lowercase.
    RobinhoodBidChain.put(bid: Map.put(RobinhoodBidChain.bid(), :owner, String.downcase(second)))

    {:ok, page} =
      StockBidSettlementActions.prepare(
        %{auction: RobinhoodBidChain.auction(), bid_id: "7"},
        wallet,
        opts
      )

    assert page.context.owner == String.downcase(second)
    {:ok, data} = answer(http(:post, settle_path(mine), %{}, agent))
    assert tool(agent, "prepare_robinhood_bid_settlement", %{bid: mine}) == {:ok, data}
    assert Enum.map(data["steps"], & &1["step"]) == ["exit"]
    assert data["steps"] == plain(page.steps)
    assert data["signer"] == wallet
  end

  test "another's bid is answered not_your_bid before the auction is asked to settle it, even where that would fail",
       %{agent: agent, mine: mine} do
    theirs = Map.put(RobinhoodBidChain.bid(), :owner, @other)
    RobinhoodBidChain.put(bid: theirs, unreadable: "eth_simulateV1")
    flush_reads()
    route = http(:post, settle_path(mine), %{}, agent)

    assert route.status == 404 and route.body["error"]["code"] == "not_your_bid"
    refute_received {:robinhood_read, "eth_simulateV1"}
    assert tool(agent, "prepare_robinhood_bid_settlement", %{bid: mine}) == {:error, route.body}

    # The person's own bid reaches that settlement, which fails.
    RobinhoodBidChain.put(unreadable: "eth_simulateV1")
    flush_reads()
    route = http(:post, settle_path(mine), %{}, agent)
    assert route.status == 503 and route.body["error"]["code"] == "chain_unavailable"
    assert_received {:robinhood_read, "eth_simulateV1"}
  end

  test "a hidden auction takes no bid, known before Robinhood Chain is read, while a bid on it stays the person's to settle",
       %{agent: agent, listed: listed, mine: mine} do
    {:ok, _hidden} = Autolaunch.hide_auction(listed, actor: system())

    input = %{auction_id: listed.id, usdg_amount: "1", max_price: "3"}
    flush_reads()
    route = http(:post, @bid_path, input, agent)

    assert route.status == 404 and route.body["error"]["code"] == "auction_not_found"
    refute_received {:robinhood_read, _method}
    assert tool(agent, "prepare_robinhood_bid", input) == {:error, route.body}

    {:ok, data} = answer(http(:post, settle_path(mine), %{}, agent))
    assert tool(agent, "prepare_robinhood_bid_settlement", %{bid: mine}) == {:ok, data}
    assert Enum.map(data["steps"], & &1["step"]) == ["exit"]
    assert data["auction"] == %{"id" => listed.id, "address" => RobinhoodBidChain.auction()}
  end

  test "a bid's id as autolaunch_my_positions and the positions route give it, in lowercase, is taken as it is by the settlement route and tool",
       %{agent: agent, mine: mine} do
    # Robinhood Chain is the only chain read here.
    keep_env(:autolaunch_base_deployment)
    Application.delete_env(:autolaunch, :autolaunch_base_deployment)

    route = http(:get, "/api/agent/v1/positions", nil, agent)
    assert route.status == 200, inspect(route.body)
    assert tool(agent, "autolaunch_my_positions", %{}) == answer(route)
    assert [%{"chain" => "robinhood", "bid" => bid}] = route.body["data"]["bids"]

    # The auction's address has letters, which the id gives in lowercase.
    assert bid == mine and bid == String.downcase(bid) and bid =~ ~r/[a-f]/

    {:ok, data} = answer(http(:post, settle_path(bid), %{}, agent))
    assert tool(agent, "prepare_robinhood_bid_settlement", %{bid: bid}) == {:ok, data}
    assert data["bid"] == bid
    assert Enum.map(data["steps"], & &1["step"]) == ["exit"]
  end

  test "a bid number is any the auction can issue: the last it can settles, one it has not issued names no bid, and one past any uint256 names no bid before anything is read",
       %{agent: agent, wallet: wallet, opts: opts} do
    # The auction's next id is a uint256 too, so the last id it can ever issue
    # is one below the largest uint256.
    last = Integer.pow(2, 256) - 2
    RobinhoodBidChain.put(bid_id: last)
    bid = RobinhoodBidChain.auction() <> ":#{last}"

    {:ok, page} =
      StockBidSettlementActions.prepare(
        %{auction: RobinhoodBidChain.auction(), bid_id: Integer.to_string(last)},
        wallet,
        opts
      )

    {:ok, data} = answer(http(:post, settle_path(bid), %{}, agent))
    assert tool(agent, "prepare_robinhood_bid_settlement", %{bid: bid}) == {:ok, data}
    assert Enum.map(data["steps"], & &1["step"]) == ["exit"]
    assert data["steps"] == plain(page.steps)

    # With bid 7 the last issued: past any uint256, at both ends of the length
    # an id may have, before anything is read; and the largest uint256, a
    # 77-digit number and the next id, none of which the auction has issued,
    # once it says which it has, never asking it for their records (it
    # reverts `BidIdDoesNotExist`).
    RobinhoodBidChain.put([])

    for {number, reads?} <- [
          {Integer.pow(2, 256), false},
          {Integer.pow(10, 78) - 1, false},
          {Integer.pow(2, 256) - 1, true},
          {Integer.pow(10, 76), true},
          {8, true}
        ] do
      none = RobinhoodBidChain.auction() <> ":#{number}"
      flush_reads()
      route = http(:post, settle_path(none), %{}, agent)

      assert route.status == 404 and route.body["error"]["code"] == "not_your_bid", none
      assert read?() == reads?, none
      assert tool(agent, "prepare_robinhood_bid_settlement", %{bid: none}) == {:error, route.body}

      # The bid's row refuses it alike, as no bid, read only for a number it can hold.
      flush_reads()

      assert {:error, %{reason: :bid_not_found}} =
               StockBidSettlementActions.review(
                 %{auction: RobinhoodBidChain.auction(), bid_id: Integer.to_string(number)},
                 wallet,
                 [wallet]
               )

      assert read?() == reads?, none
    end

    # Past any uint256 is known before the auction is looked up at all.
    lose_reads_of("auctions")

    route =
      http(
        :post,
        settle_path(RobinhoodBidChain.auction() <> ":#{Integer.pow(2, 256)}"),
        %{},
        agent
      )

    assert route.status == 404 and route.body["error"]["code"] == "not_your_bid"
  end

  test "a max_price that is no plain decimal above zero is refused before Robinhood Chain is read, alike on both ways in and on the auction page",
       %{agent: agent, listed: listed, wallet: wallet} do
    for {price, code} <- [
          {"abc", "invalid_decimal"},
          {"1e5", "invalid_decimal"},
          {"-1", "invalid_decimal"},
          {"", "invalid_decimal"},
          {" 3", "invalid_decimal"},
          {"3.", "invalid_decimal"},
          {String.duplicate("9", 513), "invalid_decimal"},
          {"0", "invalid_price"},
          {"0.000", "invalid_price"}
        ] do
      input = %{auction_id: listed.id, usdg_amount: "1", max_price: price}
      flush_reads()
      route = http(:post, @bid_path, input, agent)

      assert route.status == 422 and route.body["error"]["code"] == code,
             "#{inspect(price)} answered #{inspect(route.body)}"

      assert tool(agent, "prepare_robinhood_bid", input) == {:error, route.body}
      assert {:error, _refused} = StockBidActions.review(page_request(input), wallet)
      refute_received {:robinhood_read, _method}, inspect(price)
    end

    # A plain decimal above zero is placed on the auction's price grid, which
    # takes reading the auction: one too small for any price is refused then.
    tiny = %{
      auction_id: listed.id,
      usdg_amount: "1",
      max_price: "0." <> String.duplicate("0", 79) <> "1"
    }

    flush_reads()
    route = http(:post, @bid_path, tiny, agent)
    assert route.status == 422 and route.body["error"]["code"] == "invalid_price"
    assert_received {:robinhood_read, _method}
  end

  test "the steps are prepared for the paired agent alone, a connected app calling as it included",
       %{account: account, agent: wallet} do
    {:ok, agent} = Autolaunch.Agents.resolve(wallet)
    app_as_agent = %{agent | connection: %{subject: account.privy_user_id}}
    person = %Human{human_account_id: account.id}
    app = %ConnectedApp{principal: %{subject: account.privy_user_id}}

    for {action, input} <- [
          {:prepare, %{auction_id: Ash.UUID.generate(), usdg_amount: "1", max_price: "3"}},
          {:settle, %{bid: RobinhoodBidChain.auction() <> ":7"}}
        ],
        actor <- [agent, app_as_agent, person, app, %Autolaunch.Actors.System{}, nil] do
      may? =
        Ash.can?(Ash.ActionInput.for_action(AgentRobinhoodBid, action, input), actor)

      assert may? == actor in [agent, app_as_agent], "#{action} for #{inspect(actor)}"
    end
  end

  test "every refusal is reached, named alike on both ways in, in a status and code the contract documents",
       context do
    %{agent: agent, auction: base, listed: listed, mine: mine} = context
    tiny = "0." <> String.duplicate("0", 79) <> "1"
    bid = %{auction_id: listed.id, usdg_amount: "1", max_price: "3"}
    ended = robinhood_auction!(%{state: :ended}, random_wallet())
    settle = settle_path(mine)
    returned = {:reverted, "BidAlreadyExited()"}

    bids =
      [
        {[], Map.put(bid, :usdg_amount, 1), "invalid_request"},
        {[], Map.put(bid, :bogus, "x"), "invalid_request"},
        {[], Map.delete(bid, :max_price), "invalid_request"},
        {[], %{bid | auction_id: "nope"}, "invalid_request"},
        {[], %{bid | usdg_amount: "0"}, "invalid_amount"},
        {[], %{bid | usdg_amount: "0.0000001"}, "invalid_amount"},
        {[], %{bid | usdg_amount: "x"}, "invalid_decimal"},
        {[], %{bid | max_price: "x"}, "invalid_decimal"},
        {[], %{bid | max_price: tiny}, "invalid_price"},
        {[], Map.put(bid, :slippage_percent, "100"), "invalid_slippage"},
        {[], %{bid | max_price: "0.5"}, "price_below_admissible_tick"},
        {[], %{bid | auction_id: Ecto.UUID.generate()}, "auction_not_found"},
        # A listed auction on another chain.
        {[], %{bid | auction_id: base.id}, "auction_not_found"},
        {[], Map.put(bid, :signer, @other), "wrong_signer"},
        {[], Map.put(bid, :signer, "nope"), "wallet_required"},
        {[], %{bid | auction_id: ended.id}, "bidding_ended"},
        {[clock: 90], bid, "bidding_ended"},
        {[clock: 8], bid, "auction_not_started"},
        {[tick_next: 0], bid, "bid_preparation_unavailable"},
        {[], %{bid | usdg_amount: "1000"}, "amount_above_balance"},
        {[quote: 0], bid, "usdg_route_unavailable"},
        {[admission: [0, 18, 0]], bid, "usdg_route_unavailable"},
        {[stock: @unlisted], bid, "stock_not_listed"},
        {[unreadable: "eth_call"], bid, "chain_unavailable"},
        {[chain_id: "0x2105"], bid, "chain_unavailable"},
        # The site's own fault: the auction holds no contract, the bid adapter
        # is bound to another launchpad than the deployment names, or no
        # launchpad of the deployment made the listed auction.
        {[code: "0x"], bid, "bid_unavailable"},
        {[adapter_launchpad: @other], bid, "bid_unavailable"},
        {[launch_id: 0], bid, "bid_unavailable"}
      ]
      |> Enum.map(fn {chain, input, code} -> {chain, @bid_path, @bid_path, input, code} end)

    settlements =
      [
        {[], settle_path("bad id!"), %{}, "invalid_request"},
        {[], settle_path(RobinhoodBidChain.auction() <> ":07"), %{}, "invalid_request"},
        {[], settle, %{bogus: "x"}, "invalid_request"},
        {[], settle, %{signer: 1}, "invalid_request"},
        {[], settle_path(RobinhoodBidChain.auction() <> ":9"), %{}, "not_your_bid"},
        {[], settle, %{signer: "nope"}, "wallet_required"},
        {[], settle, %{signer: @other}, "wrong_signer"},
        {[exit: {:reverted, "AuctionNotStarted()"}], settle, %{}, "auction_not_started"},
        {[exit: {:reverted, "AuctionIsNotOver()"}], settle, %{}, "auction_not_ended"},
        {[exit: {:reverted, nil}], settle, %{}, "settlement_reverted"},
        {[exit: {:reverted, "InvalidLastFullyFilledCheckpointHint()"}], settle, %{},
         "bid_needs_partial_exit_hints_unavailable"},
        {[graduated: true, exit: {:reverted, "CannotExitBid()"}, checkpoints: :long], settle, %{},
         "price_history_long"},
        {[graduated: true, exit: returned, claim: returned], settle, %{}, "already_exited"},
        {[graduated: true, exit: returned, claim: {:reverted, "NotClaimable()"}], settle, %{},
         "claim_not_open"},
        {[graduated: true, exit: returned, claim: :nothing], settle, %{}, "nothing_to_claim"},
        {[graduated: true, exit: returned, claim: {:reverted, "BidNotExited()"}], settle, %{},
         "bid_not_exited"},
        # The auction refusing a claim as an exit it cannot take.
        {[graduated: true, exit: returned, claim: {:reverted, "CannotExitBid()"}], settle, %{},
         "settlement_reverted"},
        {[exit: returned, bid: Map.put(RobinhoodBidChain.bid(), :exited_block, 50)], settle, %{},
         "failed_bid_returned"},
        {[stock: @unlisted], settle, %{}, "stock_not_listed"},
        {[unreadable: "eth_simulateV1"], settle, %{}, "chain_unavailable"},
        # No launchpad of the deployment made the listed auction.
        {[launch_id: 0], settle, %{}, "bid_unavailable"}
      ]
      |> Enum.map(fn {chain, path, input, code} -> {chain, @settle_path, path, input, code} end)

    reached =
      for {chain, documented, path, input, code} <- bids ++ settlements do
        RobinhoodBidChain.put(chain)
        route = http(:post, path, input, agent)
        named = "#{path} #{inspect(input)} on #{inspect(chain)}"

        assert route.body["error"]["code"] == code, "#{named} answered #{inspect(route.body)}"
        assert route.body["error"]["message"] != ""

        assert tool(agent, tool(documented), tool_input(path, input)) == {:error, route.body},
               named

        assert documented?(documented, route.status, code), "#{code} at #{route.status}"
        code
      end

    # An agent nobody paired, on either route.
    RobinhoodBidChain.put([])

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
       %{listed: listed, mine: mine} do
    unread = %Agent{
      wallet_address: random_wallet(),
      privy_user_id: "did:privy:unread",
      pairing_id: Ecto.UUID.generate(),
      human_account_id: Ecto.UUID.generate()
    }

    assert {:error, %Ash.Error.Unknown{errors: [%Refused{reason: :authentication_required}]}} =
             Autolaunch.prepare_robinhood_bid(
               %{auction_id: listed.id, usdg_amount: "1", max_price: "3"},
               actor: unread
             )

    assert {:error, %Ash.Error.Unknown{errors: [%Refused{reason: :authentication_required}]}} =
             Autolaunch.prepare_robinhood_bid_settlement(%{bid: mine}, actor: unread)

    assert documented?(@bid_path, 401, "authentication_required")
    assert documented?(@settle_path, 401, "authentication_required")
  end

  test "a paired agent whose person's account cannot be read as the request arrives is refused account_unavailable on both routes",
       %{agent: agent, listed: listed, mine: mine} do
    # The person's account is read with its ENS name as the pairing is resolved.
    lose_reads_of("account_ens_identities")

    for {path, documented, input} <- [
          {@bid_path, @bid_path, %{auction_id: listed.id, usdg_amount: "1", max_price: "3"}},
          {settle_path(mine), @settle_path, %{}}
        ] do
      route = http(:post, path, input, agent)

      assert route.status == 503 and route.body["error"]["code"] == "account_unavailable",
             "#{path} answered #{inspect(route.body)}"

      assert documented?(documented, 503, "account_unavailable")
    end
  end

  test "both routes spend the person's one budget of 120 signed requests a minute",
       %{agent: agent, mine: mine} do
    # Requests that might straddle two minutes start in the next one.
    {:ok, %{reset: left}} = RequestRateLimiter.admit({"minute", make_ref()}, 1, 60)
    if left < 5, do: Process.sleep(left * 1000)

    for {path, remaining} <- [{@bid_path, 119}, {settle_path(mine), 118}] do
      answered = signed(:post, path, %{bogus: "x"}, agent)
      assert answered.status == 422
      assert [budget] = get_resp_header(answered, "ratelimit")
      assert budget =~ ~s("agent";r=#{remaining}), "#{path} answered #{budget}"
    end
  end

  test "a person whose wallet evidence has lapsed, or no longer holds together, is refused wallet_required on both actions, never not_your_bid for their own bid",
       %{account: account, agent: agent, listed: listed, mine: mine, wallet: wallet} do
    bid = %{auction_id: listed.id, usdg_amount: "1", max_price: "3"}

    # Lapsed: no primary wallet and none listed, as a sign-in that finds no
    # linked wallet leaves it. Not holding together: wallets listed but no
    # primary among them.
    for {primary, addresses} <- [{nil, []}, {nil, [wallet]}, {@other, [wallet]}] do
      {:ok, _account} = Accounts.refresh_verified(account, primary, addresses, actor: system())

      for {path, documented, input} <- [
            {@bid_path, @bid_path, bid},
            {@bid_path, @bid_path, Map.put(bid, :signer, wallet)},
            {settle_path(mine), @settle_path, %{}},
            {settle_path(mine), @settle_path, %{signer: wallet}}
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

  test "a read that fails, or a reason nobody named, is logged by kind alone and refused as bid_unavailable alike on both ways in",
       %{agent: agent, listed: listed, mine: mine, wallet: wallet} do
    bid = %{auction_id: listed.id, usdg_amount: "1", max_price: "3"}
    routes = [{@bid_path, @bid_path, bid}, {settle_path(mine), @settle_path, %{}}]

    refused = fn path, documented, input ->
      {route, log} = with_log(fn -> http(:post, path, input, agent) end)

      assert route.status == 503 and route.body["error"]["code"] == "bid_unavailable",
             "#{path} answered #{inspect(route.body)}"

      assert documented?(documented, 503, "bid_unavailable")
      assert tool(agent, tool(documented), tool_input(path, input)) == {:error, route.body}
      refute log =~ wallet
      log
    end

    # The auction the site lists holds no contract on Robinhood Chain.
    RobinhoodBidChain.put(code: "0x")

    for {path, documented, input} <- routes do
      assert refused.(path, documented, input) =~
               "agent robinhood bid failed: lab_contract_missing"
    end

    lose_reads_of("auctions")

    for {path, documented, input} <- routes do
      assert refused.(path, documented, input) =~ "agent robinhood bid connection_lost"
    end

    restore_reads_of("auctions")

    # The site's Robinhood deployment description cannot be read.
    Application.delete_env(:autolaunch, :autolaunch_robinhood_deployment)

    for {path, documented, input} <- routes do
      assert refused.(path, documented, input) =~
               "agent robinhood bid failed: robinhood_unavailable"
    end

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
        with_log(fn -> AgentRobinhoodBidAnswer.send(conn(:post, "/", ""), {:error, error}) end)

      assert answered.status == 503
      assert Jason.decode!(answered.resp_body)["error"]["code"] == "bid_unavailable"
      assert log =~ "agent robinhood bid failed"
    end
  end

  test "a raise in either operation is logged by kind alone and refused as bid_unavailable alike on both ways in",
       %{agent: agent, listed: listed, mine: mine, wallet: wallet} do
    # The site's deployment description as it is held, naming none of its
    # contracts: a fault nobody named, which raises where a review reads one.
    {:ok, config} = Lab.current()
    held = {Lab, config.path}
    on_exit(fn -> :persistent_term.erase(held) end)
    :persistent_term.put(held, %{config | addresses: %{}})

    for {path, documented, input} <- [
          {@bid_path, @bid_path, %{auction_id: listed.id, usdg_amount: "1", max_price: "3"}},
          {settle_path(mine), @settle_path, %{}}
        ] do
      {{route, tool}, log} =
        with_log(fn ->
          {http(:post, path, input, agent),
           tool(agent, tool(documented), tool_input(path, input))}
        end)

      assert route.status == 503 and route.body["error"]["code"] == "bid_unavailable",
             "#{path} answered #{inspect(route.body)}"

      assert tool == {:error, route.body}, "#{path} tool answered #{inspect(tool)}"
      assert log =~ "agent robinhood bid failed: KeyError"
      refute log =~ wallet
    end
  end

  test "each reason the reviews, the listing, the wallet and the account give has one code, which both ways in answer in a status the contract documents; anything else is bid_unavailable" do
    codes = %{
      authentication_required: :authentication_required,
      wallet_required: :wallet_required,
      wrong_signer: :wrong_signer,
      auction_not_listed: :auction_not_found,
      invalid_slippage: :invalid_slippage,
      invalid_decimal: :invalid_decimal,
      amount_required: :invalid_amount,
      amount_not_representable: :invalid_amount,
      max_price_required: :invalid_price,
      price_out_of_range: :invalid_price,
      price_below_admissible_tick: :price_below_admissible_tick,
      bidding_ended: :bidding_ended,
      bid_preparation_unavailable: :bid_preparation_unavailable,
      amount_above_balance: :amount_above_balance,
      usdg_route_unavailable: :usdg_route_unavailable,
      stock_route_unavailable: :usdg_route_unavailable,
      quote_out_of_range: :usdg_route_unavailable,
      stock_not_listed: :stock_not_listed,
      not_your_bid: :not_your_bid,
      bid_not_found: :not_your_bid,
      auction_not_started: :auction_not_started,
      auction_not_ended: :auction_not_ended,
      already_exited: :already_exited,
      claim_not_open: :claim_not_open,
      nothing_to_claim: :nothing_to_claim,
      bid_not_exited: :bid_not_exited,
      failed_bid_returned: :failed_bid_returned,
      settlement_reverted: :settlement_reverted,
      bid_needs_partial_exit: :settlement_reverted,
      bid_needs_partial_exit_hints_unavailable: :bid_needs_partial_exit_hints_unavailable,
      price_history_long: :price_history_long,
      chain_unavailable: :chain_unavailable,
      invalid_chain_response: :chain_unavailable,
      invalid_block_header: :chain_unavailable,
      wrong_chain: :chain_unavailable,
      invalid_decimals: :chain_unavailable,
      robinhood_unavailable: :bid_unavailable,
      lab_config_changed: :bid_unavailable,
      invalid_auction: :bid_unavailable,
      lab_contract_missing: :bid_unavailable,
      unknown_auction: :bid_unavailable,
      auction_not_found: :bid_unavailable
    }

    assert Map.new(codes, fn {reason, _code} -> {reason, AgentRobinhoodBid.code(reason)} end) ==
             codes

    for unexpected <- [:unnamed_reason, {:closed, :econnreset}, "text", nil, %{reason: :x}],
        do: assert(AgentRobinhoodBid.code(unexpected) == :bid_unavailable)

    for code <- Enum.uniq([:bid_unavailable | Map.values(codes)]) do
      answered = AgentRobinhoodBidAnswer.refuse(conn(:post, "/", ""), code)
      body = Jason.decode!(answered.resp_body)
      assert body == AgentRobinhoodBidAnswer.body(code) |> plain(), "#{code}"
      assert body["error"]["code"] == Atom.to_string(code)

      assert documented?(@bid_path, answered.status, body["error"]["code"]) or
               documented?(@settle_path, answered.status, body["error"]["code"]),
             "#{code} at #{answered.status}"
    end
  end

  property "any amount, price and slippage is answered or refused alike on both ways in, and a slippage, amount or price text the page refuses never reaches Robinhood Chain",
           %{agent: agent, listed: listed} do
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
          "0.0000001",
          String.duplicate("9", 101),
          "0." <> String.duplicate("0", 79) <> "1"
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
            usdg_amount <- figure,
            max_price <- figure,
            slippage <- one_of([constant(:none), figure]),
            max_runs: 50
          ) do
      body =
        %{auction_id: listed.id, usdg_amount: usdg_amount, max_price: max_price}
        |> then(&if(slippage == :none, do: &1, else: Map.put(&1, :slippage_percent, slippage)))

      flush_reads()
      route = http(:post, @bid_path, body, agent)
      read? = read?()

      assert tool(agent, "prepare_robinhood_bid", body) == answer(route)
      assert route.status == 200 or route.body["error"]["code"] in @codes

      assert route.status == 200 or
               documented?(@bid_path, route.status, route.body["error"]["code"])

      if refused_figures?(body) do
        assert route.status == 422, inspect(body)
        refute read?, inspect(body)
      else
        assert read?, inspect(body)
      end
    end
  end

  test "in prelaunch read-only mode neither tool is listed or run, and both routes wait",
       %{agent: agent, listed: listed, mine: mine} do
    Application.put_env(:autolaunch, :prelaunch_read_only, true)

    for {path, documented} <- [{@bid_path, @bid_path}, {settle_path(mine), @settle_path}] do
      route = http(:post, path, %{}, agent)
      assert route.status == 503 and route.body["error"]["code"] == "prelaunch_read_only"
      assert documented?(documented, 503, "prelaunch_read_only")
    end

    refute Enum.any?(@tools, &(&1 in tool_names(agent)))

    for {name, input} <- [
          {"prepare_robinhood_bid", %{auction_id: listed.id, usdg_amount: "1", max_price: "3"}},
          {"prepare_robinhood_bid_settlement", %{bid: mine}}
        ] do
      assert %{"error" => _} = json(mcp(agent, call(name, input)))
    end
  end

  test "switched on a paired agent lists both tools; off, neither is listed, and a call to either is answered as one to no tool",
       %{agent: agent, listed: listed, mine: mine} do
    listed_tools = listed(agent)
    assert Enum.all?(@tools, &(&1 in Enum.map(listed_tools, fn tool -> tool["name"] end)))

    for %{"name" => name, "annotations" => annotations} <- listed_tools, name in @tools do
      assert annotations["readOnlyHint"] == true, name
    end

    Application.put_env(:autolaunch, :agent_robinhood_bids, :off)
    refute Enum.any?(@tools, &(&1 in tool_names(agent)))

    # Off, a call to either, well formed or not, is answered exactly as one to
    # a tool that does not exist, in no words of agent Robinhood bids.
    for name <- @tools,
        arguments <- [
          %{"input" => %{auction_id: listed.id, usdg_amount: "1", max_price: "3"}},
          %{"input" => %{bid: mine}},
          %{"input" => "not an object"},
          %{"input" => %{bogus: "x"}},
          %{"input" => %{auction_id: 1, usdg_amount: 1, max_price: [3], signer: false}},
          %{"input" => %{bid: 7}},
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

      refute said =~ ~r/bid|auction|signer|wallet|steps|robinhood|usdg/i
    end
  end

  # Whether the contract documents `code` for `path` answering `status`.
  defp documented?(path, status, code) do
    response = get_in(@contract, ["paths", path, "post", "responses", Integer.to_string(status)])
    code in @codes and is_map(response) and response["description"] =~ ~r/\b#{code}\b/
  end

  # Whether the page's own parsers refuse a body's slippage, amount or price
  # text, as its review does before it reads Robinhood Chain.
  defp refused_figures?(body) do
    figures = Map.delete(body, :auction_id)

    with true <- Enum.all?(figures, fn {_name, value} -> is_binary(value) end),
         {:ok, _bps} <- Autolaunch.BidSlippage.parse(Map.get(body, :slippage_percent, "5")),
         {:ok, amount} when amount > 0 <- Amounts.parse_units(body.usdg_amount, 6),
         {:ok, price, _denominator} when price > 0 <- Amounts.decimal_ratio(body.max_price) do
      false
    else
      _refused -> true
    end
  end

  # The auction page's request for an agent's bid input.
  defp page_request(input) do
    input
    |> Map.take([:usdg_amount, :max_price, :slippage_percent])
    |> Map.put(:auction, RobinhoodBidChain.auction())
  end

  defp flush_reads do
    receive do
      {:robinhood_read, _method} -> flush_reads()
    after
      0 -> :ok
    end
  end

  # Whether Robinhood Chain was read since the reads were last flushed.
  defp read? do
    receive do
      {:robinhood_read, _method} -> true
    after
      0 -> false
    end
  end

  defp tool(@bid_path), do: "prepare_robinhood_bid"
  defp tool(@settle_path), do: "prepare_robinhood_bid_settlement"

  # A route's body as its tool's input: a settlement's also names its bid.
  defp tool_input(@bid_path, input), do: input

  defp tool_input("/api/agent/v1/robinhood/bids/" <> rest, input),
    do: Map.put(input, :bid, rest |> String.replace_suffix("/steps", "") |> URI.decode())

  defp settle_path(bid),
    do: "/api/agent/v1/robinhood/bids/#{URI.encode(bid, &URI.char_unreserved?/1)}/steps"

  # A Memestock auction on Robinhood Chain the site lists, at `address`.
  defp robinhood_auction!(fields, address) do
    [
      chain_id: RobinhoodBidChain.chain_id(),
      kind: :stocks,
      address: address,
      title: "Robinhood bid auction",
      symbol: "RDOG"
    ]
    |> Keyword.merge(Map.to_list(fields))
    |> TestSupport.project_auction()
  end

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

  defp http(method, path, body, agent) do
    conn = signed(method, path, body, agent)
    %{status: conn.status, body: json(conn)}
  end

  # One signed request from an address of its own.
  defp signed(method, path, body, agent) do
    conn(method, path, Jason.encode!(body))
    |> Map.put(:remote_ip, from())
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-siwa-signature", "fixture-proof")
    |> put_req_header("x-agent-wallet-address", agent)
    |> @endpoint.call([])
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
