defmodule AutolaunchWeb.AgentPaymentTest do
  @moduledoc """
  Agent payments on a paired agent's two ways in: the signed route the browser
  tool calls and the hosted MCP tool give one answer for one input, refusals
  in the same code and words.

  The steps are the token page's, built by the one function its Make a
  payment card calls (`Autolaunch.SubjectWalletActions.prepare/5`, through its
  `review/4`): a payment of USDC, REGENT or the token itself, with the exact
  approval to the payment address while the wallet lacks it, then the
  payment, and a sweep of what waits at the payment address, each equal to
  what the card's review holds for the same wallet but for the reference
  every payment draws anew. A token the card is not shown for takes no
  payment here, nor does any token on a site reading the local Base fork; a
  token whose treasury the launch has not named yet takes none yet; a revenue
  split or payment address that is not the launch's own is refused, as on
  the page. A chain that cannot be read, or a block header it cannot vouch
  for, is `chain_unavailable`, as on the page; a node answering as another
  chain is the launch read's own fault, `payment_unavailable`, as on the
  page. An amount that is no decimal above zero, or finer than the asset, is
  refused before any chain is read. Only the person's own wallets are
  prepared for, and only for the agent paired with them, while the person
  has a verified wallet; a token the site does not list or show is answered
  as no token, byte for byte as a missing one, before any chain is read.
  Every refusal is reached and named, with a status and code the contract
  documents, and every reason has one code; anything else is logged by kind
  alone and refused as `payment_unavailable`. Off, or in prelaunch read-only
  mode, the tool is not listed or run, and off a call to it is answered as
  one to a tool that does not exist.

  Base is `Autolaunch.StakeChain`, whose Revstake launch record names the
  token, its revenue split, payment address and treasury, and the card's one
  snapshot of the split, the payment address and the wallet is
  `Autolaunch.SubjectWalletFixture` bound to that launch: the wallet holds 50
  USDC, 20 REGENT and 900 of the token and has allowed nothing, 7 USDC waits
  at the payment address, and a quarter of the token's supply is staked. The
  sign-in service is stubbed: it vouches for the wallet a request names.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1, system: 0]
  import Autolaunch.DatabaseFaults, only: [lose_reads_of: 1, restore_reads_of: 1]
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Plug.Test, only: [conn: 3]

  alias Autolaunch.Actors.{Agent, ConnectedApp, Human}
  alias Autolaunch.AgentPayment.Refused
  alias Autolaunch.Chain.{Abi, SubjectAbi}
  alias Autolaunch.SubjectWalletActions
  alias Autolaunch.TestAutolaunchSubjectWalletChainClient, as: SubjectChain
  alias AutolaunchWeb.AgentPaymentAnswer
  alias RegentChain.{Address, BuilderCode}

  alias Autolaunch.{
    Accounts,
    AgentPayment,
    BaseRpcStub,
    Lab,
    RobinhoodBidChain,
    StakeChain,
    SubjectWalletFixture,
    TestSupport
  }

  @moduletag :capture_log
  @contract "../../contracts/agent-payment.openapiv3.yaml"
            |> Path.expand(__DIR__)
            |> YamlElixir.read_from_file!()
  @codes get_in(
           @contract,
           ~w(components schemas AgentPaymentError properties error properties code enum)
         )
  @schemas @contract["components"]["schemas"]
  @path "/api/agent/v1/tokens/{token_id}/payment/steps"
  @other "0x2222222222222222222222222222222222222222"
  @zero "0x0000000000000000000000000000000000000000"
  @unit 10 ** 18
  @usdc_unit 10 ** 6
  @pay %{kind: "pay", asset: "usdc", amount: "1"}
  @sweep %{kind: "sweep", asset: "usdc"}

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

    for key <- [:agent_payments, :prelaunch_read_only], do: keep_env(key)
    Application.put_env(:autolaunch, :agent_payments, :on)
    # Past the prelaunch gate, which refuses wallet steps until the site opens.
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    StakeChain.install()
    SubjectWalletFixture.install(bound())

    %{agent: paired_agent(account), listed: token!(kind: :agent)}
  end

  test "each payment and sweep's steps are the payment card's for the same wallet and token, alike on both ways in",
       %{agent: agent, listed: listed, opts: opts, wallet: wallet} do
    usdc = Address.normalize!(Abi.usdc_address())
    regent = Address.normalize!(Abi.regent_address())
    subject = Address.normalize!(StakeChain.subject())
    receiver = Address.normalize!(StakeChain.receiver())

    cases = [
      # Nothing allowed, so the exact approval comes first.
      {%{}, @pay, ["approval", "action"], {usdc, @usdc_unit, "USDC"}},
      {%{allowance: @usdc_unit}, @pay, ["action"], {usdc, @usdc_unit, "USDC"}},
      {%{}, %{kind: "pay", asset: "regent", amount: "2.5"}, ["approval", "action"],
       {regent, 25 * div(@unit, 10), "REGENT"}},
      {%{}, %{kind: "pay", asset: "token", amount: "900"}, ["approval", "action"],
       {subject, 900 * @unit, "LRVS"}},
      # A sweep routes everything waiting at the payment address and needs no
      # approval.
      {%{}, @sweep, ["action"], {usdc, 7 * @usdc_unit, "USDC"}},
      {%{receiver_balances: %{subject: 3 * @unit, usdc: 0, regent: 0}},
       %{kind: "sweep", asset: "token"}, ["action"], {subject, 3 * @unit, "LRVS"}}
    ]

    for {chain, input, names, {asset, amount, symbol}} <- cases do
      payments(chain)
      named = "#{inspect(input)} on #{inspect(chain)}"

      {:ok, page} =
        SubjectWalletActions.prepare(
          listed.auction.id,
          wallet,
          String.to_existing_atom(input.kind),
          page_params(input),
          opts
        )

      {:ok, data} = answer(http(:post, path(listed.id), input, agent))
      {:ok, called} = tool(agent, "prepare_payment", Map.put(input, :token_id, listed.id))

      assert referenceless(called) == referenceless(data), named
      assert referenceless(data)["steps"] == referenceless(plain(page))["steps"], named
      assert Enum.map(data["steps"], & &1["step"]) == names, named
      assert data["chain"] == plain(page.chain), named
      assert data["chain"]["chain_id"] == 8453

      assert %{"kind" => kind, "asset" => asset_name, "signer" => ^wallet} = data
      assert {kind, asset_name} == {input.kind, input.asset}
      assert data["token"] == %{"id" => listed.id, "address" => subject}
      assert Enum.sort(Map.keys(data)) == Enum.sort(@schemas["AgentPaymentSteps"]["required"])

      # The payment address takes it, and each payment carries its own
      # reference, the one its facts name; a sweep's is zero.
      action = List.last(data["steps"])
      assert action["to"] == receiver, named

      if input.kind == "pay" do
        assert action ==
                 step(
                   "action",
                   receiver,
                   SubjectAbi.encode_pay(asset, amount, data["facts"]["payment_reference"])
                 ),
               named

        refute data["facts"]["payment_reference"] == called["facts"]["payment_reference"]
      else
        assert action == step("action", receiver, SubjectAbi.encode_sweep(asset)), named
        assert data["facts"]["payment_reference"] == "0x" <> String.duplicate("0", 64)
      end

      if "approval" in names do
        assert hd(data["steps"]) ==
                 step("approval", asset, Abi.encode_erc20("approve", [receiver, amount])),
               named
      end

      # The amount and how it divides, as the card's sentence gives them.
      allocation = page.facts.allocation
      units = &%{"amount" => SubjectWalletActions.units(&1, page.facts.asset), "symbol" => symbol}

      assert data["facts"] == %{
               "amount" => units.(amount),
               "receiver" => receiver,
               "payment_reference" => data["facts"]["payment_reference"],
               "split" => %{
                 "protocol" => units.(allocation.skim),
                 "stakers" => units.(allocation.stakers),
                 "treasury" => units.(allocation.treasury)
               }
             },
             named

      assert allocation.gross == amount, named
    end

    # One USDC: 2% to the protocol, and the rest a quarter to the stakers, who
    # hold a quarter of the supply, and three quarters to the treasury.
    payments(%{})
    {:ok, data} = answer(http(:post, path(listed.id), @pay, agent))

    assert data["facts"]["split"] == %{
             "protocol" => %{"amount" => "0.02", "symbol" => "USDC"},
             "stakers" => %{"amount" => "0.245", "symbol" => "USDC"},
             "treasury" => %{"amount" => "0.735", "symbol" => "USDC"}
           }
  end

  test "a token the payment card is not shown for, and any token on a site reading the local Base fork, takes no payment here, before any chain is read",
       %{agent: agent, listed: listed, opts: opts, wallet: wallet} do
    for token <- [memestock!(), robinhood!()], input <- [@pay, @sweep] do
      named = "#{token.auction.chain_id} #{token.auction.kind} #{inspect(input)}"
      chain_reads()

      # The card's own review names no Revstake launch.
      assert {:error, %Ash.Error.Invalid.Unavailable{reason: :subject_not_found}} =
               SubjectWalletActions.prepare(
                 token.auction.id,
                 wallet,
                 String.to_existing_atom(input.kind),
                 page_params(input),
                 opts
               ),
             named

      route = http(:post, path(token.id), input, agent)

      assert route.status == 409 and route.body["error"]["code"] == "payment_not_offered",
             "#{named} answered #{inspect(route.body)}"

      assert tool(agent, "prepare_payment", Map.put(input, :token_id, token.id)) ==
               {:error, route.body},
             named

      assert chain_reads() == [], named
    end

    # A site reading the local Base fork, whose token pages show no payment card.
    keep_env(:autolaunch_base_chain_id)
    Application.put_env(:autolaunch, :autolaunch_base_chain_id, 31_337)
    assert Lab.test_chain?()
    chain_reads()

    for input <- [@pay, @sweep] do
      route = http(:post, path(listed.id), input, agent)

      assert route.status == 409 and route.body["error"]["code"] == "payment_not_offered",
             inspect(route.body)

      assert tool(agent, "prepare_payment", Map.put(input, :token_id, listed.id)) ==
               {:error, route.body}
    end

    assert chain_reads() == []
    assert documented?(409, "payment_not_offered")
  end

  test "a token whose launch has named no treasury yet takes no payment yet, as on the page",
       %{agent: agent, listed: listed, opts: opts, wallet: wallet} do
    StakeChain.put(%{treasury: @zero})

    for input <- [@pay, @sweep] do
      assert {:error, %Ash.Error.Invalid.Unavailable{reason: :subject_treasury_unavailable}} =
               SubjectWalletActions.prepare(
                 listed.auction.id,
                 wallet,
                 String.to_existing_atom(input.kind),
                 page_params(input),
                 opts
               )

      route = http(:post, path(listed.id), input, agent)

      assert route.status == 409 and route.body["error"]["code"] == "payment_not_open",
             inspect(route.body)

      assert tool(agent, "prepare_payment", Map.put(input, :token_id, listed.id)) ==
               {:error, route.body}
    end

    assert documented?(409, "payment_not_open")
  end

  test "a revenue split or payment address the chain says is not the launch's own is refused, as on the page",
       %{agent: agent, listed: listed, opts: opts, wallet: wallet} do
    cases = [
      {%{treasury: @other}, :splitter_treasury_mismatch},
      {%{splitter: @other}, :receiver_splitter_mismatch},
      {%{token: @other}, :splitter_subject_mismatch},
      {%{beneficiary: @other}, :receiver_not_canonical},
      {%{note_editor: @other}, :receiver_not_canonical},
      {%{referral_bps: 100}, :receiver_not_canonical}
    ]

    for {broken, reason} <- cases, input <- [@pay, @sweep] do
      payments(broken)
      named = "#{inspect(broken)} #{inspect(input)}"

      assert {:error, %Ash.Error.Invalid.Unavailable{reason: ^reason}} =
               SubjectWalletActions.prepare(
                 listed.auction.id,
                 wallet,
                 String.to_existing_atom(input.kind),
                 page_params(input),
                 opts
               ),
             named

      route = http(:post, path(listed.id), input, agent)

      assert route.status == 409 and route.body["error"]["code"] == "split_mismatch",
             "#{named} answered #{inspect(route.body)}"

      assert tool(agent, "prepare_payment", Map.put(input, :token_id, listed.id)) ==
               {:error, route.body},
             named
    end

    assert documented?(409, "split_mismatch")
  end

  test "a chain that cannot be read, or a block header it cannot vouch for, is chain_unavailable on the page and on both ways in; a node answering as another chain is payment_unavailable, as on the page",
       %{agent: agent, listed: listed, opts: opts, wallet: wallet} do
    header = %{"number" => "0x20", "hash" => "0xnope", "timestamp" => "0x6700"}

    cases = [
      {fn -> StakeChain.put(%{unavailable: true}) end, :chain_unavailable, "chain_unavailable"},
      {fn -> BaseRpcStub.put(%{chain_id: "0x2105", blocks: %{"latest" => header}}) end,
       :chain_unavailable, "chain_unavailable"},
      {fn -> BaseRpcStub.put(%{chain_id: "0x1"}) end, :subject_unavailable, "payment_unavailable"}
    ]

    for {arrange, reason, code} <- cases, input <- [@pay, @sweep] do
      StakeChain.install()
      arrange.()
      named = "#{code} #{inspect(input)}"

      assert {:error, %Ash.Error.Invalid.Unavailable{reason: ^reason}} =
               SubjectWalletActions.prepare(
                 listed.auction.id,
                 wallet,
                 String.to_existing_atom(input.kind),
                 page_params(input),
                 opts
               ),
             named

      {route, log} = with_log(fn -> http(:post, path(listed.id), input, agent) end)

      assert route.status == 503 and route.body["error"]["code"] == code,
             "#{named} answered #{inspect(route.body)}"

      if code == "payment_unavailable", do: assert(log =~ "agent payment failed: #{reason}")
      refute log =~ wallet

      assert tool(agent, "prepare_payment", Map.put(input, :token_id, listed.id)) ==
               {:error, route.body},
             named
    end

    # The card's snapshot of the split, the payment address and the wallet
    # cannot be read either.
    StakeChain.install()
    BaseRpcStub.put(%{chain_id: "0x2105"})
    SubjectChain.put(%{unavailable: :chain_unavailable})
    route = http(:post, path(listed.id), @pay, agent)
    assert route.status == 503 and route.body["error"]["code"] == "chain_unavailable"
    assert documented?(503, "chain_unavailable")
  end

  test "an amount that is no decimal above zero, or finer than the asset, is refused before any chain is read, on the page and on both ways in",
       %{agent: agent, listed: listed, opts: opts, wallet: wallet} do
    too_large = Integer.to_string(Integer.pow(2, 128))

    for {asset, amount} <- [
          {"usdc", "abc"},
          {"usdc", ""},
          {"usdc", "-1"},
          {"usdc", "1e3"},
          {"usdc", "0"},
          {"usdc", "0.000"},
          {"usdc", "0.0000001"},
          {"regent", "0.0000000000000000001"},
          {"token", too_large}
        ] do
      input = %{kind: "pay", asset: asset, amount: amount}
      chain_reads()

      assert {:error, %Ash.Error.Invalid.Unavailable{reason: :invalid_amount}} =
               SubjectWalletActions.prepare(
                 listed.auction.id,
                 wallet,
                 :pay,
                 page_params(input),
                 opts
               ),
             inspect(input)

      route = http(:post, path(listed.id), input, agent)

      assert route.status == 422 and route.body["error"]["code"] == "invalid_amount",
             "#{inspect(input)} answered #{inspect(route.body)}"

      assert tool(agent, "prepare_payment", Map.put(input, :token_id, listed.id)) ==
               {:error, route.body}

      assert chain_reads() == [], inspect(input)
    end
  end

  test "a token the site does not list or show, and an id naming none, are answered alike as no token, before any chain is read",
       %{agent: agent} do
    hidden = token!(kind: :agent)
    {:ok, _hidden} = Autolaunch.hide_auction(hidden.auction, actor: system())
    # The site lists only its own launches, and the chain's Base Memestock ones.
    unlisted = unlisted!()

    answers =
      for id <- [Ecto.UUID.generate(), hidden.id, unlisted.id], input <- [@pay, @sweep] do
        chain_reads()
        route = http(:post, path(id), input, agent)

        assert route.status == 404 and route.body["error"]["code"] == "token_not_found",
               "#{id} answered #{inspect(route.body)}"

        assert chain_reads() == [], id

        assert tool(agent, "prepare_payment", Map.put(input, :token_id, id)) ==
                 {:error, route.body}

        assert chain_reads() == [], id
        route.body
      end

    assert [_one] = Enum.uniq(answers)
    assert documented?(404, "token_not_found")
  end

  test "only the person's own wallets are prepared for: another of theirs is, any other is refused, as is another person's agent naming theirs",
       %{account: account, agent: agent, listed: listed, wallet: wallet} do
    route = http(:post, path(listed.id), Map.put(@pay, :signer, @other), agent)
    assert route.status == 403 and route.body["error"]["code"] == "wrong_signer"

    assert tool(agent, "prepare_payment", Map.merge(@pay, %{token_id: listed.id, signer: @other})) ==
             {:error, route.body}

    # Another of the person's own wallets, named in its checksummed letter case.
    {:ok, bytes} = Address.decode("0xabcdef0123456789abcdef0123456789abcdef01")
    second = Address.checksum(bytes)

    {:ok, _account} =
      Accounts.refresh_verified(account, wallet, [wallet, second], actor: system())

    {:ok, data} = answer(http(:post, path(listed.id), Map.put(@pay, :signer, second), agent))
    assert data["signer"] == Address.normalize!(second)

    # Left out, the wallet they signed in with.
    {:ok, data} = answer(http(:post, path(listed.id), @pay, agent))
    assert data["signer"] == wallet

    # Another person's agent, asking with this person's wallet.
    stranger = paired_agent(TestSupport.register_creator!())
    route = http(:post, path(listed.id), Map.put(@pay, :signer, wallet), stranger)
    assert route.status == 403 and route.body["error"]["code"] == "wrong_signer"
  end

  test "the steps are prepared for the paired agent alone, a connected app calling as it included",
       %{account: account, agent: wallet, listed: listed} do
    {:ok, agent} = Autolaunch.Agents.resolve(wallet)
    app_as_agent = %{agent | connection: %{subject: account.privy_user_id}}
    person = %Human{human_account_id: account.id}
    app = %ConnectedApp{principal: %{subject: account.privy_user_id}}
    input = %{token_id: listed.id, kind: :pay, asset: :usdc, amount: "1"}

    for actor <- [agent, app_as_agent, person, app, %Autolaunch.Actors.System{}, nil] do
      may? = Ash.can?(Ash.ActionInput.for_action(AgentPayment, :prepare, input), actor)
      assert may? == actor in [agent, app_as_agent], "#{inspect(actor)}"
    end
  end

  test "every refusal is reached, named alike on both ways in, in a status and code the contract documents",
       %{agent: agent, listed: listed} do
    hidden = token!(kind: :agent)
    {:ok, _hidden} = Autolaunch.hide_auction(hidden.auction, actor: system())
    unlisted = unlisted!()
    memestock = memestock!()
    id = listed.id
    long = String.duplicate("1", 129)

    cases = [
      {%{}, "nope", @pay, "invalid_request"},
      {%{}, id, Map.put(@pay, :bogus, "x"), "invalid_request"},
      {%{}, id, %{}, "invalid_request"},
      {%{}, id, Map.delete(@pay, :kind), "invalid_request"},
      {%{}, id, Map.delete(@pay, :asset), "invalid_request"},
      {%{}, id, %{@pay | kind: 1}, "invalid_request"},
      {%{}, id, %{@pay | asset: 1}, "invalid_request"},
      {%{}, id, %{@pay | amount: 1}, "invalid_request"},
      {%{}, id, Map.put(@pay, :signer, 1), "invalid_request"},
      # Only a payment or a sweep of the three assets is offered, a payment
      # names its amount and a sweep none, and no field is longer than any it
      # reads.
      {%{}, id, %{@pay | kind: "refund"}, "invalid_request"},
      {%{}, id, %{@pay | asset: "eth"}, "invalid_request"},
      {%{}, id, %{@pay | asset: "subject"}, "invalid_request"},
      {%{}, id, Map.delete(@pay, :amount), "invalid_request"},
      {%{}, id, Map.put(@sweep, :amount, "1"), "invalid_request"},
      {%{}, id, Map.put(@sweep, :amount, ""), "invalid_request"},
      {%{}, id, %{@pay | amount: long}, "invalid_request"},
      {%{}, id, Map.put(@pay, :signer, long), "invalid_request"},
      {%{}, Ecto.UUID.generate(), @pay, "token_not_found"},
      {%{}, hidden.id, @pay, "token_not_found"},
      {%{}, unlisted.id, @pay, "token_not_found"},
      {%{}, id, Map.put(@pay, :signer, @other), "wrong_signer"},
      {%{}, id, Map.put(@pay, :signer, "nope"), "wallet_required"},
      {%{}, id, %{@pay | amount: "abc"}, "invalid_amount"},
      {%{}, id, %{@pay | amount: ""}, "invalid_amount"},
      {%{}, id, %{@pay | amount: "0"}, "invalid_amount"},
      {%{}, id, %{@pay | amount: "0.0000001"}, "invalid_amount"},
      {%{}, memestock.id, @pay, "payment_not_offered"},
      {%{chain: %{treasury: @zero}}, id, @pay, "payment_not_open"},
      {%{payments: %{beneficiary: @other}}, id, @pay, "split_mismatch"},
      {%{payments: %{treasury: @other}}, id, @sweep, "split_mismatch"},
      {%{}, id, %{@pay | amount: "50.000001"}, "amount_above_balance"},
      {%{payments: %{balances: %{subject: 0, usdc: 0, regent: 0}}}, id,
       %{kind: "pay", asset: "token", amount: "1"}, "amount_above_balance"},
      {%{}, id, %{@sweep | asset: "regent"}, "nothing_to_sweep"},
      {%{chain: %{unavailable: true}}, id, @pay, "chain_unavailable"},
      {%{chain: %{unavailable: true}}, id, @sweep, "chain_unavailable"}
    ]

    reached =
      for {arranged, token_id, input, code} <- cases do
        StakeChain.put(arranged[:chain] || %{})
        payments(arranged[:payments] || %{})
        route = http(:post, path(token_id), input, agent)
        named = "#{token_id} #{inspect(input)} on #{inspect(arranged)}"

        assert route.body["error"]["code"] == code, "#{named} answered #{inspect(route.body)}"
        assert route.body["error"]["message"] != ""

        assert tool(agent, "prepare_payment", Map.put(input, :token_id, token_id)) ==
                 {:error, route.body},
               named

        assert documented?(route.status, code), "#{code} at #{route.status}"
        code
      end

    # The site's own fault: a node answering as another chain, as the launch
    # record is read.
    StakeChain.install()
    payments(%{})
    BaseRpcStub.put(%{chain_id: "0x1"})
    route = http(:post, path(id), @pay, agent)
    assert route.status == 503 and route.body["error"]["code"] == "payment_unavailable"
    assert tool(agent, "prepare_payment", Map.put(@pay, :token_id, id)) == {:error, route.body}
    assert documented?(503, "payment_unavailable")

    # An agent nobody paired.
    route = http(:post, path(id), @pay, random_wallet())
    assert route.status == 403 and route.body["error"]["code"] == "agent_not_paired"
    assert documented?(403, "agent_not_paired")

    # Each code the contract lists is reached here, but the account read and
    # prelaunch refusals, each in its own test below.
    assert Enum.sort(Enum.uniq(["agent_not_paired", "payment_unavailable" | reached])) ==
             Enum.sort(
               @codes -- ~w(authentication_required account_unavailable prelaunch_read_only)
             )
  end

  test "switched on, the signed route refuses an unsigned request, an agent nobody paired, another's wallet and an id that is none, each in its own words, and answers a hidden token byte for byte as a missing one",
       %{agent: agent, listed: listed} do
    chain_reads()

    unsigned =
      conn(:post, path(listed.id), Jason.encode!(@pay))
      |> Map.put(:remote_ip, from())
      |> put_req_header("content-type", "application/json")
      |> @endpoint.call([])

    # Refused before the route, in the sign-in's own words, nothing prepared.
    assert unsigned.status == 401
    assert %{"error" => %{"code" => "verification_failed"}} = body = json(unsigned)
    refute Map.has_key?(body, "data")
    assert chain_reads() == []

    unpaired = http(:post, path(listed.id), @pay, random_wallet())
    assert unpaired.status == 403 and unpaired.body["error"]["code"] == "agent_not_paired"

    stranger = http(:post, path(listed.id), Map.put(@pay, :signer, @other), agent)

    assert stranger.status == 403 and
             Map.take(stranger.body["error"], ~w(code message)) == %{
               "code" => "wrong_signer",
               "message" => "That wallet is not one of your person's own wallets."
             }

    for id <- ["nope", "1", Ecto.UUID.generate() <> "0"] do
      malformed = http(:post, path(id), @pay, agent)

      assert malformed.status == 422 and
               Map.take(malformed.body["error"], ~w(code message)) == %{
                 "code" => "invalid_request",
                 "message" =>
                   "Send the token's id as autolaunch_tokens lists it, and in the body kind as pay or sweep, asset as usdc, regent or token, amount for pay only, and signer if you like, each as text."
               },
             "#{id} answered #{inspect(malformed.body)}"
    end

    hidden = token!(kind: :agent)
    {:ok, _hidden} = Autolaunch.hide_auction(hidden.auction, actor: system())

    [hidden_answer, missing_answer] =
      for id <- [hidden.id, Ecto.UUID.generate()], do: signed(:post, path(id), @pay, agent)

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
             Autolaunch.prepare_payment(
               %{token_id: listed.id, kind: :pay, asset: :usdc, amount: "1"},
               actor: unread
             )

    assert documented?(401, "authentication_required")
  end

  test "a paired agent whose person's account cannot be read as the request arrives is refused account_unavailable",
       %{agent: agent, listed: listed} do
    # The person's account is read with its ENS name as the pairing is resolved.
    lose_reads_of("account_ens_identities")
    route = http(:post, path(listed.id), @pay, agent)

    assert route.status == 503 and route.body["error"]["code"] == "account_unavailable",
           inspect(route.body)

    assert documented?(503, "account_unavailable")
  end

  test "a person whose wallet evidence has lapsed, or no longer holds together, is refused wallet_required",
       %{account: account, agent: agent, listed: listed, wallet: wallet} do
    for {primary, addresses} <- [{nil, []}, {nil, [wallet]}, {@other, [wallet]}],
        input <- [@pay, Map.put(@sweep, :signer, wallet)] do
      {:ok, _account} = Accounts.refresh_verified(account, primary, addresses, actor: system())
      named = "#{inspect({primary, addresses})} #{inspect(input)}"
      route = http(:post, path(listed.id), input, agent)

      assert route.status == 409 and route.body["error"]["code"] == "wallet_required",
             "#{named} answered #{inspect(route.body)}"

      assert tool(agent, "prepare_payment", Map.put(input, :token_id, listed.id)) ==
               {:error, route.body},
             named
    end

    assert documented?(409, "wallet_required")
  end

  test "a read that fails, a raise, or a reason nobody named, is logged by kind alone and refused as payment_unavailable alike on both ways in",
       %{agent: agent, listed: listed, wallet: wallet} do
    refused = fn ->
      {{route, tool}, log} =
        with_log(fn ->
          {http(:post, path(listed.id), @pay, agent),
           tool(agent, "prepare_payment", Map.put(@pay, :token_id, listed.id))}
        end)

      assert route.status == 503 and route.body["error"]["code"] == "payment_unavailable",
             inspect(route.body)

      assert tool == {:error, route.body}
      refute log =~ wallet
      log
    end

    # The card's snapshot without the wallet's balances: a fault nobody named,
    # which raises where the payment is planned.
    SubjectChain.put(%{
      snapshot: Map.delete(SubjectWalletFixture.fixture(bound()).snapshot, :balances)
    })

    assert refused.() =~ "agent payment failed: KeyError"
    payments(%{})

    # The token's listing cannot be read: Ash's own error, which names the
    # lost connection.
    lose_reads_of("tokens")

    assert {:error, %Ash.Error.Unknown{errors: [%Ash.Error.Unknown.UnknownError{}]}} =
             Autolaunch.get_listed_token(listed.id, actor: nil)

    assert refused.() =~ "agent payment connection_lost"
    restore_reads_of("tokens")

    # The card's snapshot fails for a reason the review does not name.
    SubjectChain.put(%{unavailable: :wrong_chain})
    assert refused.() =~ "agent payment failed: wrong_chain"

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
        with_log(fn -> AgentPaymentAnswer.send(conn(:post, "/", ""), {:error, error}) end)

      assert answered.status == 503
      assert Jason.decode!(answered.resp_body)["error"]["code"] == "payment_unavailable"
      assert log =~ "agent payment failed"
    end
  end

  test "a launch on another network than the site's Base deployment is the site's own fault: payment_unavailable, logged by kind alone, as the page refuses it",
       %{agent: agent, opts: opts, wallet: wallet} do
    elsewhere = token!(kind: :agent, chain_id: 84_532)

    assert {:error, %Ash.Error.Invalid.Unavailable{reason: :review_network_mismatch}} =
             SubjectWalletActions.prepare(
               elsewhere.auction.id,
               wallet,
               :pay,
               page_params(@pay),
               opts
             )

    {route, log} = with_log(fn -> http(:post, path(elsewhere.id), @pay, agent) end)

    assert route.status == 503 and route.body["error"]["code"] == "payment_unavailable",
           inspect(route.body)

    assert log =~ "agent payment failed: review_network_mismatch"
    refute log =~ wallet

    assert tool(agent, "prepare_payment", Map.put(@pay, :token_id, elsewhere.id)) ==
             {:error, route.body}
  end

  test "each reason the review, the listing, the wallet and the account give has one code, which both ways in answer in a status the contract documents; anything else is payment_unavailable" do
    mismatches =
      ~w(splitter_subject_mismatch splitter_usdc_mismatch splitter_regent_mismatch splitter_treasury_mismatch receiver_splitter_mismatch receiver_subject_mismatch receiver_usdc_mismatch receiver_regent_mismatch receiver_treasury_mismatch receiver_not_canonical)a

    codes =
      Map.merge(
        %{
          authentication_required: :authentication_required,
          wallet_required: :wallet_required,
          wrong_signer: :wrong_signer,
          token_not_listed: :token_not_found,
          invalid_amount: :invalid_amount,
          test_chain: :payment_not_offered,
          subject_not_found: :payment_not_offered,
          subject_not_on_base: :payment_not_offered,
          subject_token_unavailable: :payment_not_open,
          subject_splitter_unavailable: :payment_not_open,
          subject_treasury_unavailable: :payment_not_open,
          canonical_receiver_unavailable: :payment_not_open,
          amount_above_balance: :amount_above_balance,
          nothing_to_sweep: :nothing_to_sweep,
          chain_unavailable: :chain_unavailable
        },
        Map.new(mismatches, &{&1, :split_mismatch})
      )

    assert Map.new(codes, fn {reason, _code} -> {reason, AgentPayment.code(reason)} end) == codes

    # A launch the site cannot read, a Base deployment on another network than
    # the launch's, and every reason the card names that no paired agent's
    # payment reaches, are the site's.
    for unexpected <- [
          :payment_unavailable,
          :subject_unavailable,
          :review_network_mismatch,
          :unsupported_asset,
          :unknown_action,
          :invalid_address,
          :session_unavailable,
          :wrong_chain,
          {:closed, :econnreset},
          "text",
          nil,
          %{reason: :x}
        ],
        do: assert(AgentPayment.code(unexpected) == :payment_unavailable)

    for code <- Enum.uniq([:invalid_request, :payment_unavailable | Map.values(codes)]) do
      answered = AgentPaymentAnswer.refuse(conn(:post, "/", ""), code)
      body = Jason.decode!(answered.resp_body)
      assert body == plain(AgentPaymentAnswer.body(code)), "#{code}"
      assert body["error"]["code"] == Atom.to_string(code)
      assert documented?(answered.status, body["error"]["code"]), "#{code} at #{answered.status}"
    end
  end

  test "in prelaunch read-only mode the tool is not listed or run, and the route waits",
       %{agent: agent, listed: listed} do
    Application.put_env(:autolaunch, :prelaunch_read_only, true)

    route = http(:post, path(listed.id), @pay, agent)
    assert route.status == 503 and route.body["error"]["code"] == "prelaunch_read_only"
    assert documented?(503, "prelaunch_read_only")

    refute "prepare_payment" in tool_names(agent)

    assert %{"error" => _} =
             json(mcp(agent, call("prepare_payment", Map.put(@pay, :token_id, listed.id))))
  end

  test "switched on a paired agent lists the tool as read-only and not idempotent; off, it is not listed, and a call to it is answered as one to no tool",
       %{agent: agent, listed: listed} do
    assert [%{"annotations" => %{"readOnlyHint" => true} = hints}] =
             for(%{"name" => "prepare_payment"} = tool <- listed(agent), do: tool)

    # Each payment's steps carry a new random reference, so a second call with
    # the same input prepares a different payment.
    refute Map.has_key?(hints, "idempotentHint")

    Application.put_env(:autolaunch, :agent_payments, :off)
    refute "prepare_payment" in tool_names(agent)

    # Off, a call, well formed or not, is answered exactly as one to a tool that
    # does not exist, in no words of agent payments.
    for arguments <- [
          %{"input" => Map.put(@pay, :token_id, listed.id)},
          %{"input" => %{token_id: listed.id, kind: "sweep", asset: "token", signer: @other}},
          %{"input" => "not an object"},
          %{"input" => %{bogus: "x"}},
          %{"input" => %{token_id: 1, kind: false}},
          %{"input" => %{}},
          %{},
          "not an object"
        ] do
      called =
        mcp(agent, rpc("tools/call", %{"name" => "prepare_payment", "arguments" => arguments}))

      nothing =
        mcp(agent, rpc("tools/call", %{"name" => "no_such_tool", "arguments" => arguments}))

      said =
        called.resp_body
        |> IO.iodata_to_binary()
        |> String.replace("prepare_payment", "no_such_tool")

      assert {called.status, said} == {nothing.status, IO.iodata_to_binary(nothing.resp_body)},
             inspect(arguments)

      refute said =~ ~r/pay|sweep|split|token|signer|wallet|steps|amount|asset/i
    end
  end

  # Whether the contract documents `code` for the route answering `status`.
  defp documented?(status, code) do
    response = get_in(@contract, ["paths", @path, "post", "responses", Integer.to_string(status)])
    code in @codes and is_map(response) and response["description"] =~ ~r/\b#{code}\b/
  end

  defp path(token_id),
    do: "/api/agent/v1/tokens/#{URI.encode(token_id, &URI.char_unreserved?/1)}/payment/steps"

  # The card's one snapshot, bound to `Autolaunch.StakeChain`'s Revstake
  # launch, with a quarter of the token's supply staked, and `overrides` over
  # it.
  defp bound(overrides \\ %{}) do
    Map.merge(
      %{
        token: StakeChain.subject(),
        splitter: StakeChain.splitter(),
        receiver: StakeChain.receiver(),
        treasury: StakeChain.treasury(),
        total_staked: 25_000_000_000 * @unit
      },
      overrides
    )
  end

  # The card's snapshot from now on: `overrides` over the bound one.
  defp payments(overrides), do: SubjectChain.put(SubjectWalletFixture.fixture(bound(overrides)))

  # The params the token page's payment card sends for the same input.
  defp page_params(%{asset: asset} = input) do
    params = %{"asset" => if(asset == "token", do: "subject", else: asset)}
    if Map.has_key?(input, :amount), do: Map.put(params, "amount", input.amount), else: params
  end

  # A graduated launch's token the site lists, on Base unless `fields` names
  # another chain, with its auction loaded as its page reads it.
  defp token!(fields) do
    auction =
      [
        chain_id: 8453,
        state: :graduated,
        title: "Payment token",
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

  # The site's graduated Memestock launch on Base, `Autolaunch.StakeChain`'s.
  defp memestock!,
    do:
      token!(
        kind: :stocks,
        address: StakeChain.auction(),
        quote_token_address: StakeChain.stock(),
        quote_token_symbol: "AAPLc",
        quote_token_decimals: 8
      )

  # The site's graduated launch on Robinhood Chain.
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

  defp step(name, to, data),
    do: %{
      "kind" => "transaction",
      "step" => name,
      "to" => Address.normalize!(to),
      "data" => BuilderCode.append(data),
      "value" => "0x0"
    }

  # A review as it reads whichever reference its payment drew: the payment's
  # reference word zeroed, and its facts' copy of it left out.
  defp referenceless(review) do
    review
    |> Map.update!("steps", fn steps -> Enum.map(steps, &referenceless_step/1) end)
    |> put_in(["facts", "payment_reference"], nil)
  end

  defp referenceless_step(%{"step" => "action", "data" => "0x5e5571ac" <> _call} = step),
    do: %{step | "data" => zeroed(step["data"], 2)}

  defp referenceless_step(step), do: step

  # Calldata with its argument word `index` zeroed.
  defp zeroed("0x" <> hex, index) do
    before = 8 + 64 * index
    <<head::binary-size(^before), _word::binary-size(64), rest::binary>> = hex
    "0x" <> head <> String.duplicate("0", 64) <> rest
  end

  # Every Base read since the last call, from this test's mailbox: Base's
  # double tells each request, with the contract an `eth_call` asks.
  defp chain_reads(reads \\ []) do
    receive do
      {:rpc, "eth_call", [%{to: to}, _block]} ->
        chain_reads([{"eth_call", Address.normalize!(to)} | reads])

      {:rpc, method, _params} ->
        chain_reads([method | reads])
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
