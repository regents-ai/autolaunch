defmodule AutolaunchWeb.AgentStakeTest do
  @moduledoc """
  Agent staking on a paired agent's two ways in: the signed route the browser
  tool calls and the hosted MCP tool give one answer for one input, refusals
  in the same code and words.

  The steps are the token page's, built by the one function the page's Stake
  and Claim views call (`Autolaunch.Stocks.StakeActions.prepare/3`, through
  its `review/2`): on a Base Revstake token, a stake of the wallet's whole
  balance with its approval while the allowance is short, an unstake of the
  amount named, the whole stake included, and a claim that collects the
  locked position's fees first, each equal to what the page's review holds
  for the same wallet. A Base Memestock claim with fees waiting for the
  stakers and a Robinhood Chain stake are each read from their own chain and
  answered as the page is; a chain that cannot be read, or a node answering
  as another chain or with a block header it cannot vouch for, is
  `chain_unavailable`, as on the page. An unstake amount that is no amount is
  refused before any chain is read. Only the person's own
  wallets are prepared for, and only for the agent paired with them, while
  the person has a verified wallet; a token the site does not list or show is
  answered as no token, byte for byte as a missing one, before any chain is
  read. Every refusal is reached and named, with a status and code the
  contract documents, and every reason has one code; anything else is logged
  by kind alone and refused as `stake_unavailable`. Off, or in prelaunch
  read-only mode, the tool is not listed or run, and off a call to it is
  answered as one to a tool that does not exist.

  Base is `Autolaunch.StakeChain`, a Revstake launch and a Memestock one
  staking in one contract, and Robinhood Chain is
  `Autolaunch.RobinhoodBidChain`, its launch graduated; the two share the site's
  one chain client, so each case reads through the chain its token runs on.
  The sign-in service is stubbed: it vouches for the wallet a request names.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1, system: 0]
  import Autolaunch.DatabaseFaults, only: [lose_reads_of: 1, restore_reads_of: 1]
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Plug.Test, only: [conn: 3]

  alias Autolaunch.Actors.{Agent, ConnectedApp, Human}
  alias Autolaunch.AgentStake.Refused
  alias Autolaunch.Chain.Abi
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias Autolaunch.Stocks.StakeActions
  alias AutolaunchWeb.AgentStakeAnswer
  alias RegentChain.{Address, BuilderCode}

  alias Autolaunch.{
    Accounts,
    AgentStake,
    BaseRpcStub,
    Lab,
    LabAbi,
    Pool,
    RobinhoodBidChain,
    StakeChain,
    TestSupport
  }

  @moduletag :capture_log
  @contract "../../contracts/agent-stake.openapiv3.yaml"
            |> Path.expand(__DIR__)
            |> YamlElixir.read_from_file!()
  @codes get_in(
           @contract,
           ~w(components schemas AgentStakeError properties error properties code enum)
         )
  @schemas @contract["components"]["schemas"]
  @path "/api/agent/v1/tokens/{token_id}/stake/steps"
  @other "0x2222222222222222222222222222222222222222"
  @unit 10 ** 18
  # The wallet's position on the Revstake token: 5 held, 3 staked, and 1.5
  # USDC, 0.25 of the token and 2 REGENT to claim.
  @position %{
    balance: 5 * @unit,
    staked: 3 * @unit,
    claimable: %{dollar: 1_500_000, token: div(@unit, 4), currency: 2 * @unit}
  }

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

    for key <- [:agent_staking, :prelaunch_read_only], do: keep_env(key)
    Application.put_env(:autolaunch, :agent_staking, :on)
    # Past the prelaunch gate, which refuses wallet steps until the site opens.
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    StakeChain.install(@position)

    %{agent: paired_agent(account), listed: token!(kind: :agent)}
  end

  test "each kind's steps are the token page's for the same wallet and Base Revstake token, alike on both ways in",
       %{agent: agent, listed: listed, opts: opts, wallet: wallet} do
    {:ok, config} = Lab.contracts(Lab.current!(), :v2)
    locker = Address.normalize!(Lab.address!(config, :lp_locker))
    splitter = Address.normalize!(StakeChain.splitter())
    subject = Address.normalize!(StakeChain.subject())

    cases = [
      # The allowance is short of the whole balance, so the approval comes first.
      {%{allowance: 0}, %{kind: "stake"}, ["token_approval", "stake"]},
      {%{allowance: 5 * @unit}, %{kind: "stake"}, ["stake"]},
      {%{}, %{kind: "unstake", amount: "1.5"}, ["unstake"]},
      # The whole stake, to the last unit.
      {%{}, %{kind: "unstake", amount: "3"}, ["unstake"]},
      {%{}, %{kind: "claim"}, ["collect_full_range", "claim"]}
    ]

    for {chain, input, names} <- cases do
      StakeChain.put(Map.merge(@position, chain))
      named = "#{inspect(input)} on #{inspect(chain)}"
      {:ok, page} = StakeActions.prepare(page_request(listed, input), wallet, opts)
      {:ok, data} = answer(http(:post, path(listed.id), input, agent))

      assert tool(agent, "prepare_stake", Map.put(input, :token_id, listed.id)) == {:ok, data},
             named

      assert data["steps"] == plain(page.steps), named
      assert Enum.map(data["steps"], & &1["step"]) == names, named
      assert data["chain"] == plain(page.chain), named
      assert data["chain"]["chain_id"] == 8453
      assert %{"kind" => kind, "signer" => ^wallet, "block" => 32} = data
      assert kind == input.kind
      assert data["block"] == page.block
      assert data["token"] == %{"id" => listed.id, "address" => subject}

      assert data["facts"] == %{
               "balance" => %{"amount" => "5", "symbol" => "LRVS"},
               "staked" => %{"amount" => "3", "symbol" => "LRVS"},
               "claimable" => [
                 %{"amount" => "1.5", "symbol" => "USDC"},
                 %{"amount" => "0.25", "symbol" => "LRVS"},
                 %{"amount" => "2", "symbol" => "REGENT"}
               ]
             },
             named

      assert Enum.sort(Map.keys(data)) == Enum.sort(@schemas["AgentStakeSteps"]["required"])
    end

    # What each step sends: the exact allowance and the whole balance, the
    # amount named, and the locked position's collect before the claim.
    StakeChain.put(@position)

    assert {:ok, %{"steps" => [approval, stake]}} =
             answer(http(:post, path(listed.id), %{kind: "stake"}, agent))

    assert approval ==
             step("token_approval", subject, Abi.encode_erc20("approve", [splitter, 5 * @unit]))

    assert stake == step("stake", splitter, splitter_data("stake(uint256)", [5 * @unit]))

    assert {:ok, %{"steps" => [unstake]}} =
             answer(http(:post, path(listed.id), %{kind: "unstake", amount: "1.5"}, agent))

    assert unstake ==
             step("unstake", splitter, splitter_data("unstake(uint256)", [div(3 * @unit, 2)]))

    assert {:ok, %{"steps" => [whole]}} =
             answer(http(:post, path(listed.id), %{kind: "unstake", amount: "3"}, agent))

    assert whole == step("unstake", splitter, splitter_data("unstake(uint256)", [3 * @unit]))

    assert {:ok, %{"steps" => [collect, claim]}} =
             answer(http(:post, path(listed.id), %{kind: "claim"}, agent))

    assert collect ==
             step(
               "collect_full_range",
               locker,
               LabAbi.encode(Lab.abi!(config, :lp_locker), "collect(uint256)", [
                 StakeChain.lp_token_id()
               ])
             )

    assert claim == step("claim", splitter, splitter_data("claimAll()", []))
  end

  # The page offers a claim with nothing waiting too: it pays nothing.
  test "a claim with nothing waiting is still the page's steps, the claim paying nothing",
       %{agent: agent, listed: listed, opts: opts, wallet: wallet} do
    StakeChain.put(%{claimable: %{dollar: 0, token: 0, currency: 0}})
    {:ok, page} = StakeActions.prepare(page_request(listed, %{kind: "claim"}), wallet, opts)
    {:ok, data} = answer(http(:post, path(listed.id), %{kind: "claim"}, agent))

    assert data["steps"] == plain(page.steps)
    assert Enum.map(data["steps"], & &1["step"]) == ["collect_full_range", "claim"]
    assert Enum.map(data["facts"]["claimable"], & &1["amount"]) == ["0", "0", "0"]
  end

  test "a Base Memestock token and a Robinhood Chain token are each read from their own chain, answered as the page is",
       %{agent: agent, opts: opts, wallet: wallet} do
    {:ok, stocks} = StocksLab.contracts(StocksLab.current!(), :v2)
    memestock = memestock!()
    robinhood = robinhood!()

    cases = [
      {memestock, fn -> StakeChain.put(Map.put(@position, :unavailable, true)) end},
      {robinhood, fn -> RobinhoodBidChain.install(%{unreadable: "eth_call"}) end}
    ]

    for {token, arrange} <- cases, input <- [%{kind: "stake"}, %{kind: "claim"}] do
      arrange.()
      named = "#{token.auction.chain_id} #{inspect(input)}"
      chain_reads()

      assert {:error, %Ash.Error.Invalid.Unavailable{reason: :chain_unavailable}} =
               StakeActions.prepare(page_request(token, input), wallet, opts)

      paged = chain_reads()
      route = http(:post, path(token.id), input, agent)

      assert route.status == 503 and route.body["error"]["code"] == "chain_unavailable",
             "#{named} answered #{inspect(route.body)}"

      assert chain_reads() == paged, named

      assert tool(agent, "prepare_stake", Map.put(input, :token_id, token.id)) ==
               {:error, route.body},
             named

      # The Memestock token's launch is asked of its own launchpad on Base;
      # the Robinhood token's, of Robinhood Chain.
      if token == memestock do
        assert {"eth_call", Address.normalize!(stocks.launchpad)} in paged, named
      else
        assert {:robinhood, "eth_call"} in paged, named
        assert Enum.all?(paged, &match?({:robinhood, _method}, &1)), named
      end
    end
  end

  test "a Base Memestock claim with fees waiting for the stakers settles them, collects both locked positions, then claims, as the page's does",
       %{agent: agent, opts: opts, wallet: wallet} do
    config = StocksLab.current!()
    {:ok, stocks} = StocksLab.contracts(config, :v2)
    memestock = memestock!()
    splitter = Address.normalize!(StakeChain.splitter())
    # 1.5 USDC, 0.25 of the token and 2 AAPLc to claim, and 3 AAPLc waiting
    # in the hook's staker lane.
    StakeChain.put(
      Map.merge(@position, %{
        claimable: %{dollar: 1_500_000, token: div(@unit, 4), currency: 2 * 10 ** 8},
        lanes: [0, 0, 3 * 10 ** 8]
      })
    )

    {:ok, page} = StakeActions.prepare(page_request(memestock, %{kind: "claim"}), wallet, opts)
    {:ok, data} = answer(http(:post, path(memestock.id), %{kind: "claim"}, agent))

    assert tool(agent, "prepare_stake", %{token_id: memestock.id, kind: "claim"}) == {:ok, data}
    assert data["steps"] == plain(page.steps)
    assert data["chain"] == plain(page.chain)
    assert data["chain"]["chain_id"] == 8453

    collect = fn name, id ->
      step(name, stocks.locker, LabAbi.encode(stocks.abis["locker"], "collect(uint256)", [id]))
    end

    assert data["steps"] == [
             step(
               "settle",
               stocks.hook,
               LabAbi.encode(stocks.abis["hook"], "settleStakerLane(bytes32)", [
                 StakeChain.memestock_pool_id()
               ])
             ),
             collect.("collect_full_range", StakeChain.memestock_lp()),
             collect.("collect_new_only", StakeChain.memestock_new_only()),
             step(
               "claim",
               splitter,
               LabAbi.encode(StocksLab.abi!(config, :splitter), "claimAll()", [])
             )
           ]

    assert data["facts"]["claimable"] == [
             %{"amount" => "1.5", "symbol" => "USDC"},
             %{"amount" => "0.25", "symbol" => "LRVS"},
             %{"amount" => "2", "symbol" => "AAPLc"}
           ]

    assert data["token"] == %{"id" => memestock.id, "address" => StakeChain.subject()}
  end

  test "a Robinhood Chain stake approves the whole balance and stakes it, as the page's does",
       %{agent: agent, opts: opts, wallet: wallet} do
    robinhood = robinhood!()
    token = Address.normalize!(RobinhoodBidChain.token())
    splitter = Address.normalize!(RobinhoodBidChain.splitter())

    RobinhoodBidChain.install(%{
      lifecycle: 2,
      token_balance: 5 * @unit,
      token_allowance: 0,
      staked: 3 * @unit,
      claimable: %{dollar: 1_500_000, token: div(@unit, 4), currency: 2 * @unit}
    })

    {:ok, config} = RobinhoodLab.current()

    {:ok, page} = StakeActions.prepare(page_request(robinhood, %{kind: "stake"}), wallet, opts)
    {:ok, data} = answer(http(:post, path(robinhood.id), %{kind: "stake"}, agent))

    assert tool(agent, "prepare_stake", %{token_id: robinhood.id, kind: "stake"}) == {:ok, data}
    assert data["steps"] == plain(page.steps)
    assert data["chain"] == plain(page.chain)
    assert data["chain"]["chain_id"] == RobinhoodBidChain.chain_id()
    assert data["block"] == 100

    assert data["steps"] == [
             step("token_approval", token, Abi.encode_erc20("approve", [splitter, 5 * @unit])),
             step(
               "stake",
               splitter,
               LabAbi.encode(RobinhoodLab.abi!(config, :splitter), "stake(uint256)", [5 * @unit])
             )
           ]

    assert data["facts"] == %{
             "balance" => %{"amount" => "5", "symbol" => "RDOG"},
             "staked" => %{"amount" => "3", "symbol" => "RDOG"},
             "claimable" => [
               %{"amount" => "1.5", "symbol" => "USDG"},
               %{"amount" => "0.25", "symbol" => "RDOG"},
               %{"amount" => "2", "symbol" => "TSLA"}
             ]
           }

    assert data["token"] == %{"id" => robinhood.id, "address" => token}
  end

  test "a node answering as another chain, or with a block header it cannot vouch for, is chain_unavailable on both ways in, as on the page",
       %{agent: agent, listed: listed, opts: opts, wallet: wallet} do
    robinhood = robinhood!()
    header = %{"number" => "0x20", "hash" => "0xnope", "timestamp" => "0x6700"}

    # Robinhood Chain's double takes over the one chain client, so it comes last.
    cases = [
      {listed, fn -> BaseRpcStub.put(%{chain_id: "0x1"}) end, :wrong_chain},
      {listed, fn -> BaseRpcStub.put(%{chain_id: "0x2105", blocks: %{"latest" => header}}) end,
       :invalid_block_header},
      {robinhood, fn -> RobinhoodBidChain.install(%{lifecycle: 2, chain_id: "0x2105"}) end,
       :wrong_chain}
    ]

    for {token, arrange, fault} <- cases, input <- [%{kind: "stake"}, %{kind: "claim"}] do
      arrange.()
      named = "#{token.auction.chain_id} #{inspect(input)} #{fault}"

      # The pool's own read names the fault.
      read = if token == robinhood, do: &Autolaunch.Robinhood.Pool.read/1, else: &Pool.read/1
      assert read.(token.auction) == {:error, fault}, named

      assert {:error, %Ash.Error.Invalid.Unavailable{reason: :chain_unavailable}} =
               StakeActions.prepare(page_request(token, input), wallet, opts),
             named

      route = http(:post, path(token.id), input, agent)

      assert route.status == 503 and route.body["error"]["code"] == "chain_unavailable",
             "#{named} answered #{inspect(route.body)}"

      assert tool(agent, "prepare_stake", Map.put(input, :token_id, token.id)) ==
               {:error, route.body},
             named
    end
  end

  test "an unstake amount that is no amount is refused before any chain is read, on the page and on both ways in; only one above the stake asks the chain",
       %{agent: agent, listed: listed, opts: opts, wallet: wallet} do
    too_large = Integer.to_string(div(Integer.pow(2, 128), @unit) + 1)

    for {amount, reason} <- [
          {"abc", :invalid_decimal},
          {"", :invalid_decimal},
          {" 1", :invalid_decimal},
          {"0", :amount_required},
          {"0.0000000000000000001", :amount_not_representable},
          {too_large, :amount_too_large}
        ] do
      input = %{kind: "unstake", amount: amount}
      chain_reads()

      assert {:error, %Ash.Error.Invalid.Unavailable{reason: ^reason}} =
               StakeActions.prepare(page_request(listed, input), wallet, opts),
             inspect(amount)

      route = http(:post, path(listed.id), input, agent)
      assert route.body["error"]["code"] == "invalid_amount", inspect(amount)

      assert tool(agent, "prepare_stake", Map.put(input, :token_id, listed.id)) ==
               {:error, route.body}

      assert chain_reads() == [], inspect(amount)
    end

    input = %{kind: "unstake", amount: "3.000000000000000001"}
    chain_reads()

    assert {:error, %Ash.Error.Invalid.Unavailable{reason: :amount_above_stake}} =
             StakeActions.prepare(page_request(listed, input), wallet, opts)

    assert chain_reads() != []
  end

  test "a token the site does not list or show, and an id naming none, are answered alike as no token, before any chain is read",
       %{agent: agent} do
    hidden = token!(kind: :agent)
    {:ok, _hidden} = Autolaunch.hide_auction(hidden.auction, actor: system())

    robinhood =
      token!(
        chain_id: RobinhoodBidChain.chain_id(),
        kind: :stocks,
        address: unique_address(),
        quote_token_address: RobinhoodBidChain.stock(),
        quote_token_symbol: "TSLA",
        quote_token_decimals: 18
      )

    {:ok, _hidden} = Autolaunch.hide_auction(robinhood.auction, actor: system())
    # The site lists only its own launches, and the chain's Base Memestock ones.
    unlisted = unlisted!()

    answers =
      for id <- [Ecto.UUID.generate(), hidden.id, robinhood.id, unlisted.id],
          input <- [%{kind: "stake"}, %{kind: "unstake", amount: "1"}, %{kind: "claim"}] do
        chain_reads()
        route = http(:post, path(id), input, agent)

        assert route.status == 404 and route.body["error"]["code"] == "token_not_found",
               "#{id} answered #{inspect(route.body)}"

        assert chain_reads() == [], id
        assert tool(agent, "prepare_stake", Map.put(input, :token_id, id)) == {:error, route.body}
        assert chain_reads() == [], id
        route.body
      end

    assert [_one] = Enum.uniq(answers)
    assert documented?(404, "token_not_found")
  end

  test "only the person's own wallets are prepared for: another of theirs is, any other is refused, as is another person's agent naming theirs",
       %{account: account, agent: agent, listed: listed, wallet: wallet} do
    route = http(:post, path(listed.id), %{kind: "stake", signer: @other}, agent)
    assert route.status == 403 and route.body["error"]["code"] == "wrong_signer"

    assert tool(agent, "prepare_stake", %{token_id: listed.id, kind: "stake", signer: @other}) ==
             {:error, route.body}

    # Another of the person's own wallets, named in its checksummed letter case;
    # the chain holds nothing for it.
    {:ok, bytes} = Address.decode("0xabcdef0123456789abcdef0123456789abcdef01")
    second = Address.checksum(bytes)

    {:ok, _account} =
      Accounts.refresh_verified(account, wallet, [wallet, second], actor: system())

    {:ok, data} = answer(http(:post, path(listed.id), %{kind: "claim", signer: second}, agent))

    assert tool(agent, "prepare_stake", %{token_id: listed.id, kind: "claim", signer: second}) ==
             {:ok, data}

    assert Address.equal?(data["signer"], second)
    assert data["facts"]["balance"] == %{"amount" => "0", "symbol" => "LRVS"}

    # Another person's agent, asking with this person's wallet.
    stranger = paired_agent(TestSupport.register_creator!())
    route = http(:post, path(listed.id), %{kind: "stake", signer: wallet}, stranger)
    assert route.status == 403 and route.body["error"]["code"] == "wrong_signer"
  end

  test "the steps are prepared for the paired agent alone, a connected app calling as it included",
       %{account: account, agent: wallet, listed: listed} do
    {:ok, agent} = Autolaunch.Agents.resolve(wallet)
    app_as_agent = %{agent | connection: %{subject: account.privy_user_id}}
    person = %Human{human_account_id: account.id}
    app = %ConnectedApp{principal: %{subject: account.privy_user_id}}

    for actor <- [agent, app_as_agent, person, app, %Autolaunch.Actors.System{}, nil] do
      may? =
        Ash.can?(
          Ash.ActionInput.for_action(AgentStake, :prepare, %{token_id: listed.id, kind: :claim}),
          actor
        )

      assert may? == actor in [agent, app_as_agent], "#{inspect(actor)}"
    end
  end

  test "every refusal is reached, named alike on both ways in, in a status and code the contract documents",
       %{agent: agent, listed: listed} do
    hidden = token!(kind: :agent)
    {:ok, _hidden} = Autolaunch.hide_auction(hidden.auction, actor: system())
    unlisted = unlisted!()
    id = listed.id
    # More than the staking contract can move at once: 2^128 of the smallest unit.
    too_large = Integer.to_string(div(Integer.pow(2, 128), @unit) + 1)

    cases = [
      {%{}, "nope", %{kind: "stake"}, "invalid_request"},
      {%{}, id, %{kind: "stake", bogus: "x"}, "invalid_request"},
      {%{}, id, %{}, "invalid_request"},
      {%{}, id, %{kind: 1}, "invalid_request"},
      {%{}, id, %{kind: "unstake", amount: 1}, "invalid_request"},
      {%{}, id, %{kind: "stake", signer: 1}, "invalid_request"},
      # The page's other staking actions are not offered here.
      {%{}, id, %{kind: "settle"}, "invalid_request"},
      {%{}, id, %{kind: "convert", amount: "1"}, "invalid_request"},
      {%{}, id, %{kind: "release"}, "invalid_request"},
      # Only an unstake takes an amount, and it needs one.
      {%{}, id, %{kind: "stake", amount: "1"}, "invalid_request"},
      {%{}, id, %{kind: "claim", amount: "1"}, "invalid_request"},
      {%{}, id, %{kind: "stake", amount: ""}, "invalid_request"},
      {%{}, id, %{kind: "claim", amount: ""}, "invalid_request"},
      {%{}, id, %{kind: "unstake"}, "invalid_request"},
      {%{}, Ecto.UUID.generate(), %{kind: "stake"}, "token_not_found"},
      {%{}, hidden.id, %{kind: "stake"}, "token_not_found"},
      {%{}, unlisted.id, %{kind: "stake"}, "token_not_found"},
      {%{}, id, %{kind: "stake", signer: @other}, "wrong_signer"},
      {%{}, id, %{kind: "stake", signer: "nope"}, "wallet_required"},
      {%{}, id, %{kind: "unstake", amount: "abc"}, "invalid_amount"},
      {%{}, id, %{kind: "unstake", amount: ""}, "invalid_amount"},
      {%{}, id, %{kind: "unstake", amount: " 1"}, "invalid_amount"},
      {%{}, id, %{kind: "unstake", amount: "0"}, "invalid_amount"},
      {%{}, id, %{kind: "unstake", amount: "0.0000000000000000001"}, "invalid_amount"},
      {%{}, id, %{kind: "unstake", amount: too_large}, "invalid_amount"},
      {%{}, id, %{kind: "unstake", amount: "3.000000000000000001"}, "amount_above_stake"},
      {%{balance: 0}, id, %{kind: "stake"}, "nothing_to_stake"},
      {%{unavailable: true}, id, %{kind: "stake"}, "chain_unavailable"},
      {%{unavailable: true}, id, %{kind: "claim"}, "chain_unavailable"}
    ]

    reached =
      for {chain, token_id, input, code} <- cases do
        StakeChain.put(Map.merge(@position, chain))
        route = http(:post, path(token_id), input, agent)
        named = "#{token_id} #{inspect(input)} on #{inspect(chain)}"

        assert route.body["error"]["code"] == code, "#{named} answered #{inspect(route.body)}"
        assert route.body["error"]["message"] != ""

        assert tool(agent, "prepare_stake", Map.put(input, :token_id, token_id)) ==
                 {:error, route.body},
               named

        assert documented?(route.status, code), "#{code} at #{route.status}"
        code
      end

    # The site's own fault: its Base deployment cannot be read.
    StakeChain.put(@position)
    keep_env(:autolaunch_base_deployment_id)
    Application.put_env(:autolaunch, :autolaunch_base_deployment_id, "")
    route = http(:post, path(id), %{kind: "stake"}, agent)
    assert route.status == 503 and route.body["error"]["code"] == "stake_unavailable"
    assert tool(agent, "prepare_stake", %{token_id: id, kind: "stake"}) == {:error, route.body}
    assert documented?(503, "stake_unavailable")

    # An agent nobody paired.
    route = http(:post, path(id), %{kind: "stake"}, random_wallet())
    assert route.status == 403 and route.body["error"]["code"] == "agent_not_paired"
    assert documented?(403, "agent_not_paired")

    # Each code the contract lists is reached here, but the account read and
    # prelaunch refusals, each in its own test below.
    assert Enum.sort(Enum.uniq(["agent_not_paired", "stake_unavailable" | reached])) ==
             Enum.sort(
               @codes -- ~w(authentication_required account_unavailable prelaunch_read_only)
             )
  end

  test "switched on, the signed route refuses an unsigned request, an agent nobody paired, another's wallet and an id that is none, each in its own words, and answers a hidden token byte for byte as a missing one",
       %{agent: agent, listed: listed} do
    chain_reads()

    unsigned =
      conn(:post, path(listed.id), Jason.encode!(%{kind: "stake"}))
      |> Map.put(:remote_ip, from())
      |> put_req_header("content-type", "application/json")
      |> @endpoint.call([])

    # Refused before the route, in the sign-in's own words, nothing prepared.
    assert unsigned.status == 401
    assert %{"error" => %{"code" => "verification_failed"}} = body = json(unsigned)
    refute Map.has_key?(body, "data")
    assert chain_reads() == []

    unpaired = http(:post, path(listed.id), %{kind: "stake"}, random_wallet())
    assert unpaired.status == 403 and unpaired.body["error"]["code"] == "agent_not_paired"

    stranger = http(:post, path(listed.id), %{kind: "stake", signer: @other}, agent)

    assert stranger.status == 403 and
             Map.take(stranger.body["error"], ~w(code message)) == %{
               "code" => "wrong_signer",
               "message" => "That wallet is not one of your person's own wallets."
             }

    for id <- ["nope", "1", Ecto.UUID.generate() <> "0"] do
      malformed = http(:post, path(id), %{kind: "stake"}, agent)

      assert malformed.status == 422 and
               Map.take(malformed.body["error"], ~w(code message)) == %{
                 "code" => "invalid_request",
                 "message" =>
                   "Send the token's id as autolaunch_tokens lists it, and in the body kind as stake, unstake or claim, amount for unstake only, and signer if you like, each as text."
               },
             "#{id} answered #{inspect(malformed.body)}"
    end

    hidden = token!(kind: :agent)
    {:ok, _hidden} = Autolaunch.hide_auction(hidden.auction, actor: system())

    [hidden_answer, missing_answer] =
      for id <- [hidden.id, Ecto.UUID.generate()],
          do: signed(:post, path(id), %{kind: "stake"}, agent)

    assert hidden_answer.status == 404 and missing_answer.status == 404

    assert IO.iodata_to_binary(hidden_answer.resp_body) ==
             IO.iodata_to_binary(missing_answer.resp_body)

    assert get_resp_header(hidden_answer, "content-type") ==
             get_resp_header(missing_answer, "content-type")
  end

  test "a paired agent whose person's account cannot be read prepares nothing",
       %{listed: listed} do
    unread = %Agent{
      wallet_address: random_wallet(),
      privy_user_id: "did:privy:unread",
      pairing_id: Ecto.UUID.generate(),
      human_account_id: Ecto.UUID.generate()
    }

    assert {:error, %Ash.Error.Unknown{errors: [%Refused{reason: :authentication_required}]}} =
             Autolaunch.prepare_stake(%{token_id: listed.id, kind: :stake}, actor: unread)

    assert documented?(401, "authentication_required")
  end

  test "a paired agent whose person's account cannot be read as the request arrives is refused account_unavailable",
       %{agent: agent, listed: listed} do
    # The person's account is read with its ENS name as the pairing is resolved.
    lose_reads_of("account_ens_identities")
    route = http(:post, path(listed.id), %{kind: "stake"}, agent)

    assert route.status == 503 and route.body["error"]["code"] == "account_unavailable",
           inspect(route.body)

    assert documented?(503, "account_unavailable")
  end

  test "a person whose wallet evidence has lapsed, or no longer holds together, is refused wallet_required",
       %{account: account, agent: agent, listed: listed, wallet: wallet} do
    for {primary, addresses} <- [{nil, []}, {nil, [wallet]}, {@other, [wallet]}],
        input <- [%{kind: "stake"}, %{kind: "claim", signer: wallet}] do
      {:ok, _account} = Accounts.refresh_verified(account, primary, addresses, actor: system())
      named = "#{inspect({primary, addresses})} #{inspect(input)}"
      route = http(:post, path(listed.id), input, agent)

      assert route.status == 409 and route.body["error"]["code"] == "wallet_required",
             "#{named} answered #{inspect(route.body)}"

      assert tool(agent, "prepare_stake", Map.put(input, :token_id, listed.id)) ==
               {:error, route.body},
             named
    end

    assert documented?(409, "wallet_required")
  end

  test "a read that fails, a raise, or a reason nobody named, is logged by kind alone and refused as stake_unavailable alike on both ways in",
       %{agent: agent, listed: listed, wallet: wallet} do
    refused = fn ->
      {{route, tool}, log} =
        with_log(fn ->
          {http(:post, path(listed.id), %{kind: "stake"}, agent),
           tool(agent, "prepare_stake", %{token_id: listed.id, kind: "stake"})}
        end)

      assert route.status == 503 and route.body["error"]["code"] == "stake_unavailable",
             inspect(route.body)

      assert tool == {:error, route.body}
      refute log =~ wallet
      log
    end

    # The site's Base deployment description as it is held, naming none of its
    # contracts: a fault nobody named, which raises where the review reads one.
    config = Lab.current!()
    held = {Lab, Application.fetch_env!(:autolaunch, :autolaunch_base_deployment)}
    original = :persistent_term.get(held)
    on_exit(fn -> :persistent_term.put(held, original) end)
    :persistent_term.put(held, %{Map.delete(config, :run_id) | addresses: %{}})
    assert refused.() =~ "agent stake failed: KeyError"
    :persistent_term.put(held, original)

    # The token's listing cannot be read: Ash's own error, which names the
    # lost connection.
    lose_reads_of("tokens")

    assert {:error, %Ash.Error.Unknown{errors: [%Ash.Error.Unknown.UnknownError{}]}} =
             Autolaunch.get_listed_token(listed.id, actor: nil)

    assert refused.() =~ "agent stake connection_lost"
    restore_reads_of("tokens")

    # Whatever else an operation hands the route, a policy's refusal or a raw
    # Ash error, is answered the same way.
    for error <- [
          Ash.Error.Forbidden.exception([]),
          Ash.Error.Unknown.exception(
            errors: [Ash.Error.Unknown.UnknownError.exception(error: "x")]
          ),
          :unexpected
        ] do
      {answered, log} =
        with_log(fn -> AgentStakeAnswer.send(conn(:post, "/", ""), {:error, error}) end)

      assert answered.status == 503
      assert Jason.decode!(answered.resp_body)["error"]["code"] == "stake_unavailable"
      assert log =~ "agent stake failed"
    end
  end

  test "each reason the review, the listing, the wallet and the account give has one code, which both ways in answer in a status the contract documents; anything else is stake_unavailable" do
    codes = %{
      authentication_required: :authentication_required,
      wallet_required: :wallet_required,
      wrong_signer: :wrong_signer,
      token_not_listed: :token_not_found,
      amount_required: :invalid_amount,
      invalid_decimal: :invalid_amount,
      amount_not_representable: :invalid_amount,
      amount_too_large: :invalid_amount,
      amount_above_stake: :amount_above_stake,
      nothing_to_stake: :nothing_to_stake,
      chain_unavailable: :chain_unavailable
    }

    assert Map.new(codes, fn {reason, _code} -> {reason, AgentStake.code(reason)} end) == codes

    # The review's own fault for a staking contract it cannot find or read, and
    # every reason it names that no stake, unstake or claim of a listed token
    # reaches, are the site's.
    for unexpected <- [
          :stake_unavailable,
          :unknown_action,
          :invalid_address,
          :unnamed_reason,
          {:closed, :econnreset},
          "text",
          nil,
          %{reason: :x}
        ],
        do: assert(AgentStake.code(unexpected) == :stake_unavailable)

    for code <- Enum.uniq([:invalid_request, :stake_unavailable | Map.values(codes)]) do
      answered = AgentStakeAnswer.refuse(conn(:post, "/", ""), code)
      body = Jason.decode!(answered.resp_body)
      assert body == plain(AgentStakeAnswer.body(code)), "#{code}"
      assert body["error"]["code"] == Atom.to_string(code)
      assert documented?(answered.status, body["error"]["code"]), "#{code} at #{answered.status}"
    end
  end

  test "in prelaunch read-only mode the tool is not listed or run, and the route waits",
       %{agent: agent, listed: listed} do
    Application.put_env(:autolaunch, :prelaunch_read_only, true)

    route = http(:post, path(listed.id), %{kind: "stake"}, agent)
    assert route.status == 503 and route.body["error"]["code"] == "prelaunch_read_only"
    assert documented?(503, "prelaunch_read_only")

    refute "prepare_stake" in tool_names(agent)

    assert %{"error" => _} =
             json(mcp(agent, call("prepare_stake", %{token_id: listed.id, kind: "stake"})))
  end

  test "switched on a paired agent lists the tool as read-only; off, it is not listed, and a call to it is answered as one to no tool",
       %{agent: agent, listed: listed} do
    assert [%{"annotations" => %{"readOnlyHint" => true}}] =
             for(%{"name" => "prepare_stake"} = tool <- listed(agent), do: tool)

    Application.put_env(:autolaunch, :agent_staking, :off)
    refute "prepare_stake" in tool_names(agent)

    # Off, a call, well formed or not, is answered exactly as one to a tool that
    # does not exist, in no words of agent staking.
    for arguments <- [
          %{"input" => %{token_id: listed.id, kind: "stake"}},
          %{"input" => %{token_id: listed.id, kind: "unstake", amount: "1", signer: @other}},
          %{"input" => "not an object"},
          %{"input" => %{bogus: "x"}},
          %{"input" => %{token_id: 1, kind: false}},
          %{"input" => %{}},
          %{},
          "not an object"
        ] do
      called =
        mcp(agent, rpc("tools/call", %{"name" => "prepare_stake", "arguments" => arguments}))

      nothing =
        mcp(agent, rpc("tools/call", %{"name" => "no_such_tool", "arguments" => arguments}))

      said =
        called.resp_body
        |> IO.iodata_to_binary()
        |> String.replace("prepare_stake", "no_such_tool")

      assert {called.status, said} == {nothing.status, IO.iodata_to_binary(nothing.resp_body)},
             inspect(arguments)

      refute said =~ ~r/stak|claim|token|signer|wallet|steps|amount/i
    end
  end

  # Whether the contract documents `code` for the route answering `status`.
  defp documented?(status, code) do
    response = get_in(@contract, ["paths", @path, "post", "responses", Integer.to_string(status)])
    code in @codes and is_map(response) and response["description"] =~ ~r/\b#{code}\b/
  end

  defp path(token_id),
    do: "/api/agent/v1/tokens/#{URI.encode(token_id, &URI.char_unreserved?/1)}/stake/steps"

  # A graduated launch's token the site lists, on Base unless `fields` names
  # another chain, with its auction loaded as its page reads it.
  defp token!(fields) do
    auction =
      [
        chain_id: 8453,
        state: :graduated,
        title: "Stake token",
        symbol: "LRVS",
        token_address: StakeChain.subject()
      ]
      |> Keyword.merge(fields)
      |> TestSupport.project_auction()

    TestSupport.project_token(
      auction_id: auction.id,
      symbol: auction.token_symbol,
      graduated_at: DateTime.utc_now()
    )
    |> Map.put(:auction, auction)
  end

  # The site's graduated Memestock launch on Base, `Autolaunch.StakeChain`'s,
  # trading against AAPLc.
  defp memestock!,
    do:
      token!(
        kind: :stocks,
        address: StakeChain.auction(),
        quote_token_address: StakeChain.stock(),
        quote_token_symbol: "AAPLc",
        quote_token_decimals: 8
      )

  # The site's graduated launch on Robinhood Chain, `Autolaunch.RobinhoodBidChain`'s,
  # trading against TSLA.
  defp robinhood!,
    do:
      token!(
        chain_id: RobinhoodBidChain.chain_id(),
        kind: :stocks,
        address: RobinhoodBidChain.auction(),
        symbol: "RDOG",
        token_address: RobinhoodBidChain.token(),
        quote_token_address: RobinhoodBidChain.stock(),
        quote_token_symbol: "TSLA",
        quote_token_decimals: 18
      )

  # A graduated Robinhood Chain launch made elsewhere, which the site records
  # from the chain as nobody's here and does not list.
  defp unlisted!,
    do:
      token!(
        chain_id: RobinhoodBidChain.chain_id(),
        kind: :stocks,
        origin: :chain,
        creator_human_account_id: nil,
        address: unique_address(),
        symbol: "ELSE",
        token_address: unique_address(),
        quote_token_address: RobinhoodBidChain.stock(),
        quote_token_symbol: "TSLA",
        quote_token_decimals: 18
      )

  # The request the token page's Stake or Claim view makes for the same input.
  defp page_request(token, input) do
    chain = if token.auction.chain_id == RobinhoodBidChain.chain_id(), do: :robinhood, else: :base

    %{
      kind: String.to_existing_atom(input.kind),
      launch: %{chain: chain, auction: token.auction},
      amount: input[:amount]
    }
  end

  defp step(name, to, data),
    do: %{
      "kind" => "transaction",
      "step" => name,
      "to" => Address.normalize!(to),
      "data" => BuilderCode.append(data),
      "value" => "0x0"
    }

  defp splitter_data(signature, arguments),
    do: LabAbi.encode(Lab.abi!(Lab.current!(), :splitter), signature, arguments)

  # Every chain read since the last call, from this test's mailbox: Base's
  # double tells each request, with the contract an `eth_call` asks, and
  # Robinhood Chain's each method.
  defp chain_reads(reads \\ []) do
    receive do
      {:rpc, "eth_call", [%{to: to}, _block]} ->
        chain_reads([{"eth_call", Address.normalize!(to)} | reads])

      {:rpc, method, _params} ->
        chain_reads([method | reads])

      {:robinhood_read, method} ->
        chain_reads([{:robinhood, method} | reads])
    after
      0 -> Enum.reverse(reads)
    end
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

  defp unique_address,
    do:
      "0x" <>
        String.pad_leading(Integer.to_string(System.unique_integer([:positive]), 16), 40, "0")
end
