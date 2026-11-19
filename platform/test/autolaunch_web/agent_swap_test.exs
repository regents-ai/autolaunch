defmodule AutolaunchWeb.AgentSwapTest do
  @moduledoc """
  Agent swaps on a paired agent's two ways in: the signed route the browser
  tool calls and the hosted MCP tool give one answer for one input, refusals
  in the same code and words.

  The steps are the token page's, built by the one function its swap panel
  calls (`Autolaunch.SwapActions.prepare/3`, through its `review/2`): a buy
  or a sell on each pool the site trades, a Base Revstake token's, a Base
  Memestock token's and a Robinhood Chain token's, each with the token
  approval to Permit2 and the Permit2 allowance to the router while the
  wallet lacks them, then the swap, each equal to what the panel's review
  holds for the same wallet but for the second the clock wrote into it. A
  chain that cannot be read is `chain_unavailable`, as on the page; a node
  answering as another chain or with a block header it cannot vouch for is
  the pool read's own fault, `swap_unavailable`, as on the page. An amount
  that is no decimal above zero, and a price protection out of range, are
  refused before any chain is read. Only the person's own wallets are
  prepared for, and only for the agent paired with them, while the person
  has a verified wallet; a token the site does not list or show is answered
  as no token, byte for byte as a missing one, before any chain is read.
  Every refusal is reached and named, with a status and code the contract
  documents, and every reason has one code; anything else is logged by kind
  alone and refused as `swap_unavailable`. Off, or in prelaunch read-only
  mode, the tool is not listed or run, and off a call to it is answered as
  one to a tool that does not exist.

  Base is `Autolaunch.StakeChain`, a Revstake launch and a Memestock one
  trading the same token, and Robinhood Chain is
  `Autolaunch.RobinhoodBidChain`, its launch graduated; the two share the
  site's one chain client, so each case reads through the chain its token
  runs on. The sign-in service is stubbed: it vouches for the wallet a
  request names.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1, system: 0]
  import Autolaunch.DatabaseFaults, only: [lose_reads_of: 1, restore_reads_of: 1]
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Plug.Test, only: [conn: 3]

  alias Autolaunch.Actors.{Agent, ConnectedApp, Human}
  alias Autolaunch.AgentSwap.Refused
  alias Autolaunch.Chain.{Abi, Permit2Abi}
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.SwapActions
  alias AutolaunchWeb.AgentSwapAnswer
  alias RegentChain.{Address, BuilderCode}

  alias Autolaunch.{
    Accounts,
    AgentSwap,
    BaseRpcStub,
    Lab,
    RobinhoodBidChain,
    StakeChain,
    TestSupport
  }

  @moduletag :capture_log
  @contract "../../contracts/agent-swap.openapiv3.yaml"
            |> Path.expand(__DIR__)
            |> YamlElixir.read_from_file!()
  @codes get_in(
           @contract,
           ~w(components schemas AgentSwapError properties error properties code enum)
         )
  @schemas @contract["components"]["schemas"]
  @path "/api/agent/v1/tokens/{token_id}/swap/steps"
  @other "0x2222222222222222222222222222222222222222"
  @base_router "0x6ff5693b99212da76ad316178a184ab56d299b43"
  @unit 10 ** 18
  # The wallet holds 5 of whatever it spends and has allowed nothing, and the
  # pool quotes 10 of whatever it buys.
  @wallet %{balance: 5 * @unit, allowance: 0, swap_quote: 10 * @unit}
  # A Permit2 allowance standing long after any deadline a review sets.
  @standing 2 ** 40

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

    for key <- [:agent_swaps, :prelaunch_read_only], do: keep_env(key)
    Application.put_env(:autolaunch, :agent_swaps, :on)
    # Past the prelaunch gate, which refuses wallet steps until the site opens.
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    StakeChain.install(@wallet)

    %{agent: paired_agent(account), listed: token!(kind: :agent)}
  end

  test "each direction's steps are the swap panel's for the same wallet and Base Revstake token, alike on both ways in",
       %{agent: agent, listed: listed, opts: opts, wallet: wallet} do
    regent = Address.normalize!(Lab.address!(Lab.current!(), :regent))
    subject = Address.normalize!(StakeChain.subject())
    soon = System.os_time(:second) + 60

    cases = [
      # Nothing allowed, so both approvals come first.
      {%{}, %{direction: "buy", amount: "2"}, ["token_approval", "permit2_approval", "swap"]},
      {%{allowance: 2 * @unit}, %{direction: "buy", amount: "2"}, ["permit2_approval", "swap"]},
      {%{allowance: 2 * @unit, permit2: %{amount: 2 * @unit, expiration: @standing}},
       %{direction: "buy", amount: "2", protection: "1"}, ["swap"]},
      # A standing Permit2 allowance that ends before the swap's deadline is
      # granted again.
      {%{allowance: 2 * @unit, permit2: %{amount: 2 * @unit, expiration: soon}},
       %{direction: "buy", amount: "2"}, ["permit2_approval", "swap"]},
      {%{}, %{direction: "sell", amount: "1.5", protection: "10"},
       ["token_approval", "permit2_approval", "swap"]}
    ]

    for {chain, input, names} <- cases do
      StakeChain.put(Map.merge(@wallet, chain))
      named = "#{inspect(input)} on #{inspect(chain)}"
      {:ok, page} = SwapActions.prepare(page_request(listed, input), wallet, opts)
      {:ok, data} = answer(http(:post, path(listed.id), input, agent))
      {:ok, called} = tool(agent, "prepare_swap", Map.put(input, :token_id, listed.id))

      assert timeless(called) == timeless(data), named
      assert timeless(data)["steps"] == timeless(plain(page))["steps"], named
      assert Enum.map(data["steps"], & &1["step"]) == names, named
      assert data["chain"] == plain(page.chain), named
      assert data["chain"]["chain_id"] == 8453
      assert %{"direction" => direction, "signer" => ^wallet, "block" => 32} = data
      assert direction == input.direction
      assert data["block"] == page.block
      assert data["token"] == %{"id" => listed.id, "address" => subject}
      assert_deadline(data)
      assert Enum.sort(Map.keys(data)) == Enum.sort(@schemas["AgentSwapSteps"]["required"])

      {pay, receive} =
        if input.direction == "buy", do: {"REGENT", "LRVS"}, else: {"LRVS", "REGENT"}

      protection = input[:protection] || "6"
      minimum = Decimal.mult(10, Decimal.sub(1, Decimal.div(protection, 100)))

      assert data["facts"] == %{
               "pay" => %{"amount" => input.amount, "symbol" => pay},
               "receive" => %{"amount" => "10", "symbol" => receive},
               "minimum" => %{
                 "amount" => minimum |> Decimal.normalize() |> Decimal.to_string(:normal),
                 "symbol" => receive
               },
               "protection" => protection,
               "fees" => page.facts.fees
             },
             named
    end

    # What the approvals send: the exact amount, to Permit2 and then from it to
    # Uniswap's router, for the side spent.
    StakeChain.put(@wallet)

    assert {:ok, %{"steps" => [approval, permit2, swap]} = data} =
             answer(http(:post, path(listed.id), %{direction: "buy", amount: "2"}, agent))

    assert approval ==
             step(
               "token_approval",
               regent,
               Abi.encode_erc20("approve", [Permit2Abi.address(), 2 * @unit])
             )

    until = deadline(data) + 900

    assert permit2 ==
             step(
               "permit2_approval",
               Permit2Abi.address(),
               Permit2Abi.encode_approve(regent, @base_router, 2 * @unit, until)
             )

    assert swap["to"] == @base_router

    assert {:ok, %{"steps" => [sell_approval | _rest]}} =
             answer(http(:post, path(listed.id), %{direction: "sell", amount: "1.5"}, agent))

    assert sell_approval["to"] == subject
  end

  test "a Base Memestock token and a Robinhood Chain token each trade on their own pool both ways, answered as the page is",
       %{agent: agent, opts: opts, wallet: wallet} do
    memestock = memestock!()
    robinhood = robinhood!()

    cases = [
      {memestock, fn -> StakeChain.put(@wallet) end, 8453, 32, {"AAPLc", "LRVS"}},
      {robinhood,
       fn ->
         RobinhoodBidChain.install(%{
           lifecycle: 2,
           stock_balance: 5 * @unit,
           token_balance: 5 * @unit,
           swap_quote: 10 * @unit
         })
       end, RobinhoodBidChain.chain_id(), 100, {"TSLA", "RDOG"}}
    ]

    for {token, arrange, chain_id, block, {currency, symbol}} <- cases,
        input <- [%{direction: "buy", amount: "2"}, %{direction: "sell", amount: "3"}] do
      arrange.()
      named = "#{chain_id} #{inspect(input)}"
      {:ok, page} = SwapActions.prepare(page_request(token, input), wallet, opts)
      {:ok, data} = answer(http(:post, path(token.id), input, agent))
      {:ok, called} = tool(agent, "prepare_swap", Map.put(input, :token_id, token.id))

      assert timeless(called) == timeless(data), named
      assert timeless(data)["steps"] == timeless(plain(page))["steps"], named

      assert Enum.map(data["steps"], & &1["step"]) ==
               ["token_approval", "permit2_approval", "swap"],
             named

      assert data["chain"] == plain(page.chain), named
      assert data["chain"]["chain_id"] == chain_id, named
      assert data["block"] == block and page.block == block, named
      assert_deadline(data)

      {pay, receive} =
        if input.direction == "buy", do: {currency, symbol}, else: {symbol, currency}

      assert data["facts"]["pay"] == %{"amount" => input.amount, "symbol" => pay}, named
      assert data["facts"]["receive"]["symbol"] == receive, named
      assert data["facts"]["fees"] == page.facts.fees and page.facts.fees != [], named

      # Robinhood Chain trades through its deployment's own router.
      if token == robinhood do
        {:ok, config} = RobinhoodLab.current()
        {:ok, %{router: router}} = RobinhoodLab.swap_addresses(config)
        assert List.last(data["steps"])["to"] == Address.normalize!(router)
      end
    end
  end

  test "a chain that cannot be read is chain_unavailable on the page and on both ways in, read the page's way",
       %{agent: agent, listed: listed, opts: opts, wallet: wallet} do
    robinhood = robinhood!()

    cases = [
      {listed, fn -> StakeChain.put(Map.put(@wallet, :unavailable, true)) end},
      {memestock!(), fn -> StakeChain.put(Map.put(@wallet, :unavailable, true)) end},
      {robinhood, fn -> RobinhoodBidChain.install(%{lifecycle: 2, unreadable: "eth_call"}) end}
    ]

    for {token, arrange} <- cases, input <- [%{direction: "buy", amount: "1"}] do
      arrange.()
      named = "#{token.auction.chain_id} #{token.auction.kind}"
      chain_reads()

      assert {:error, %Ash.Error.Invalid.Unavailable{reason: :chain_unavailable}} =
               SwapActions.prepare(page_request(token, input), wallet, opts),
             named

      paged = chain_reads()
      route = http(:post, path(token.id), input, agent)

      assert route.status == 503 and route.body["error"]["code"] == "chain_unavailable",
             "#{named} answered #{inspect(route.body)}"

      assert chain_reads() == paged, named

      assert tool(agent, "prepare_swap", Map.put(input, :token_id, token.id)) ==
               {:error, route.body},
             named
    end
  end

  test "a node answering as another chain, or with a block header it cannot vouch for, is swap_unavailable on both ways in, as on the page",
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

    for {token, arrange, fault} <- cases do
      arrange.()
      input = %{direction: "buy", amount: "1"}
      named = "#{token.auction.chain_id} #{fault}"

      # The pool's own read names the fault.
      read =
        if token == robinhood,
          do: &Autolaunch.Robinhood.Pool.read/1,
          else: &Autolaunch.Pool.read/1

      assert read.(token.auction) == {:error, fault}, named

      assert {:error, %Ash.Error.Invalid.Unavailable{reason: :swap_unavailable}} =
               SwapActions.prepare(page_request(token, input), wallet, opts),
             named

      {route, log} = with_log(fn -> http(:post, path(token.id), input, agent) end)

      assert route.status == 503 and route.body["error"]["code"] == "swap_unavailable",
             "#{named} answered #{inspect(route.body)}"

      assert log =~ "agent swap"
      refute log =~ wallet

      assert tool(agent, "prepare_swap", Map.put(input, :token_id, token.id)) ==
               {:error, route.body},
             named
    end
  end

  test "a listed token whose launch has not graduated has no pool yet: swap_not_open on both ways in, as the page refuses it, and nothing is logged",
       %{agent: agent, opts: opts, wallet: wallet} do
    # Robinhood Chain's double takes over the one chain client, so it comes last.
    cases = [
      {token!(kind: :agent, state: :ended), fn -> StakeChain.put(@wallet) end},
      {robinhood!(), fn -> RobinhoodBidChain.install(%{lifecycle: 1}) end}
    ]

    for {token, arrange} <- cases, direction <- ["buy", "sell"] do
      arrange.()
      input = %{direction: direction, amount: "1"}
      named = "#{token.auction.chain_id} #{direction}"

      assert {:error, %Ash.Error.Invalid.Unavailable{reason: :swap_not_open}} =
               SwapActions.prepare(page_request(token, input), wallet, opts),
             named

      {route, log} = with_log(fn -> http(:post, path(token.id), input, agent) end)

      assert route.status == 409 and route.body["error"]["code"] == "swap_not_open",
             "#{named} answered #{inspect(route.body)}"

      refute log =~ "agent swap", named

      assert tool(agent, "prepare_swap", Map.put(input, :token_id, token.id)) ==
               {:error, route.body},
             named
    end

    assert documented?(409, "swap_not_open")
  end

  test "an amount that is no decimal above zero, and a price protection out of range, are refused before any chain is read, on the page and on both ways in; only the pool names how many places and how much it takes",
       %{agent: agent, listed: listed, opts: opts, wallet: wallet} do
    too_large = Integer.to_string(div(Integer.pow(2, 127), @unit) + 1)

    before_any_chain = [
      {%{amount: "abc"}, :invalid_decimal, "invalid_amount"},
      {%{amount: ""}, :invalid_decimal, "invalid_amount"},
      {%{amount: " 1"}, :invalid_decimal, "invalid_amount"},
      {%{amount: "-1"}, :invalid_decimal, "invalid_amount"},
      {%{amount: "1e3"}, :invalid_decimal, "invalid_amount"},
      {%{amount: "0"}, :amount_required, "invalid_amount"},
      {%{amount: "0.000"}, :amount_required, "invalid_amount"},
      {%{amount: "1", protection: "0"}, :protection_out_of_range, "protection_out_of_range"},
      {%{amount: "1", protection: "0.99"}, :protection_out_of_range, "protection_out_of_range"},
      {%{amount: "1", protection: "10.01"}, :protection_out_of_range, "protection_out_of_range"},
      {%{amount: "1", protection: "abc"}, :protection_out_of_range, "protection_out_of_range"},
      {%{amount: "1", protection: ""}, :protection_out_of_range, "protection_out_of_range"}
    ]

    for {fields, reason, code} <- before_any_chain do
      input = Map.put(fields, :direction, "buy")
      chain_reads()

      assert {:error, %Ash.Error.Invalid.Unavailable{reason: ^reason}} =
               SwapActions.prepare(page_request(listed, input), wallet, opts),
             inspect(input)

      route = http(:post, path(listed.id), input, agent)
      assert route.body["error"]["code"] == code, inspect(input)

      assert tool(agent, "prepare_swap", Map.put(input, :token_id, listed.id)) ==
               {:error, route.body}

      assert chain_reads() == [], inspect(input)
    end

    # The pool names the decimals the side spent has and the most it takes.
    for {amount, reason} <- [
          {"0.0000000000000000001", :amount_not_representable},
          {too_large, :amount_too_large}
        ] do
      input = %{direction: "buy", amount: amount}
      chain_reads()

      assert {:error, %Ash.Error.Invalid.Unavailable{reason: ^reason}} =
               SwapActions.prepare(page_request(listed, input), wallet, opts)

      assert chain_reads() != []
      route = http(:post, path(listed.id), input, agent)
      assert route.body["error"]["code"] == "invalid_amount", inspect(amount)
    end
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
          input <- [%{direction: "buy", amount: "1"}, %{direction: "sell", amount: "1"}] do
        chain_reads()
        route = http(:post, path(id), input, agent)

        assert route.status == 404 and route.body["error"]["code"] == "token_not_found",
               "#{id} answered #{inspect(route.body)}"

        assert chain_reads() == [], id
        assert tool(agent, "prepare_swap", Map.put(input, :token_id, id)) == {:error, route.body}
        assert chain_reads() == [], id
        route.body
      end

    assert [_one] = Enum.uniq(answers)
    assert documented?(404, "token_not_found")
  end

  test "only the person's own wallets are prepared for: another of theirs is, any other is refused, as is another person's agent naming theirs",
       %{account: account, agent: agent, listed: listed, wallet: wallet} do
    input = %{direction: "buy", amount: "1"}
    route = http(:post, path(listed.id), Map.put(input, :signer, @other), agent)
    assert route.status == 403 and route.body["error"]["code"] == "wrong_signer"

    assert tool(agent, "prepare_swap", Map.merge(input, %{token_id: listed.id, signer: @other})) ==
             {:error, route.body}

    # Another of the person's own wallets, named in its checksummed letter case;
    # the chain holds nothing for it.
    {:ok, bytes} = Address.decode("0xabcdef0123456789abcdef0123456789abcdef01")
    second = Address.checksum(bytes)

    {:ok, _account} =
      Accounts.refresh_verified(account, wallet, [wallet, second], actor: system())

    route = http(:post, path(listed.id), Map.put(input, :signer, second), agent)
    assert route.status == 409 and route.body["error"]["code"] == "amount_above_balance"

    assert tool(agent, "prepare_swap", Map.merge(input, %{token_id: listed.id, signer: second})) ==
             {:error, route.body}

    # Left out, the wallet they signed in with, which holds enough.
    {:ok, data} = answer(http(:post, path(listed.id), input, agent))
    assert data["signer"] == wallet

    # Another person's agent, asking with this person's wallet.
    stranger = paired_agent(TestSupport.register_creator!())
    route = http(:post, path(listed.id), Map.put(input, :signer, wallet), stranger)
    assert route.status == 403 and route.body["error"]["code"] == "wrong_signer"
  end

  test "the steps are prepared for the paired agent alone, a connected app calling as it included",
       %{account: account, agent: wallet, listed: listed} do
    {:ok, agent} = Autolaunch.Agents.resolve(wallet)
    app_as_agent = %{agent | connection: %{subject: account.privy_user_id}}
    person = %Human{human_account_id: account.id}
    app = %ConnectedApp{principal: %{subject: account.privy_user_id}}
    input = %{token_id: listed.id, direction: :buy, amount: "1"}

    for actor <- [agent, app_as_agent, person, app, %Autolaunch.Actors.System{}, nil] do
      may? = Ash.can?(Ash.ActionInput.for_action(AgentSwap, :prepare, input), actor)
      assert may? == actor in [agent, app_as_agent], "#{inspect(actor)}"
    end
  end

  test "every refusal is reached, named alike on both ways in, in a status and code the contract documents",
       %{agent: agent, listed: listed} do
    hidden = token!(kind: :agent)
    {:ok, _hidden} = Autolaunch.hide_auction(hidden.auction, actor: system())
    unlisted = unlisted!()
    not_open = token!(kind: :agent, state: :ended)
    id = listed.id
    buy = %{direction: "buy", amount: "1"}
    # More than the quoter takes at once: 2^127 of the smallest unit.
    too_large = Integer.to_string(div(Integer.pow(2, 127), @unit) + 1)
    long = String.duplicate("1", 129)

    cases = [
      {%{}, "nope", buy, "invalid_request"},
      {%{}, id, Map.put(buy, :bogus, "x"), "invalid_request"},
      {%{}, id, %{}, "invalid_request"},
      {%{}, id, %{direction: "buy"}, "invalid_request"},
      {%{}, id, %{amount: "1"}, "invalid_request"},
      {%{}, id, %{buy | direction: 1}, "invalid_request"},
      {%{}, id, %{buy | amount: 1}, "invalid_request"},
      {%{}, id, Map.put(buy, :protection, 6), "invalid_request"},
      {%{}, id, Map.put(buy, :signer, 1), "invalid_request"},
      # Only a buy or a sell is offered, and no field longer than any it reads.
      {%{}, id, %{buy | direction: "swap"}, "invalid_request"},
      {%{}, id, %{buy | amount: long}, "invalid_request"},
      {%{}, id, Map.put(buy, :protection, long), "invalid_request"},
      {%{}, id, Map.put(buy, :signer, long), "invalid_request"},
      {%{}, Ecto.UUID.generate(), buy, "token_not_found"},
      {%{}, hidden.id, buy, "token_not_found"},
      {%{}, unlisted.id, buy, "token_not_found"},
      {%{}, id, Map.put(buy, :signer, @other), "wrong_signer"},
      {%{}, id, Map.put(buy, :signer, "nope"), "wallet_required"},
      {%{}, id, %{buy | amount: "abc"}, "invalid_amount"},
      {%{}, id, %{buy | amount: ""}, "invalid_amount"},
      {%{}, id, %{buy | amount: "0"}, "invalid_amount"},
      {%{}, id, %{buy | amount: "0.0000000000000000001"}, "invalid_amount"},
      {%{}, id, %{buy | amount: too_large}, "invalid_amount"},
      {%{}, id, Map.put(buy, :protection, "11"), "protection_out_of_range"},
      {%{}, id, Map.put(buy, :protection, "0.5"), "protection_out_of_range"},
      {%{}, not_open.id, buy, "swap_not_open"},
      {%{}, id, %{buy | amount: "5.000000000000000001"}, "amount_above_balance"},
      {%{balance: 0}, id, %{direction: "sell", amount: "1"}, "amount_above_balance"},
      {%{swap_quote: 0}, id, buy, "quote_unavailable"},
      {%{unavailable: true}, id, buy, "chain_unavailable"},
      {%{unavailable: true}, id, %{direction: "sell", amount: "1"}, "chain_unavailable"}
    ]

    reached =
      for {chain, token_id, input, code} <- cases do
        StakeChain.put(Map.merge(@wallet, chain))
        route = http(:post, path(token_id), input, agent)
        named = "#{token_id} #{inspect(input)} on #{inspect(chain)}"

        assert route.body["error"]["code"] == code, "#{named} answered #{inspect(route.body)}"
        assert route.body["error"]["message"] != ""

        assert tool(agent, "prepare_swap", Map.put(input, :token_id, token_id)) ==
                 {:error, route.body},
               named

        assert documented?(route.status, code), "#{code} at #{route.status}"
        code
      end

    # The site's own fault: its Base deployment cannot be read.
    StakeChain.put(@wallet)
    keep_env(:autolaunch_base_deployment_id)
    Application.put_env(:autolaunch, :autolaunch_base_deployment_id, "")
    route = http(:post, path(id), buy, agent)
    assert route.status == 503 and route.body["error"]["code"] == "swap_unavailable"
    assert tool(agent, "prepare_swap", Map.put(buy, :token_id, id)) == {:error, route.body}
    assert documented?(503, "swap_unavailable")

    # An agent nobody paired.
    route = http(:post, path(id), buy, random_wallet())
    assert route.status == 403 and route.body["error"]["code"] == "agent_not_paired"
    assert documented?(403, "agent_not_paired")

    # Each code the contract lists is reached here, but the account read and
    # prelaunch refusals, each in its own test below.
    assert Enum.sort(Enum.uniq(["agent_not_paired", "swap_unavailable" | reached])) ==
             Enum.sort(
               @codes -- ~w(authentication_required account_unavailable prelaunch_read_only)
             )
  end

  test "switched on, the signed route refuses an unsigned request, an agent nobody paired, another's wallet and an id that is none, each in its own words, and answers a hidden token byte for byte as a missing one",
       %{agent: agent, listed: listed} do
    buy = %{direction: "buy", amount: "1"}
    chain_reads()

    unsigned =
      conn(:post, path(listed.id), Jason.encode!(buy))
      |> Map.put(:remote_ip, from())
      |> put_req_header("content-type", "application/json")
      |> @endpoint.call([])

    # Refused before the route, in the sign-in's own words, nothing prepared.
    assert unsigned.status == 401
    assert %{"error" => %{"code" => "verification_failed"}} = body = json(unsigned)
    refute Map.has_key?(body, "data")
    assert chain_reads() == []

    unpaired = http(:post, path(listed.id), buy, random_wallet())
    assert unpaired.status == 403 and unpaired.body["error"]["code"] == "agent_not_paired"

    stranger = http(:post, path(listed.id), Map.put(buy, :signer, @other), agent)

    assert stranger.status == 403 and
             Map.take(stranger.body["error"], ~w(code message)) == %{
               "code" => "wrong_signer",
               "message" => "That wallet is not one of your person's own wallets."
             }

    for id <- ["nope", "1", Ecto.UUID.generate() <> "0"] do
      malformed = http(:post, path(id), buy, agent)

      assert malformed.status == 422 and
               Map.take(malformed.body["error"], ~w(code message)) == %{
                 "code" => "invalid_request",
                 "message" =>
                   "Send the token's id as autolaunch_tokens lists it, and in the body direction as buy or sell and amount, with protection and signer if you like, each as text."
               },
             "#{id} answered #{inspect(malformed.body)}"
    end

    hidden = token!(kind: :agent)
    {:ok, _hidden} = Autolaunch.hide_auction(hidden.auction, actor: system())

    [hidden_answer, missing_answer] =
      for id <- [hidden.id, Ecto.UUID.generate()], do: signed(:post, path(id), buy, agent)

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
             Autolaunch.prepare_swap(%{token_id: listed.id, direction: :buy, amount: "1"},
               actor: unread
             )

    assert documented?(401, "authentication_required")
  end

  test "a paired agent whose person's account cannot be read as the request arrives is refused account_unavailable",
       %{agent: agent, listed: listed} do
    # The person's account is read with its ENS name as the pairing is resolved.
    lose_reads_of("account_ens_identities")
    route = http(:post, path(listed.id), %{direction: "buy", amount: "1"}, agent)

    assert route.status == 503 and route.body["error"]["code"] == "account_unavailable",
           inspect(route.body)

    assert documented?(503, "account_unavailable")
  end

  test "a person whose wallet evidence has lapsed, or no longer holds together, is refused wallet_required",
       %{account: account, agent: agent, listed: listed, wallet: wallet} do
    for {primary, addresses} <- [{nil, []}, {nil, [wallet]}, {@other, [wallet]}],
        input <- [
          %{direction: "buy", amount: "1"},
          %{direction: "sell", amount: "1", signer: wallet}
        ] do
      {:ok, _account} = Accounts.refresh_verified(account, primary, addresses, actor: system())
      named = "#{inspect({primary, addresses})} #{inspect(input)}"
      route = http(:post, path(listed.id), input, agent)

      assert route.status == 409 and route.body["error"]["code"] == "wallet_required",
             "#{named} answered #{inspect(route.body)}"

      assert tool(agent, "prepare_swap", Map.put(input, :token_id, listed.id)) ==
               {:error, route.body},
             named
    end

    assert documented?(409, "wallet_required")
  end

  test "a read that fails, a raise, or a reason nobody named, is logged by kind alone and refused as swap_unavailable alike on both ways in",
       %{agent: agent, listed: listed, wallet: wallet} do
    buy = %{direction: "buy", amount: "1"}

    refused = fn ->
      {{route, tool}, log} =
        with_log(fn ->
          {http(:post, path(listed.id), buy, agent),
           tool(agent, "prepare_swap", Map.put(buy, :token_id, listed.id))}
        end)

      assert route.status == 503 and route.body["error"]["code"] == "swap_unavailable",
             inspect(route.body)

      assert tool == {:error, route.body}
      refute log =~ wallet
      log
    end

    # Uniswap's router, quoter or Permit2 has no code on the chain the site
    # reads: the site's own fault, which the agent cannot mend.
    BaseRpcStub.put(%{code: "0x"})
    assert refused.() =~ "agent swap failed: lab_contract_missing"
    BaseRpcStub.put(%{code: "0x6000"})

    # The site's Base deployment description as it is held, naming none of its
    # contracts: a fault nobody named, which raises where the review reads one.
    config = Lab.current!()
    held = {Lab, Application.fetch_env!(:autolaunch, :autolaunch_base_deployment)}
    original = :persistent_term.get(held)
    on_exit(fn -> :persistent_term.put(held, original) end)
    :persistent_term.put(held, %{Map.delete(config, :run_id) | addresses: %{}})
    assert refused.() =~ "agent swap failed: KeyError"
    :persistent_term.put(held, original)

    # The token's listing cannot be read: Ash's own error, which names the
    # lost connection.
    lose_reads_of("tokens")

    assert {:error, %Ash.Error.Unknown{errors: [%Ash.Error.Unknown.UnknownError{}]}} =
             Autolaunch.get_listed_token(listed.id, actor: nil)

    assert refused.() =~ "agent swap connection_lost"
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
        with_log(fn -> AgentSwapAnswer.send(conn(:post, "/", ""), {:error, error}) end)

      assert answered.status == 503
      assert Jason.decode!(answered.resp_body)["error"]["code"] == "swap_unavailable"
      assert log =~ "agent swap failed"
    end
  end

  test "each reason the review, the listing, the wallet and the account give has one code, which both ways in answer in a status the contract documents; anything else is swap_unavailable" do
    codes = %{
      authentication_required: :authentication_required,
      wallet_required: :wallet_required,
      wrong_signer: :wrong_signer,
      token_not_listed: :token_not_found,
      amount_required: :invalid_amount,
      invalid_decimal: :invalid_amount,
      amount_not_representable: :invalid_amount,
      amount_too_large: :invalid_amount,
      protection_out_of_range: :protection_out_of_range,
      swap_not_open: :swap_not_open,
      amount_above_balance: :amount_above_balance,
      quote_unavailable: :quote_unavailable,
      chain_unavailable: :chain_unavailable,
      invalid_chain_response: :chain_unavailable
    }

    assert Map.new(codes, fn {reason, _code} -> {reason, AgentSwap.code(reason)} end) == codes

    # The review's own fault for a pool, router or deployment it cannot find or
    # read, and every reason it names that no buy or sell of a listed token
    # reaches, are the site's.
    for unexpected <- [
          :swap_unavailable,
          :lab_contract_missing,
          :invalid_direction,
          :invalid_address,
          :unnamed_reason,
          {:closed, :econnreset},
          "text",
          nil,
          %{reason: :x}
        ],
        do: assert(AgentSwap.code(unexpected) == :swap_unavailable)

    for code <- Enum.uniq([:invalid_request, :swap_unavailable | Map.values(codes)]) do
      answered = AgentSwapAnswer.refuse(conn(:post, "/", ""), code)
      body = Jason.decode!(answered.resp_body)
      assert body == plain(AgentSwapAnswer.body(code)), "#{code}"
      assert body["error"]["code"] == Atom.to_string(code)
      assert documented?(answered.status, body["error"]["code"]), "#{code} at #{answered.status}"
    end
  end

  test "in prelaunch read-only mode the tool is not listed or run, and the route waits",
       %{agent: agent, listed: listed} do
    Application.put_env(:autolaunch, :prelaunch_read_only, true)
    buy = %{direction: "buy", amount: "1"}

    route = http(:post, path(listed.id), buy, agent)
    assert route.status == 503 and route.body["error"]["code"] == "prelaunch_read_only"
    assert documented?(503, "prelaunch_read_only")

    refute "prepare_swap" in tool_names(agent)

    assert %{"error" => _} =
             json(mcp(agent, call("prepare_swap", Map.put(buy, :token_id, listed.id))))
  end

  test "switched on a paired agent lists the tool as read-only; off, it is not listed, and a call to it is answered as one to no tool",
       %{agent: agent, listed: listed} do
    assert [%{"annotations" => %{"readOnlyHint" => true}}] =
             for(%{"name" => "prepare_swap"} = tool <- listed(agent), do: tool)

    Application.put_env(:autolaunch, :agent_swaps, :off)
    refute "prepare_swap" in tool_names(agent)

    # Off, a call, well formed or not, is answered exactly as one to a tool that
    # does not exist, in no words of agent swaps.
    for arguments <- [
          %{"input" => %{token_id: listed.id, direction: "buy", amount: "1"}},
          %{
            "input" => %{
              token_id: listed.id,
              direction: "sell",
              amount: "1",
              protection: "2",
              signer: @other
            }
          },
          %{"input" => "not an object"},
          %{"input" => %{bogus: "x"}},
          %{"input" => %{token_id: 1, direction: false}},
          %{"input" => %{}},
          %{},
          "not an object"
        ] do
      called =
        mcp(agent, rpc("tools/call", %{"name" => "prepare_swap", "arguments" => arguments}))

      nothing =
        mcp(agent, rpc("tools/call", %{"name" => "no_such_tool", "arguments" => arguments}))

      said =
        called.resp_body
        |> IO.iodata_to_binary()
        |> String.replace("prepare_swap", "no_such_tool")

      assert {called.status, said} == {nothing.status, IO.iodata_to_binary(nothing.resp_body)},
             inspect(arguments)

      refute said =~ ~r/swap|buy|sell|trad|token|signer|wallet|steps|amount|protection/i
    end
  end

  # Whether the contract documents `code` for the route answering `status`.
  defp documented?(status, code) do
    response = get_in(@contract, ["paths", @path, "post", "responses", Integer.to_string(status)])
    code in @codes and is_map(response) and response["description"] =~ ~r/\b#{code}\b/
  end

  defp path(token_id),
    do: "/api/agent/v1/tokens/#{URI.encode(token_id, &URI.char_unreserved?/1)}/swap/steps"

  # A graduated launch's token the site lists, on Base unless `fields` names
  # another chain, with its auction loaded as its page reads it.
  defp token!(fields) do
    auction =
      [
        chain_id: 8453,
        state: :graduated,
        title: "Swap token",
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

  # The request the token page's swap panel makes for the same input.
  defp page_request(token, input) do
    chain = if token.auction.chain_id == RobinhoodBidChain.chain_id(), do: :robinhood, else: :base

    %{
      launch: %{chain: chain, auction: token.auction},
      direction: String.to_existing_atom(input.direction),
      amount: input.amount,
      protection: input[:protection] || SwapActions.default_protection()
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

  # A review as it reads whatever second it was made in: the swap's deadline
  # and a new Permit2 allowance's expiry, the only words the clock writes,
  # zeroed, and when the steps stop being good left out.
  defp timeless(review) do
    review
    |> Map.delete("expires_at")
    |> Map.update!("steps", fn steps -> Enum.map(steps, &timeless_step/1) end)
  end

  defp timeless_step(%{"step" => "swap", "data" => data} = step),
    do: %{step | "data" => zeroed(data, 2)}

  defp timeless_step(%{"step" => "permit2_approval", "data" => data} = step),
    do: %{step | "data" => zeroed(data, 3)}

  defp timeless_step(step), do: step

  # Calldata with its argument word `index` zeroed.
  defp zeroed("0x" <> hex, index) do
    before = 8 + 64 * index
    <<head::binary-size(^before), _word::binary-size(64), rest::binary>> = hex
    "0x" <> head <> String.duplicate("0", 64) <> rest
  end

  # The swap's deadline, as its calldata names it.
  defp deadline(%{"steps" => steps}) do
    %{"data" => "0x" <> hex} = List.last(steps)
    hex |> binary_part(8 + 64 * 2, 64) |> String.to_integer(16)
  end

  # The steps stop being good at the swap's deadline, fifteen minutes on.
  defp assert_deadline(data) do
    {:ok, expires_at, 0} = DateTime.from_iso8601(data["expires_at"])
    assert DateTime.to_unix(expires_at) == deadline(data)
    assert DateTime.diff(expires_at, DateTime.utc_now()) in 880..900
  end

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
