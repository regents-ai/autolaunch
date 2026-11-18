defmodule AutolaunchWeb.AgentFinishTest do
  @moduledoc """
  Agent finishes on a paired agent's two ways in: the signed route the browser
  tool calls and the hosted MCP tool give one answer for one input, refusals
  in the same code and words.

  The finish step is the auction page's, read by the one rule the page's
  Finish button follows (`Autolaunch.FinishActions.read/1`), for a Revstake
  and a Memestock auction on Base and a Memestock auction on Robinhood Chain.
  It is refused as `finish_not_open`, naming the block finishing opens at,
  while even the launchpad clock's next block is before the migration block,
  and comes back from one block before it. Only the person's own wallets are
  prepared for, and only for the agent paired with them, while the person has
  a verified wallet; an auction the site does not list or show is answered as
  no auction, before any chain is read. Every refusal is reached and named,
  with a status and code the contract documents, and every reason has one
  code. A launchpad that holds no launch for a listed auction, a read that
  raises, or a reason nobody named, is refused as `finish_unavailable`; an
  auction on a chain no deployment description names, as `chain_unavailable`
  with nothing read, logged once. The signed route refuses an unsigned or
  unpaired request, another's wallet and an id that is none in their own
  words, and answers a hidden auction byte for byte as a missing one. Off, or
  in prelaunch read-only mode, the tool is not listed or run, and off a call
  to it is answered as one to a tool that does not exist.

  Base is `Autolaunch.BaseRpcStub` answering the launch's record as each case
  names it, and Robinhood Chain is `Autolaunch.RobinhoodBidChain`; the two
  share the site's one chain client, so each case reads through the chain its
  auction runs on. The sign-in service is stubbed: it vouches for the wallet a
  request names.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1, system: 0]
  import Autolaunch.DatabaseFaults, only: [lose_reads_of: 1, restore_reads_of: 1]
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Plug.Test, only: [conn: 3]

  alias Autolaunch.Accounts.RequestRateLimiter
  alias Autolaunch.Actors.{Agent, ConnectedApp, Human}
  alias Autolaunch.AgentFinish.Refused
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi
  alias AutolaunchWeb.AgentFinishAnswer
  alias RegentChain.{Address, BuilderCode}

  alias Autolaunch.{
    Accounts,
    AgentFinish,
    BaseRpcStub,
    FinishActions,
    Lab,
    LabAbi,
    RobinhoodBidChain,
    TestSupport
  }

  @moduletag :capture_log
  @contract "../../contracts/agent-finish.openapiv3.yaml"
            |> Path.expand(__DIR__)
            |> YamlElixir.read_from_file!()
  @codes get_in(
           @contract,
           ~w(components schemas AgentFinishError properties error properties code enum)
         )
  @schemas @contract["components"]["schemas"]
  @path "/api/agent/v1/auctions/{auction_id}/finish/steps"
  @other "0x2222222222222222222222222222222222222222"
  @running 1
  @graduated 2
  @failed 3
  # The block a Base launch finishes from, and a Memestock launch's id there.
  @migration_block 1_000
  @launch_id 4
  # The rollup block Robinhood Chain's launch finishes from, and its launch's id
  # (`Autolaunch.RobinhoodBidChain`).
  @robinhood_migration 95
  @robinhood_launch_id 1

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

    for key <- [:agent_finish, :prelaunch_read_only], do: keep_env(key)
    Application.put_env(:autolaunch, :agent_finish, :on)
    # Past the prelaunch gate, which refuses wallet steps until the site opens.
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    RobinhoodBidChain.install()
    BaseRpcStub.install(:autolaunch_lab_http_client, &base_answer/2)
    base([])

    %{
      agent: paired_agent(account),
      listed: auction!(kind: :agent),
      robinhood:
        auction!(
          chain_id: RobinhoodBidChain.chain_id(),
          kind: :stocks,
          address: RobinhoodBidChain.auction()
        )
    }
  end

  test "the finish step is the auction page's, for a Revstake and a Memestock auction on Base and a Memestock auction on Robinhood Chain, alike on both ways in",
       %{agent: agent, robinhood: robinhood, wallet: wallet} do
    base_cases =
      for kind <- [:agent, :stocks], version <- [:v2, :v3] do
        auction = auction!(kind: kind, contracts_version: version)

        {auction, fn -> base(version: version, auction: auction.auction_address) end, 8453,
         @migration_block - 1, @migration_block}
      end

    robinhood_case =
      {robinhood, fn -> robinhood([]) end, RobinhoodBidChain.chain_id(), 100,
       @robinhood_migration}

    for {auction, arrange, chain_id, block, opens_at} <- base_cases ++ [robinhood_case] do
      arrange.()
      named = "#{auction.kind} #{auction.contracts_version} on #{chain_id}"
      {:ok, page} = FinishActions.read(auction)
      {:ok, data} = answer(http(:post, path(auction.id), %{}, agent))

      assert tool(agent, "prepare_finish", %{auction_id: auction.id}) == {:ok, data}, named
      assert data["steps"] == plain(page.steps), named
      assert data["steps"] == [finish_step(auction)], named
      assert data["chain"] == plain(page.chain), named
      assert data["chain"]["chain_id"] == chain_id, named

      assert %{"kind" => "finish", "signer" => ^wallet, "block" => ^block} = data
      assert data["block"] == page.block
      assert data["facts"] == %{"migration_block" => opens_at, "clock" => opens_at - 1}, named
      assert data["auction"] == %{"id" => auction.id, "address" => auction.auction_address}
      assert Enum.sort(Map.keys(data)) == Enum.sort(@schemas["AgentFinishSteps"]["required"])
    end
  end

  # The page's button is held by the same rule.
  test "two blocks before the migration block the finish is refused as finish_not_open naming that block; from one block before, the step comes back, on Base and Robinhood Chain",
       %{agent: agent, listed: listed, robinhood: robinhood} do
    for {auction, arrange, opens_at} <- [
          {listed, &base(latest: &1), @migration_block},
          {robinhood, &robinhood(clock: &1), @robinhood_migration}
        ] do
      input = %{auction_id: auction.id}

      # The clock never runs back: a finish sent two blocks before lands one
      # block before at the earliest, which the launchpad refuses.
      for clock <- [1, opens_at - 2] do
        arrange.(clock)
        route = http(:post, path(auction.id), %{}, agent)
        named = "#{auction.chain_id} clock #{clock} answered #{inspect(route.body)}"

        assert route.status == 409 and route.body["error"]["code"] == "finish_not_open", named
        assert route.body["error"]["message"] =~ ~r/\bblock #{opens_at}\b/, named
        refute Map.has_key?(route.body, "data")
        assert tool(agent, "prepare_finish", input) == {:error, route.body}, named
        assert documented?(409, "finish_not_open")

        assert {:ok, %{blocked: :finish_not_open, migration_block: ^opens_at}} =
                 FinishActions.read(auction)
      end

      # One block before, the finish may land at the migration block, which
      # takes it; from the migration block on, the launchpad takes it.
      for clock <- [opens_at - 1, opens_at, opens_at + 1] do
        arrange.(clock)

        assert {:ok, %{"steps" => [%{"step" => "finish"}], "facts" => %{"clock" => ^clock}}} =
                 answer(http(:post, path(auction.id), %{}, agent))

        assert {:ok, %{blocked: nil}} = FinishActions.read(auction)
      end
    end
  end

  test "a finished auction is refused as auction_finished with no step, as the page says it is finished, on Base and on Robinhood Chain",
       %{agent: agent, listed: listed, robinhood: robinhood} do
    for lifecycle <- [@graduated, @failed],
        {auction, arrange} <- [
          {listed, fn -> base(lifecycle: lifecycle) end},
          {robinhood, fn -> robinhood(lifecycle: lifecycle) end}
        ] do
      arrange.()
      route = http(:post, path(auction.id), %{}, agent)
      named = "#{auction.chain_id} lifecycle #{lifecycle} answered #{inspect(route.body)}"

      assert route.status == 409 and route.body["error"]["code"] == "auction_finished", named
      refute Map.has_key?(route.body, "data")
      assert tool(agent, "prepare_finish", %{auction_id: auction.id}) == {:error, route.body}
      assert {:ok, %{blocked: :auction_finished}} = FinishActions.read(auction)
    end
  end

  test "an auction the site does not list or show, and an id naming none, are answered alike as no auction, before any chain is read",
       %{agent: agent, robinhood: robinhood} do
    hidden = auction!(kind: :agent)
    {:ok, _hidden} = Autolaunch.hide_auction(hidden, actor: system())
    {:ok, _hidden} = Autolaunch.hide_auction(robinhood, actor: system())

    unlisted = [
      # The site lists only its own launches, and the chain's Base Memestock ones.
      auction!(kind: :agent, origin: :chain),
      auction!(chain_id: RobinhoodBidChain.chain_id(), kind: :stocks, origin: :chain)
    ]

    answers =
      for {id, arrange} <-
            [{Ecto.UUID.generate(), &base/1}, {hidden.id, &base/1}, {robinhood.id, &robinhood/1}] ++
              for(auction <- unlisted, do: {auction.id, &base/1}) do
        arrange.([])
        chain_reads()
        route = http(:post, path(id), %{}, agent)

        assert route.status == 404 and route.body["error"]["code"] == "auction_not_found",
               "#{id} answered #{inspect(route.body)}"

        assert chain_reads() == [], id
        assert tool(agent, "prepare_finish", %{auction_id: id}) == {:error, route.body}
        assert chain_reads() == [], id
        route.body
      end

    assert [_one] = Enum.uniq(answers)
    assert documented?(404, "auction_not_found")
  end

  test "only the person's own wallets are prepared for: another of theirs is, any other is refused, as is another person's agent naming theirs",
       %{account: account, agent: agent, listed: listed, wallet: wallet} do
    route = http(:post, path(listed.id), %{signer: @other}, agent)
    assert route.status == 403 and route.body["error"]["code"] == "wrong_signer"

    assert tool(agent, "prepare_finish", %{auction_id: listed.id, signer: @other}) ==
             {:error, route.body}

    # Another of the person's own wallets, named in its checksummed letter case.
    {:ok, bytes} = Address.decode("0xabcdef0123456789abcdef0123456789abcdef01")
    second = Address.checksum(bytes)

    {:ok, _account} =
      Accounts.refresh_verified(account, wallet, [wallet, second], actor: system())

    {:ok, data} = answer(http(:post, path(listed.id), %{signer: second}, agent))
    assert tool(agent, "prepare_finish", %{auction_id: listed.id, signer: second}) == {:ok, data}
    assert Address.equal?(data["signer"], second)
    assert data["steps"] == [finish_step(listed)]

    # Another person's agent, asking with this person's wallet.
    stranger = paired_agent(TestSupport.register_creator!())
    route = http(:post, path(listed.id), %{signer: wallet}, stranger)
    assert route.status == 403 and route.body["error"]["code"] == "wrong_signer"
  end

  test "the step is prepared for the paired agent alone, a connected app calling as it included",
       %{account: account, agent: wallet, listed: listed} do
    {:ok, agent} = Autolaunch.Agents.resolve(wallet)
    app_as_agent = %{agent | connection: %{subject: account.privy_user_id}}
    person = %Human{human_account_id: account.id}
    app = %ConnectedApp{principal: %{subject: account.privy_user_id}}

    for actor <- [agent, app_as_agent, person, app, %Autolaunch.Actors.System{}, nil] do
      may? =
        Ash.can?(
          Ash.ActionInput.for_action(AgentFinish, :prepare, %{auction_id: listed.id}),
          actor
        )

      assert may? == actor in [agent, app_as_agent], "#{inspect(actor)}"
    end
  end

  test "every refusal is reached, named alike on both ways in, in a status and code the contract documents",
       %{agent: agent, listed: listed, robinhood: robinhood} do
    hidden = auction!(kind: :agent)
    {:ok, _hidden} = Autolaunch.hide_auction(hidden, actor: system())
    unlisted = auction!(kind: :agent, origin: :chain)
    id = listed.id

    cases = [
      {&base/1, [], "nope", %{}, "invalid_request"},
      {&base/1, [], id, %{bogus: "x"}, "invalid_request"},
      {&base/1, [], id, %{signer: 1}, "invalid_request"},
      {&base/1, [], Ecto.UUID.generate(), %{}, "auction_not_found"},
      {&base/1, [], hidden.id, %{}, "auction_not_found"},
      {&base/1, [], unlisted.id, %{}, "auction_not_found"},
      {&base/1, [], id, %{signer: @other}, "wrong_signer"},
      {&base/1, [], id, %{signer: "nope"}, "wallet_required"},
      {&base/1, [latest: @migration_block - 2], id, %{}, "finish_not_open"},
      {&robinhood/1, [clock: @robinhood_migration - 2], robinhood.id, %{}, "finish_not_open"},
      {&base/1, [lifecycle: @graduated], id, %{}, "auction_finished"},
      {&robinhood/1, [lifecycle: @failed], robinhood.id, %{}, "auction_finished"},
      {&base/1, [answers?: false], id, %{}, "chain_unavailable"},
      {&robinhood/1, [unreadable: "eth_call"], robinhood.id, %{}, "chain_unavailable"},
      {&robinhood/1, [chain_id: "0x2105"], robinhood.id, %{}, "chain_unavailable"},
      # The site's own fault: the launchpad holds no launch for the listed auction.
      {&base/1, [lifecycle: 0], id, %{}, "finish_unavailable"},
      {&robinhood/1, [lifecycle: 0], robinhood.id, %{}, "finish_unavailable"}
    ]

    reached =
      for {arrange, chain, auction_id, input, code} <- cases do
        arrange.(chain)
        route = http(:post, path(auction_id), input, agent)
        named = "#{auction_id} #{inspect(input)} on #{inspect(chain)}"

        assert route.body["error"]["code"] == code, "#{named} answered #{inspect(route.body)}"
        assert route.body["error"]["message"] != ""

        assert tool(agent, "prepare_finish", Map.put(input, :auction_id, auction_id)) ==
                 {:error, route.body},
               named

        assert documented?(route.status, code), "#{code} at #{route.status}"
        code
      end

    # An agent nobody paired.
    base([])
    route = http(:post, path(id), %{}, random_wallet())
    assert route.status == 403 and route.body["error"]["code"] == "agent_not_paired"
    assert documented?(403, "agent_not_paired")

    # Each code the contract lists is reached here, but the account read and
    # prelaunch refusals, each in its own test below.
    assert Enum.sort(Enum.uniq(["agent_not_paired" | reached])) ==
             Enum.sort(
               @codes -- ~w(authentication_required account_unavailable prelaunch_read_only)
             )
  end

  # A listed auction whose launchpad holds no launch can only come of the
  # site's own records or descriptions, which no agent can mend.
  test "a launchpad holding no launch for a listed auction is refused as finish_unavailable alike on both ways in, logged as launch_not_found, as the page reads no launch",
       %{agent: agent, listed: listed, robinhood: robinhood, wallet: wallet} do
    stocks = auction!(kind: :stocks)

    cases = [
      # Revstake's strategy answers an all-zero distribution for an address
      # that is no auction of its own, and no lifecycle names 7.
      {"Revstake lifecycle 0", listed, fn -> base(lifecycle: 0) end},
      {"Revstake lifecycle 7", listed, fn -> base(lifecycle: 7) end},
      # A Memestock launchpad numbers its launches from 1 and answers 0 for an
      # address that is no auction of its own.
      {"Memestock launch id 0", stocks,
       fn -> base(launch_id: 0, auction: stocks.auction_address) end},
      {"Memestock record of another auction", stocks, fn -> base(auction: @other) end},
      {"Memestock lifecycle 0", stocks,
       fn -> base(lifecycle: 0, auction: stocks.auction_address) end},
      {"Memestock lifecycle 7", stocks,
       fn -> base(lifecycle: 7, auction: stocks.auction_address) end},
      {"Robinhood launch id 0", robinhood, fn -> robinhood(launch_id: 0) end},
      {"Robinhood lifecycle 0", robinhood, fn -> robinhood(lifecycle: 0) end},
      {"Robinhood lifecycle 7", robinhood, fn -> robinhood(lifecycle: 7) end}
    ]

    for {named, auction, arrange} <- cases do
      arrange.()
      assert FinishActions.read(auction) == {:error, :launch_not_found}, named

      {{route, tool}, log} =
        with_log(fn ->
          {http(:post, path(auction.id), %{}, agent),
           tool(agent, "prepare_finish", %{auction_id: auction.id})}
        end)

      assert route.status == 503 and route.body["error"]["code"] == "finish_unavailable",
             "#{named} answered #{inspect(route.body)}"

      assert tool == {:error, route.body}, named
      assert log =~ "agent finish failed: launch_not_found", named
      refute log =~ wallet
    end
  end

  # The deployment descriptions are loaded as the site starts and hold while it
  # runs, so an auction on a chain none of them names stays undescribed.
  test "a listed auction on a chain no deployment description names is refused as chain_unavailable alike on both ways in, nothing read from any chain, the site's fault logged once",
       %{agent: agent} do
    undescribed = auction!(chain_id: 1, kind: :agent)
    logged = {FinishActions, :undescribed, 1, :agent, :v2, :chain_not_described}
    :persistent_term.erase(logged)
    on_exit(fn -> :persistent_term.erase(logged) end)
    chain_reads()

    {answers, log} =
      with_log(fn ->
        for _read <- 1..2 do
          {http(:post, path(undescribed.id), %{}, agent),
           tool(agent, "prepare_finish", %{auction_id: undescribed.id}),
           FinishActions.read(undescribed)}
        end
      end)

    for {route, tool, read} <- answers do
      assert route.status == 503 and route.body["error"]["code"] == "chain_unavailable",
             inspect(route.body)

      assert tool == {:error, route.body}
      assert read == {:error, :chain_unavailable}
    end

    assert chain_reads() == []

    assert [_once] =
             Regex.scan(~r/no launchpad is described for agent v2 auctions on chain 1\b/, log)
  end

  test "switched on, the signed route refuses an unsigned request, an agent nobody paired, another's wallet and an id that is none, each in its own words, and answers a hidden auction byte for byte as a missing one",
       %{agent: agent, listed: listed} do
    chain_reads()

    unsigned =
      conn(:post, path(listed.id), Jason.encode!(%{}))
      |> Map.put(:remote_ip, from())
      |> put_req_header("content-type", "application/json")
      |> @endpoint.call([])

    # Refused before the route, in the sign-in's own words, nothing prepared.
    assert unsigned.status == 401
    assert %{"error" => %{"code" => "verification_failed"}} = body = json(unsigned)
    refute Map.has_key?(body, "data")
    assert chain_reads() == []

    unpaired = http(:post, path(listed.id), %{}, random_wallet())
    assert unpaired.status == 403 and unpaired.body["error"]["code"] == "agent_not_paired"

    stranger = http(:post, path(listed.id), %{signer: @other}, agent)

    assert stranger.status == 403 and
             Map.take(stranger.body["error"], ~w(code message)) == %{
               "code" => "wrong_signer",
               "message" => "That wallet is not one of your person's own wallets."
             }

    for id <- ["nope", "1", Ecto.UUID.generate() <> "0"] do
      malformed = http(:post, path(id), %{}, agent)

      assert malformed.status == 422 and
               Map.take(malformed.body["error"], ~w(code message)) == %{
                 "code" => "invalid_request",
                 "message" =>
                   "Send the auction's id as autolaunch_auctions lists it, and only signer in the body, as text."
               },
             "#{id} answered #{inspect(malformed.body)}"
    end

    hidden = auction!(kind: :agent)
    {:ok, _hidden} = Autolaunch.hide_auction(hidden, actor: system())

    [hidden_answer, missing_answer] =
      for id <- [hidden.id, Ecto.UUID.generate()], do: signed(:post, path(id), %{}, agent)

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
             Autolaunch.prepare_finish(%{auction_id: listed.id}, actor: unread)

    assert documented?(401, "authentication_required")
  end

  test "a paired agent whose person's account cannot be read as the request arrives is refused account_unavailable",
       %{agent: agent, listed: listed} do
    # The person's account is read with its ENS name as the pairing is resolved.
    lose_reads_of("account_ens_identities")
    route = http(:post, path(listed.id), %{}, agent)

    assert route.status == 503 and route.body["error"]["code"] == "account_unavailable",
           inspect(route.body)

    assert documented?(503, "account_unavailable")
  end

  test "a person whose wallet evidence has lapsed, or no longer holds together, is refused wallet_required",
       %{account: account, agent: agent, listed: listed, wallet: wallet} do
    # Lapsed: no primary wallet and none listed, as a sign-in that finds no
    # linked wallet leaves it. Not holding together: wallets listed but no
    # primary among them.
    for {primary, addresses} <- [{nil, []}, {nil, [wallet]}, {@other, [wallet]}],
        input <- [%{}, %{signer: wallet}] do
      {:ok, _account} = Accounts.refresh_verified(account, primary, addresses, actor: system())
      named = "#{inspect({primary, addresses})} #{inspect(input)}"
      route = http(:post, path(listed.id), input, agent)

      assert route.status == 409 and route.body["error"]["code"] == "wallet_required",
             "#{named} answered #{inspect(route.body)}"

      assert tool(agent, "prepare_finish", Map.put(input, :auction_id, listed.id)) ==
               {:error, route.body},
             named
    end

    assert documented?(409, "wallet_required")
  end

  test "the route spends the person's one budget of 120 signed requests a minute",
       %{agent: agent, listed: listed} do
    # Requests that might straddle two minutes start in the next one.
    {:ok, %{reset: left}} = RequestRateLimiter.admit({"minute", make_ref()}, 1, 60)
    if left < 5, do: Process.sleep(left * 1000)

    for remaining <- [119, 118] do
      answered = signed(:post, path(listed.id), %{bogus: "x"}, agent)
      assert answered.status == 422
      assert [budget] = get_resp_header(answered, "ratelimit")
      assert budget =~ ~s("agent";r=#{remaining}), budget
    end
  end

  test "a read that fails, a raise, or a reason nobody named, is logged by kind alone and refused as finish_unavailable alike on both ways in",
       %{agent: agent, listed: listed, robinhood: robinhood, wallet: wallet} do
    refused = fn auction ->
      {{route, tool}, log} =
        with_log(fn ->
          {http(:post, path(auction.id), %{}, agent),
           tool(agent, "prepare_finish", %{auction_id: auction.id})}
        end)

      assert route.status == 503 and route.body["error"]["code"] == "finish_unavailable",
             inspect(route.body)

      assert tool == {:error, route.body}
      refute log =~ wallet
      log
    end

    # The site's Robinhood deployment description as it is held, naming none of
    # its contracts: a fault nobody named, which raises where the read reads one.
    robinhood([])
    {:ok, config} = RobinhoodLab.current()
    held = {RobinhoodLab, config.path}
    on_exit(fn -> :persistent_term.erase(held) end)
    :persistent_term.put(held, %{config | addresses: %{}})
    assert refused.(robinhood) =~ "agent finish failed: KeyError"
    :persistent_term.erase(held)

    # The auction's listing cannot be read: Ash's own error, which names the
    # lost connection.
    base([])
    lose_reads_of("auctions")

    assert {:error, %Ash.Error.Unknown{errors: [%Ash.Error.Unknown.UnknownError{}]}} =
             Autolaunch.get_listed_auction(listed.id, actor: nil)

    assert refused.(listed) =~ "agent finish connection_lost"
    restore_reads_of("auctions")

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
        with_log(fn -> AgentFinishAnswer.send(conn(:post, "/", ""), {:error, error}) end)

      assert answered.status == 503
      assert Jason.decode!(answered.resp_body)["error"]["code"] == "finish_unavailable"
      assert log =~ "agent finish failed"
    end
  end

  test "each reason the read, the listing, the wallet and the account give has one code, which both ways in answer in a status the contract documents; anything else is finish_unavailable" do
    codes = %{
      authentication_required: :authentication_required,
      wallet_required: :wallet_required,
      wrong_signer: :wrong_signer,
      auction_not_listed: :auction_not_found,
      auction_finished: :auction_finished,
      chain_unavailable: :chain_unavailable,
      launch_not_found: :finish_unavailable
    }

    assert Map.new(codes, fn {reason, _code} -> {reason, AgentFinish.code(reason)} end) == codes

    for unexpected <- [:unnamed_reason, {:closed, :econnreset}, "text", nil, %{reason: :x}],
        do: assert(AgentFinish.code(unexpected) == :finish_unavailable)

    refusals =
      [Refused.exception(reason: :finish_not_open, opens_at: @robinhood_migration)] ++
        for code <- Enum.uniq([:invalid_request, :finish_unavailable | Map.values(codes)]),
            do: Refused.exception(reason: code)

    for refused <- refusals do
      answered = AgentFinishAnswer.refuse(conn(:post, "/", ""), refused)
      body = Jason.decode!(answered.resp_body)
      assert body == plain(AgentFinishAnswer.body(refused)), "#{refused.reason}"
      assert body["error"]["code"] == Atom.to_string(refused.reason)

      assert documented?(answered.status, body["error"]["code"]),
             "#{refused.reason} at #{answered.status}"
    end
  end

  test "in prelaunch read-only mode the tool is not listed or run, and the route waits",
       %{agent: agent, listed: listed} do
    Application.put_env(:autolaunch, :prelaunch_read_only, true)

    route = http(:post, path(listed.id), %{}, agent)
    assert route.status == 503 and route.body["error"]["code"] == "prelaunch_read_only"
    assert documented?(503, "prelaunch_read_only")

    refute "prepare_finish" in tool_names(agent)
    assert %{"error" => _} = json(mcp(agent, call("prepare_finish", %{auction_id: listed.id})))
  end

  test "switched on a paired agent lists the tool as read-only; off, it is not listed, and a call to it is answered as one to no tool",
       %{agent: agent, listed: listed} do
    assert [%{"annotations" => %{"readOnlyHint" => true}}] =
             for(%{"name" => "prepare_finish"} = tool <- listed(agent), do: tool)

    Application.put_env(:autolaunch, :agent_finish, :off)
    refute "prepare_finish" in tool_names(agent)

    # Off, a call, well formed or not, is answered exactly as one to a tool that
    # does not exist, in no words of agent finishes.
    for arguments <- [
          %{"input" => %{auction_id: listed.id}},
          %{"input" => %{auction_id: listed.id, signer: @other}},
          %{"input" => "not an object"},
          %{"input" => %{bogus: "x"}},
          %{"input" => %{auction_id: 1, signer: false}},
          %{"input" => %{}},
          %{},
          "not an object"
        ] do
      called =
        mcp(agent, rpc("tools/call", %{"name" => "prepare_finish", "arguments" => arguments}))

      nothing =
        mcp(agent, rpc("tools/call", %{"name" => "no_such_tool", "arguments" => arguments}))

      said =
        called.resp_body
        |> IO.iodata_to_binary()
        |> String.replace("prepare_finish", "no_such_tool")

      assert {called.status, said} == {nothing.status, IO.iodata_to_binary(nothing.resp_body)},
             inspect(arguments)

      refute said =~ ~r/finish|auction|signer|wallet|steps|migrat/i
    end
  end

  # Whether the contract documents `code` for the route answering `status`.
  defp documented?(status, code) do
    response = get_in(@contract, ["paths", @path, "post", "responses", Integer.to_string(status)])
    code in @codes and is_map(response) and response["description"] =~ ~r/\b#{code}\b/
  end

  defp path(auction_id),
    do: "/api/agent/v1/auctions/#{URI.encode(auction_id, &URI.char_unreserved?/1)}/finish/steps"

  # An ended auction the site lists, on Base unless `fields` names another chain.
  defp auction!(fields) do
    [chain_id: 8453, state: :ended, title: "Finish auction", symbol: "FIN"]
    |> Keyword.merge(fields)
    |> TestSupport.project_auction()
  end

  # Base from now on, `changes` over the defaults: a launch of `version` still
  # running (`lifecycle`), read at the latest block `latest`, one block before
  # its migration block, the Memestock launchpad's `launch_id` for the auction
  # and its record naming the auction at `auction`.
  defp base(changes) do
    Application.put_env(:autolaunch, :autolaunch_lab_http_client, BaseRpcStub)

    state =
      Map.merge(
        %{
          latest: @migration_block - 1,
          lifecycle: @running,
          version: :v2,
          answers?: true,
          launch_id: @launch_id,
          auction: "0x0"
        },
        Map.new(changes)
      )

    latest = %{
      "number" => "0x" <> Integer.to_string(state.latest, 16),
      "hash" => BaseRpcStub.safe_hash(),
      "timestamp" => "0x6700"
    }

    BaseRpcStub.put(Map.put(state, :blocks, %{"latest" => latest}))
  end

  # Robinhood Chain from now on, `changes` over its defaults: by default its
  # clock one rollup block before the launch's migration block.
  defp robinhood(changes) do
    Application.put_env(:autolaunch, :autolaunch_lab_http_client, RobinhoodBidChain)
    RobinhoodBidChain.put(Keyword.merge([clock: @robinhood_migration - 1], changes))
  end

  # Base's answer to a launch's record: the Revstake strategy's distribution of
  # the auction, or the Memestock launchpad's launch id and launch, each holding
  # the state's lifecycle and the migration block.
  defp base_answer(_call, %{answers?: false}), do: :unavailable

  defp base_answer(%{data: data}, state) do
    "0x" <> auction = state.auction

    held = %{
      lifecycle: state.lifecycle,
      migration_block: @migration_block,
      auction: String.to_integer(auction, 16)
    }

    cond do
      called?(data, "distribution(address)") ->
        List.duplicate(0, LabAbi.distribution_words())
        |> List.replace_at(0, state.lifecycle)
        |> List.replace_at(4, @migration_block)
        |> words()

      called?(data, "launchIdOfAuction(address)") ->
        BaseRpcStub.uint(state.launch_id)

      called?(data, "launches(uint256)") ->
        StocksLabAbi.shape(state.version).record_fields
        |> Enum.map(&Map.get(held, &1, 0))
        |> words()
    end
  end

  defp called?(data, signature), do: String.starts_with?(data, LabAbi.selector(signature))

  defp words(values), do: "0x" <> Enum.map_join(values, &BaseRpcStub.hex_word/1)

  # The finish its launchpad takes for `auction`, from the site's deployment
  # descriptions: the Revstake strategy's `migrate(address)`, or the Memestock
  # launchpad's `migrate(uint256)` of its launch, ending with the Builder Code.
  defp finish_step(%{chain_id: 4_663}) do
    {:ok, config} = RobinhoodLab.current()
    {:ok, contracts} = RobinhoodLab.contracts(config, :v2)
    migrate(contracts.launchpad, contracts.abis["launchpad"], [@robinhood_launch_id])
  end

  defp finish_step(%{kind: :agent} = auction) do
    {:ok, config} = Lab.contracts(Lab.current!(), auction.contracts_version)

    Lab.address!(config, :strategy)
    |> migrate(Lab.abi!(config, :strategy), [auction.auction_address], "migrate(address)")
  end

  defp finish_step(%{kind: :stocks} = auction) do
    {:ok, contracts} = StocksLab.contracts(StocksLab.current!(), auction.contracts_version)
    migrate(contracts.launchpad, contracts.abis["launchpad"], [@launch_id])
  end

  defp migrate(to, abi, arguments, signature \\ "migrate(uint256)"),
    do: %{
      "kind" => "transaction",
      "step" => "finish",
      "to" => Address.normalize!(to),
      "data" => abi |> LabAbi.encode(signature, arguments) |> BuilderCode.append(),
      "value" => "0x0"
    }

  # Every chain read since the last call, from this test's mailbox: Base's
  # double tells each request, Robinhood Chain's each method.
  defp chain_reads(reads \\ []) do
    receive do
      {:rpc, method, _params} -> chain_reads([method | reads])
      {:robinhood_read, method} -> chain_reads([method | reads])
    after
      0 -> reads
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
end
