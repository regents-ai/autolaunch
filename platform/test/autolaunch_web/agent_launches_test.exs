defmodule AutolaunchWeb.AgentLaunchesTest do
  @moduledoc """
  Agent launches on a paired agent's two ways in: the signed route the browser
  tool calls and the hosted MCP tool give one answer for one input, refusals
  in the same code and words.

  The launch step is the create page's for the same draft and wallet: a
  Revstake draft's on Base, a Memestock draft's on the chain it names, Base or
  Robinhood Chain. The review is kept for the person, as the page keeps its
  own. Only the person's own wallets and drafts are prepared for, and only for
  the agent paired with them, while the person has a verified wallet; another
  person's draft and a draft that does not exist are answered alike, before
  any chain is read. What only the person can give stays on the create page:
  a treasury the agent chose, a private key's acknowledgement and the treasury
  check. A Revstake draft whose person has no X, GitHub or ENS account on show
  is given its step with the `no_connections` warning; a Memestock draft is
  never warned. Every refusal is reached and named, with a status and code the
  contract documents, and every reason the reviews give has one code. A read
  that fails, or a reason nobody named, is refused as `launch_unavailable`.
  Off, or in prelaunch read-only mode, the tool is not listed or run, and off
  a call to it is answered as one to a tool that does not exist.

  Base is the launch fixture's chain for a Revstake draft and
  `BaseLaunchpad` below for a Memestock one; Robinhood Chain is
  `Autolaunch.RobinhoodBidChain`. The sign-in service is stubbed: it vouches
  for the wallet a request names.
  """
  use AutolaunchWeb.ConnCase, async: false
  use ExUnitProperties

  import Autolaunch.DatabaseFaults, only: [lose_reads_of: 1, restore_reads_of: 1]
  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Plug.Test, only: [conn: 3]

  require Ash.Query

  alias Autolaunch.Accounts.RequestRateLimiter
  alias Autolaunch.Actors.{Agent, ConnectedApp, Human, System}
  alias Autolaunch.AgentLaunch.Refused
  alias Autolaunch.Robinhood.LaunchReview
  alias Autolaunch.Robinhood.StocksLaunchActions, as: RobinhoodLaunchActions
  alias Autolaunch.Stocks.LaunchActions, as: StocksLaunchActions
  alias Autolaunch.Stocks.LaunchOperation, as: StocksLaunchOperation
  alias AutolaunchWeb.AgentLaunchAnswer
  alias RegentChain.BuilderCode

  alias Autolaunch.{
    Accounts,
    AgentDrafts,
    AgentLaunch,
    LabAbi,
    LaunchActions,
    LaunchFixture,
    LaunchOperation,
    Repo,
    RobinhoodBidChain,
    TestAutolaunchLaunchChainClient,
    TestAutolaunchTreasuryChainClient
  }

  @moduletag :capture_log
  @contract "../../contracts/agent-launches.openapiv3.yaml"
            |> Path.expand(__DIR__)
            |> YamlElixir.read_from_file!()
  @codes get_in(
           @contract,
           ~w(components schemas AgentLaunchError properties error properties code enum)
         )
  @schemas @contract["components"]["schemas"]
  @path "/api/agent/v1/launches/{draft}/steps"
  @other "0x2222222222222222222222222222222222222222"
  # A smart contract account an agent may choose as a Revstake treasury.
  @contract_account "0x" <> String.duplicate("5c", 20)
  # The stock a Base Memestock draft pairs with, and its route.
  @aapl "0xb200000000000000000000c2e324d24d7eecd1fb"
  @route "0x547f3b931eaf75bab98364ab396058ddc2e68e4a"
  @stocks_deployment Path.expand("../fixtures/base-stocks-deployment.json", __DIR__)
  @robinhood_deployment Path.expand("../fixtures/robinhood-deployment.json", __DIR__)

  defmodule WatchedLaunchChain do
    @moduledoc false
    # The Revstake launch fixture's Base, telling the test process of each read.
    @behaviour Autolaunch.LaunchChainClient

    alias Autolaunch.TestAutolaunchLaunchChainClient, as: Chain

    @impl true
    def snapshot(request) do
      send(self(), {:chain_read, "snapshot"})
      Chain.snapshot(request)
    end

    @impl true
    def verify(review, hash), do: Chain.verify(review, hash)
  end

  defmodule RaisingLaunchChain do
    @moduledoc false
    # Base failing in a way nobody named, saying what it was asked.
    @behaviour Autolaunch.LaunchChainClient

    @impl true
    def snapshot(request), do: raise("snapshot failed for #{inspect(request)}")

    @impl true
    def verify(review, _hash), do: raise("verify failed for #{inspect(review)}")
  end

  defmodule BaseLaunchpad do
    @moduledoc false
    # Base as a Memestock launch's review reads it at one latest block (150):
    # the Base Stocks launchpad's pause and the stock's admission (admitted,
    # decimals, route). `put/1` replaces either, or names the one method the
    # node refuses (`unreadable`), for the calling test; each read tells the
    # test process.
    alias Autolaunch.{BaseRpcStub, LabAbi}

    def put(changes), do: Process.put(__MODULE__, Map.merge(state(), Map.new(changes)))

    defp state do
      Process.get(__MODULE__, %{
        paused: false,
        admission: [1, 8, 0x547F3B931EAF75BAB98364AB396058DDC2E68E4A],
        unreadable: nil
      })
    end

    def post(_url, options) do
      %{method: method, params: params} = options[:json]
      state = state()
      send(self(), {:chain_read, method})

      if method == state.unreadable,
        do: {:ok, %{status: 200, body: %{"error" => %{"message" => "unavailable"}}}},
        else: {:ok, %{status: 200, body: %{"result" => answer(method, params, state)}}}
    end

    defp answer("eth_chainId", _params, _state), do: "0x2105"
    defp answer("eth_getCode", _params, _state), do: "0x6080"

    defp answer("eth_getBlockByNumber", _params, _state),
      do: %{
        "number" => "0x96",
        "hash" => "0x" <> String.duplicate("ab", 32),
        "timestamp" => "0x6700"
      }

    defp answer("eth_call", [%{data: data}, _block], state) do
      cond do
        String.starts_with?(data, LabAbi.selector("launchesPaused()")) ->
          words([if(state.paused, do: 1, else: 0)])

        String.starts_with?(data, LabAbi.selector("stockAdmission(address)")) ->
          words(state.admission)
      end
    end

    defp words(values), do: "0x" <> Enum.map_join(values, &BaseRpcStub.hex_word/1)
  end

  setup do
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

    for key <- [
          :agent_launches,
          :prelaunch_read_only,
          :autolaunch_lab_http_client,
          :autolaunch_launch_chain_client,
          :autolaunch_base_stocks_deployment
        ],
        do: keep_env(key)

    Application.put_env(:autolaunch, :agent_launches, :on)
    # Past the prelaunch gate, which refuses wallet steps until the site opens.
    Application.put_env(:autolaunch, :prelaunch_read_only, false)

    LaunchFixture.install()
    Application.put_env(:autolaunch, :autolaunch_launch_chain_client, WatchedLaunchChain)
    TestAutolaunchTreasuryChainClient.seed_verified!(LaunchFixture.treasury())
    RobinhoodBidChain.install()
    base_chain()

    Autolaunch.record_stock_admission!(
      %{
        chain_id: 8453,
        address: @aapl,
        symbol: "AAPLc",
        name: "Apple Inc.",
        decimals: 8,
        route: @route,
        admitted: true
      },
      actor: %System{}
    )

    person = person!()
    Map.put(person, :person, person)
  end

  test "a Revstake draft's launch step is the create page's for the same draft and wallet, alike on both ways in, and kept for the person",
       %{agent: agent, account: account, draft: draft, wallet: wallet, opts: opts} do
    {:ok, page} = LaunchActions.prepare(draft.id, wallet, opts)

    before = kept(LaunchOperation, account)
    {:ok, data} = answer(http(:post, launch_path(draft.id), %{}, agent))
    assert [row] = kept(LaunchOperation, account) -- before

    assert_page_answer(data, page, wallet, %{"id" => draft.id, "kind" => "revstake"})
    assert data["chain"]["rpc_url"] == Autolaunch.Lab.current!().public_rpc_url
    assert data["block"] == 30_000_000
    assert data["facts"]["treasury"] == LaunchFixture.treasury()

    # The launch factory's own launch, with the draft's name, ticker and
    # picture, to the factory the chain names.
    assert [%{"to" => to, "data" => calldata}] = data["steps"]
    assert to == LaunchFixture.factory()

    assert String.starts_with?(
             calldata,
             LabAbi.selector("launch((string,string,string,string,string,address))")
           )

    assert %{"name" => "Open Research", "symbol" => "OPEN", "image" => image} = data["facts"]
    assert image == draft.image

    # Kept as the page keeps its own review: for the person, of this draft,
    # with the step the wallet is asked to send, marked as the agent's.
    assert row.human_account_id == account.id and row.launch_draft_id == draft.id
    assert row.signer == wallet and row.step == :launch and row.prepared_by == :agent
    assert row.review["step"]["data"] == calldata

    # The same preparation again, on either way in and with the wallet named
    # or not, is the one already kept, with the same step.
    for input <- [%{}, %{signer: wallet}] do
      assert tool(agent, "prepare_launch", Map.put(input, :draft, draft.id)) == {:ok, data}
      assert answer(http(:post, launch_path(draft.id), input, agent)) == {:ok, data}
    end

    assert kept(LaunchOperation, account) -- before == [row]
  end

  test "a Memestock draft's launch step on Base is the create page's for the same draft and wallet, alike on both ways in, and kept for the person",
       %{agent: agent, account: account, wallet: wallet, opts: opts} do
    draft = memestock!(agent, %{"stock_address" => @aapl})
    {:ok, page} = StocksLaunchActions.prepare(draft.id, wallet, opts)
    {:ok, stocks} = Autolaunch.Stocks.Lab.current()

    before = kept(StocksLaunchOperation, account)
    {:ok, data} = answer(http(:post, launch_path(draft.id), %{}, agent))
    assert [row] = kept(StocksLaunchOperation, account) -- before

    # The same preparation again is the one already kept.
    assert tool(agent, "prepare_launch", %{draft: draft.id}) == {:ok, data}
    assert kept(StocksLaunchOperation, account) -- before == [row]

    assert_page_answer(data, page, wallet, %{"id" => draft.id, "kind" => "memestock"})
    assert %{"chain_id" => 8453, "name" => "Base"} = data["chain"]
    assert data["chain"]["rpc_url"] == stocks.public_rpc_url
    assert data["block"] == 150

    assert [%{"to" => to, "data" => calldata}] = data["steps"]
    assert to == Autolaunch.Stocks.Lab.address!(stocks, :launchpad)
    assert %{"stock" => @aapl, "stock_symbol" => "AAPLc", "stock_decimals" => "8"} = data["facts"]
    # The fields the agent set are named for the person to see.
    assert "stock_address" in data["facts"]["agent_set_fields"]

    assert row.human_account_id == account.id and row.launch_draft_id == draft.id
    assert row.signer == wallet and row.review["step"]["data"] == calldata
    assert row.prepared_by == :agent
  end

  test "a Memestock draft's launch step on Robinhood Chain is the create page's for the same draft and wallet, alike on both ways in, and kept for the person",
       %{agent: agent, account: account, wallet: wallet, opts: opts} do
    robinhood_chain()

    draft =
      memestock!(agent, %{"chain" => "robinhood", "stock_address" => RobinhoodBidChain.stock()})

    {:ok, page} = RobinhoodLaunchActions.prepare(draft.id, wallet, opts)
    {:ok, deployment} = Autolaunch.Robinhood.Lab.current()

    before = kept(LaunchReview, account)
    {:ok, data} = answer(http(:post, launch_path(draft.id), %{}, agent))

    # The same again, on the other way in, is the review kept already.
    assert tool(agent, "prepare_launch", %{draft: draft.id}) == {:ok, data}
    assert [kept] = kept(LaunchReview, account) -- before
    assert_page_answer(data, page, wallet, %{"id" => draft.id, "kind" => "memestock"})
    assert %{"chain_id" => 4_663, "name" => "Robinhood Chain"} = data["chain"]
    assert data["chain"]["rpc_url"] == deployment.public_rpc_url
    assert data["block"] == 100

    assert [%{"to" => to}] = data["steps"]
    assert to == Autolaunch.Robinhood.Lab.address!(deployment, :stocks_launchpad)
    assert data["facts"]["stock"] == RobinhoodBidChain.stock()

    # Kept as the page keeps it, so Robinhood discovery knows the launch as
    # this site's and the person's.
    assert kept.human_account_id == account.id and kept.signer == wallet
    assert kept.chain_id == 4_663 and kept.stock == RobinhoodBidChain.stock()
    assert kept.prepared_by == :agent
    assert {kept.name, kept.symbol} == {data["facts"]["name"], data["facts"]["symbol"]}

    assert {:ok, %{id: id}} =
             Autolaunch.matching_robinhood_launch_review(
               4_663,
               wallet,
               kept.name,
               kept.symbol,
               kept.stock,
               actor: %System{}
             )

    assert id in Enum.map(kept(LaunchReview, account), & &1.id)
  end

  test "a Revstake draft whose person has no X, GitHub or ENS account on show is given its step with the no_connections warning, alike on both ways in",
       %{agent: agent, account: account, draft: draft} do
    # An X connection begun and never checked is none on show.
    Accounts.begin_x_connection_attempt!(
      %{
        role: :profile,
        attempt_state: "state-#{Ash.UUID.generate()}",
        attempt_verifier: "verifier-#{Ash.UUID.generate()}",
        attempt_generation: Ash.UUID.generate(),
        attempt_expires_at: DateTime.add(DateTime.utc_now(), 600, :second),
        intent_sequence: 1,
        intent_generation: Ash.UUID.generate()
      },
      actor: %Human{human_account_id: account.id}
    )

    {:ok, data} = answer(http(:post, launch_path(draft.id), %{}, agent))

    assert [%{"code" => "no_connections", "message" => message}] = data["warnings"]
    assert is_binary(message)
    assert [%{"step" => "launch"}] = data["steps"]
    assert tool(agent, "prepare_launch", %{draft: draft.id}) == {:ok, data}
  end

  test "a Revstake draft whose person has a checked X account, GitHub or ENS is given no warning, alike on both ways in" do
    linked = fn provider ->
      fn account ->
        Accounts.upsert_linked_identity!(
          provider,
          "#{provider}-#{account.id}",
          "#{provider}-#{account.id}",
          "#{provider}-#{account.id}",
          DateTime.utc_now(),
          %{},
          account.id,
          actor: %System{}
        )
      end
    end

    for connect <- [
          &Autolaunch.TestSupport.verify_x!(&1, :profile, username: "creator#{&1.id}"),
          linked.(:github),
          linked.(:ens)
        ] do
      %{agent: agent, account: account, draft: draft} = person!()
      connect.(account)

      {:ok, data} = answer(http(:post, launch_path(draft.id), %{}, agent))

      assert data["warnings"] == []
      assert [%{"step" => "launch"}] = data["steps"]
      assert tool(agent, "prepare_launch", %{draft: draft.id}) == {:ok, data}
    end
  end

  test "a Memestock draft is given no warning on Base or Robinhood Chain, though its person has no account on show",
       %{agent: agent} do
    base = memestock!(agent, %{"stock_address" => @aapl})

    assert {:ok, %{"warnings" => []} = data} =
             answer(http(:post, launch_path(base.id), %{}, agent))

    assert tool(agent, "prepare_launch", %{draft: base.id}) == {:ok, data}

    robinhood_chain()

    robinhood =
      memestock!(agent, %{"chain" => "robinhood", "stock_address" => RobinhoodBidChain.stock()})

    assert {:ok, %{"warnings" => []} = data} =
             answer(http(:post, launch_path(robinhood.id), %{}, agent))

    assert tool(agent, "prepare_launch", %{draft: robinhood.id}) == {:ok, data}
  end

  test "another person's draft and a draft that does not exist are answered alike, before any chain is read",
       %{agent: agent} do
    stranger = person!()
    theirs = memestock!(stranger.agent, %{"stock_address" => @aapl})

    answers =
      for id <- [stranger.draft.id, theirs.id, Ecto.UUID.generate()] do
        flush_reads()
        route = http(:post, launch_path(id), %{}, agent)

        assert route.status == 404 and route.body["error"]["code"] == "launch_draft_not_found",
               id

        refute_received {:chain_read, _method}, id
        assert tool(agent, "prepare_launch", %{draft: id}) == {:error, route.body}
        refute_received {:chain_read, _method}, id
        route.body
      end

    assert [_one] = Enum.uniq(answers)
    assert documented?(404, "launch_draft_not_found")

    # The stranger's own agent prepares the stranger's own draft.
    assert {:ok, %{"draft" => %{"id" => id}}} =
             answer(http(:post, launch_path(stranger.draft.id), %{}, stranger.agent))

    assert id == stranger.draft.id
  end

  test "only the person's own wallets are prepared for: another is wrong_signer, before any chain is read",
       %{agent: agent, account: account, draft: draft, wallet: wallet} do
    flush_reads()
    route = http(:post, launch_path(draft.id), %{signer: @other}, agent)
    assert route.status == 403 and route.body["error"]["code"] == "wrong_signer"
    refute_received {:chain_read, _method}

    assert tool(agent, "prepare_launch", %{draft: draft.id, signer: @other}) ==
             {:error, route.body}

    # Another of the person's own wallets is theirs to launch from.
    second = "0x3333333333333333333333333333333333333334"

    {:ok, _account} =
      Accounts.refresh_verified(account, wallet, [wallet, second], actor: %System{})

    assert {:ok, %{"signer" => ^second}} =
             answer(http(:post, launch_path(draft.id), %{signer: second}, agent))

    # Another person's agent, naming this person's wallet for this draft.
    stranger = person!()
    route = http(:post, launch_path(draft.id), %{signer: second}, stranger.agent)
    assert route.status == 403 and route.body["error"]["code"] == "wrong_signer"
  end

  test "a person whose wallet evidence has lapsed, or no longer holds together, is refused wallet_required, before any chain is read",
       %{account: account, agent: agent, draft: draft, wallet: wallet} do
    # Lapsed: no primary wallet and none listed, as a sign-in that finds no
    # linked wallet leaves it. Not holding together: wallets listed but no
    # primary among them.
    for {primary, addresses} <- [{nil, []}, {nil, [wallet]}, {@other, [wallet]}],
        input <- [%{}, %{signer: wallet}] do
      {:ok, _account} = Accounts.refresh_verified(account, primary, addresses, actor: %System{})
      named = "#{inspect({primary, addresses})} #{inspect(input)}"
      flush_reads()
      route = http(:post, launch_path(draft.id), input, agent)

      assert route.status == 409 and route.body["error"]["code"] == "wallet_required",
             "#{named} answered #{inspect(route.body)}"

      refute_received {:chain_read, _method}, named

      assert tool(agent, "prepare_launch", Map.put(input, :draft, draft.id)) ==
               {:error, route.body},
             named
    end

    assert documented?(409, "wallet_required")
  end

  test "what only the person can give stays on the create page: a treasury the agent chose, a private key's acknowledgement, and the treasury check",
       %{agent: agent, draft: draft} do
    {:ok, resolved} = Autolaunch.Agents.resolve(agent)

    for {saved, code} <- [
          {%{"treasury" => @contract_account, "treasury_path" => "contract"},
           "agent_treasury_unconfirmed"},
          {%{"treasury" => LaunchFixture.treasury(), "treasury_path" => "safe"},
           "agent_treasury_unconfirmed"},
          {%{"treasury" => LaunchFixture.treasury(), "treasury_path" => "eoa"},
           "launch_treasury_invalid"}
        ] do
      {:ok, _draft} = AgentDrafts.save("revstake", saved, resolved)
      route = http(:post, launch_path(draft.id), %{}, agent)

      assert route.status == 409 and route.body["error"]["code"] == code,
             "#{inspect(saved)} answered #{inspect(route.body)}"

      assert tool(agent, "prepare_launch", %{draft: draft.id}) == {:error, route.body}
    end

    # A treasury the person set themselves that the site has not checked.
    unchecked = person!(%{"treasury" => random_wallet()})
    route = http(:post, launch_path(unchecked.draft.id), %{}, unchecked.agent)
    assert route.status == 409 and route.body["error"]["code"] == "treasury_report_missing"
  end

  test "the steps are prepared for the paired agent alone, a connected app calling as it included",
       %{account: account, agent: wallet, draft: draft} do
    {:ok, agent} = Autolaunch.Agents.resolve(wallet)
    app_as_agent = %{agent | connection: %{subject: account.privy_user_id}}
    person = %Human{human_account_id: account.id}
    app = %ConnectedApp{principal: %{subject: account.privy_user_id}}

    for actor <- [agent, app_as_agent, person, app, %System{}, nil] do
      launch = Ash.ActionInput.for_action(AgentLaunch, :prepare, %{draft: draft.id})
      assert Ash.can?(launch, actor) == actor in [agent, app_as_agent], inspect(actor)
    end

    # Its reviews are kept by the agent's own actions, which no person or app
    # may take; the site itself keeps every review.
    for actor <- [agent, app_as_agent, person, app, nil] do
      for {resource, action} <- [
            {LaunchOperation, :agent_prepare},
            {StocksLaunchOperation, :agent_prepare},
            {LaunchReview, :agent_record}
          ] do
        assert Ash.can?({resource, action}, actor) == actor in [agent, app_as_agent],
               "#{inspect(resource)} #{action} for #{inspect(actor)}"
      end
    end
  end

  test "an agent's preparation of a Base draft stays good for 24 hours: past 20 unused ones, a different one waits for the oldest to be 24 hours old, and the person's own and a launched one are never removed or reused",
       %{agent: signing, account: account, draft: draft, wallet: wallet, opts: opts} do
    {:ok, agent} = Autolaunch.Agents.resolve(signing)
    meme = memestock!(signing, %{"stock_address" => @aapl})
    {:ok, _page} = LaunchActions.prepare(draft.id, wallet, opts)
    {:ok, _page} = StocksLaunchActions.prepare(meme.id, wallet, opts)

    for {resource, draft, verify} <- [
          {LaunchOperation, draft, &Autolaunch.verify_launch_review/3},
          {StocksLaunchOperation, meme, &Autolaunch.verify_stocks_launch_review/3}
        ] do
      kept = fn -> resource |> kept(account) |> MapSet.new(& &1.id) end
      assert [%{prepared_by: :person} = own] = kept(resource, account)

      launched = prepare!(resource, draft, agent, 0)
      {:ok, _launched} = verify.(launched, %{result: %{}}, actor: %System{})

      # Twenty unused ones, none 24 hours old: a different one is refused and
      # nothing changes.
      [first, second, third, fourth | rest] =
        prepared = for n <- 1..20, do: prepare!(resource, draft, agent, n)

      all = MapSet.new([own.id, launched.id | Enum.map(prepared, & &1.id)])
      assert kept.() == all
      assert too_many?(prepare(resource, draft, agent, 21))
      assert kept.() == all

      # With the four oldest past 24 hours, a different one takes the place of
      # the oldest of them alone, and is kept.
      age!(resource, [first, second, third, fourth])
      newest = prepare!(resource, draft, agent, 21)
      assert kept.() == all |> MapSet.delete(first.id) |> MapSet.put(newest.id)

      # The newest again, read at another block, is the newest itself.
      assert prepare!(resource, draft, agent, 21, 31).id == newest.id

      # The same as an older one, as the launched one, or as the person's own,
      # is a new one, each in the place of the oldest past 24 hours.
      again = prepare!(resource, draft, agent, 20)
      relaunched = prepare!(resource, draft, agent, 0)
      theirs = prepare!(resource, draft, agent, own.review)
      refute again.id == List.last(rest).id or relaunched.id == launched.id or theirs.id == own.id

      assert kept.() ==
               MapSet.new([
                 own.id,
                 launched.id,
                 newest.id,
                 again.id,
                 relaunched.id,
                 theirs.id | Enum.map(rest, & &1.id)
               ])

      # None past 24 hours is left, so the next different one waits again.
      assert too_many?(prepare(resource, draft, agent, 22))
    end
  end

  test "an agent's Robinhood preparation stays good for 24 hours: past 20 unused ones of its person on that chain, a different one waits for the oldest to be 24 hours old, and the person's own and an adopted one are never removed or reused",
       %{agent: signing, account: account} do
    {:ok, agent} = Autolaunch.Agents.resolve(signing)
    kept = fn -> LaunchReview |> kept(account) |> MapSet.new(& &1.id) end

    own =
      0
      |> robinhood_review()
      |> Map.put(:human_account_id, account.id)
      |> Autolaunch.record_robinhood_launch_review!(actor: %System{})

    adopted =
      agent
      |> record!(robinhood_review(1))
      |> Autolaunch.adopt_robinhood_launch_review!(actor: %System{})

    [first, second, third, fourth | rest] =
      prepared = for n <- 2..21, do: record!(agent, robinhood_review(n))

    all = MapSet.new([own.id, adopted.id | Enum.map(prepared, & &1.id)])
    assert kept.() == all
    assert too_many?(record(agent, robinhood_review(22)))
    assert kept.() == all

    age!(LaunchReview, [first, second, third, fourth])
    newest = record!(agent, robinhood_review(22))
    assert kept.() == all |> MapSet.delete(first.id) |> MapSet.put(newest.id)

    # The newest again is the newest itself.
    assert record!(agent, robinhood_review(22)).id == newest.id

    # The same as an older one, as the adopted one, or as the person's own, is
    # a new one.
    again = record!(agent, robinhood_review(21))
    readopted = record!(agent, robinhood_review(1))
    theirs = record!(agent, robinhood_review(0))
    refute again.id == List.last(rest).id or readopted.id == adopted.id or theirs.id == own.id

    assert kept.() ==
             MapSet.new([
               own.id,
               adopted.id,
               newest.id,
               again.id,
               readopted.id,
               theirs.id | Enum.map(rest, & &1.id)
             ])

    assert too_many?(record(agent, robinhood_review(23)))
  end

  test "an agent's review names only its person's own draft: another person's is refused and nothing is kept",
       %{agent: signing, account: account} do
    {:ok, agent} = Autolaunch.Agents.resolve(signing)
    stranger = person!()
    theirs = memestock!(stranger.agent, %{"stock_address" => @aapl})

    for {resource, draft} <- [{LaunchOperation, stranger.draft}, {StocksLaunchOperation, theirs}] do
      assert {:error, %Ash.Error.Invalid{errors: [%{field: :launch_draft_id}]}} =
               prepare(resource, draft, agent, 1)

      assert kept(resource, account) == [] and kept(resource, stranger.account) == []
    end
  end

  test "only the pairing's own refusal is agent_not_paired: one in the steps the site runs itself is launch_unavailable",
       %{agent: signing, account: account, draft: draft} do
    {:ok, agent} = Autolaunch.Agents.resolve(signing)
    meme = memestock!(signing, %{"stock_address" => @aapl})
    operation = prepare!(LaunchOperation, draft, agent, 1)
    review = record!(agent, robinhood_review(1))

    # The steps the site runs itself, reading the open ones, removing one and
    # marking one as listed, refused to the agent.
    site_steps = [
      LaunchOperation |> Ash.Query.for_read(:agent_preparations, %{}, actor: agent) |> Ash.read(),
      StocksLaunchOperation
      |> Ash.Query.for_read(:agent_preparations, %{}, actor: agent)
      |> Ash.read(),
      LaunchReview |> Ash.Query.for_read(:agent_preparations, %{}, actor: agent) |> Ash.read(),
      Ash.destroy(operation, action: :trim, actor: agent),
      Ash.destroy(review, action: :trim, actor: agent),
      Autolaunch.adopt_robinhood_launch_review(review, actor: agent)
    ]

    for answer <- site_steps do
      assert {:error, %Ash.Error.Forbidden{} = refusal} = answer
      assert AgentLaunch.code(refusal) == :launch_unavailable
    end

    # The agent's own reads and writes, refused by its pairing once it ends.
    person = %RegentAgents.Person{privy_user_id: account.privy_user_id}
    [paired] = RegentAgents.list_my_agents!(actor: person)
    :ok = RegentAgents.unpair_agent!(paired, actor: person)

    own_steps = [
      Autolaunch.LaunchDraft
      |> Ash.Query.for_read(:agent_read, %{}, actor: agent)
      |> Ash.Query.filter(id == ^draft.id)
      |> Ash.read_one(),
      Autolaunch.Stocks.LaunchDraft
      |> Ash.Query.for_read(:agent_read, %{}, actor: agent)
      |> Ash.Query.filter(id == ^meme.id)
      |> Ash.read_one(),
      prepare(LaunchOperation, draft, agent, 2),
      prepare(StocksLaunchOperation, meme, agent, 2),
      record(agent, robinhood_review(2))
    ]

    for answer <- own_steps do
      assert {:error, %Ash.Error.Forbidden{} = refusal} = answer
      assert AgentLaunch.code(refusal) == :agent_not_paired
    end
  end

  test "every refusal is reached, named alike on both ways in, in a status and code the contract documents",
       %{person: person} do
    base = with_memestock(person, %{"stock_address" => @aapl})

    robinhood =
      with_memestock(person!(), %{
        "chain" => "robinhood",
        "stock_address" => RobinhoodBidChain.stock()
      })

    # A person whose agent already holds 20 unused preparations of the draft,
    # none 24 hours old.
    crowded = person!()
    {:ok, crowding} = Autolaunch.Agents.resolve(crowded.agent)
    for n <- 1..20, do: prepare!(LaunchOperation, crowded.draft, crowding, n)

    cases = [
      {asking(person, "nope"), [], %{}, "invalid_request"},
      {person, [], %{bogus: "x"}, "invalid_request"},
      {person, [], %{signer: 1}, "invalid_request"},
      {asking(person, Ecto.UUID.generate()), [], %{}, "launch_draft_not_found"},
      {person, [], %{signer: @other}, "wrong_signer"},
      {person, [], %{signer: "nope"}, "wallet_required"},
      {person!(%{"description" => nil}), [], %{}, "launch_metadata_incomplete"},
      {agent_saved(%{"treasury" => @contract_account, "treasury_path" => "contract"}), [], %{},
       "agent_treasury_unconfirmed"},
      # A treasury held by a private key, without the person's acknowledgement.
      {agent_saved(%{"treasury_path" => "eoa"}), [], %{}, "launch_treasury_invalid"},
      {person!(%{"treasury" => LaunchFixture.factory()}), [], %{}, "launch_treasury_refused"},
      {person!(%{"treasury" => random_wallet()}), [], %{}, "treasury_report_missing"},
      # The person chose a smart contract account, but the treasury the site
      # checked is a Safe.
      {person!(%{"treasury_path" => "contract"}), [], %{}, "treasury_security_changed"},
      # The block the treasury was checked at is no longer Base's.
      {person, [treasury: [canonical?: false]], %{}, "treasury_security_changed"},
      {person, [treasury: [error: :treasury_configuration_drift]], %{},
       "treasury_configuration_drift"},
      {person, [revstake: [paused: true]], %{}, "launches_paused"},
      {person, [revstake: [strategy_factory: @other]], %{}, "strategy_not_bound"},
      # Base answering part of what a launch is built from.
      {person, [revstake: [hook: "not an address"]], %{}, "chain_unavailable"},
      # The site's own fault: Base names another REGENT than the site knows.
      {person, [revstake: [regent: @other]], %{}, "launch_unavailable"},
      {with_memestock(person!(), %{}), [], %{}, "stock_invalid"},
      {base, [base: [admission: [0, 8, 0]]], %{}, "stock_not_admitted"},
      {base, [base: [paused: true]], %{}, "launches_paused"},
      {base, [base: [unreadable: "eth_call"]], %{}, "chain_unavailable"},
      # A deployment description the site cannot load.
      {base, [unloadable: :autolaunch_base_stocks_deployment], %{}, "stocks_unavailable"},
      {robinhood, [robinhood: [admission: [0, 18, 0]]], %{}, "stock_not_admitted"},
      {robinhood, [robinhood: [launches_paused: true]], %{}, "launches_paused"},
      {robinhood, [robinhood: [unreadable: "eth_call"]], %{}, "chain_unavailable"},
      {robinhood, [robinhood: [chain_id: "0x2105"]], %{}, "chain_unavailable"},
      # The site's own fault: its launchpad holds no contract.
      {robinhood, [robinhood: [code: "0x"]], %{}, "launch_unavailable"},
      {robinhood, [unloadable: :autolaunch_robinhood_deployment], %{}, "robinhood_unavailable"},
      {crowded, [], %{}, "too_many_preparations"}
    ]

    reached =
      for {who, chain, input, code} <- cases do
        arrange(chain, who.draft)
        route = http(:post, launch_path(who.draft.id), input, who.agent)
        named = "#{inspect(input)} on #{inspect(chain)}"

        assert route.body["error"]["code"] == code, "#{named} answered #{inspect(route.body)}"
        assert route.body["error"]["message"] != ""

        assert tool(who.agent, "prepare_launch", Map.put(input, :draft, who.draft.id)) ==
                 {:error, route.body},
               named

        assert documented?(route.status, code), "#{code} at #{route.status}"
        code
      end

    # An agent nobody paired.
    arrange([], person.draft)
    route = http(:post, launch_path(person.draft.id), %{}, random_wallet())
    assert route.status == 403 and route.body["error"]["code"] == "agent_not_paired"
    assert documented?(403, "agent_not_paired")

    # Each code the contract lists is reached here, but the account read and
    # prelaunch refusals, each in its own test below.
    assert Enum.sort(Enum.uniq(["agent_not_paired" | reached])) ==
             Enum.sort(
               @codes -- ~w(authentication_required account_unavailable prelaunch_read_only)
             )
  end

  test "a paired agent whose person's account cannot be read prepares nothing", %{draft: draft} do
    unread = %Agent{
      wallet_address: random_wallet(),
      privy_user_id: "did:privy:unread",
      pairing_id: Ecto.UUID.generate(),
      human_account_id: Ecto.UUID.generate()
    }

    assert {:error, %Ash.Error.Unknown{errors: [%Refused{reason: :authentication_required}]}} =
             Autolaunch.prepare_launch(%{draft: draft.id}, actor: unread)

    assert documented?(401, "authentication_required")
  end

  test "a paired agent whose person's account cannot be read as the request arrives is refused account_unavailable",
       %{agent: agent, draft: draft} do
    # The person's account is read with its ENS name as the pairing is resolved.
    lose_reads_of("account_ens_identities")
    route = http(:post, launch_path(draft.id), %{}, agent)

    assert route.status == 503 and route.body["error"]["code"] == "account_unavailable",
           inspect(route.body)

    assert documented?(503, "account_unavailable")
  end

  test "the route spends the person's one budget of 120 signed requests a minute",
       %{agent: agent, draft: draft} do
    # Requests that might straddle two minutes start in the next one.
    {:ok, %{reset: left}} = RequestRateLimiter.admit({"minute", make_ref()}, 1, 60)
    if left < 5, do: Process.sleep(left * 1000)

    for remaining <- [119, 118] do
      answered = signed(:post, launch_path(draft.id), %{bogus: "x"}, agent)
      assert answered.status == 422
      assert [budget] = get_resp_header(answered, "ratelimit")
      assert budget =~ ~s("agent";r=#{remaining}), budget
    end
  end

  test "a read that fails, a raise, or a reason nobody named, is logged by kind alone and refused as launch_unavailable alike on both ways in",
       %{agent: agent, draft: draft, wallet: wallet, opts: opts} do
    refused = fn ->
      {route, log} = with_log(fn -> http(:post, launch_path(draft.id), %{}, agent) end)

      assert route.status == 503 and route.body["error"]["code"] == "launch_unavailable",
             inspect(route.body)

      assert documented?(503, "launch_unavailable")
      assert tool(agent, "prepare_launch", %{draft: draft.id}) == {:error, route.body}
      refute log =~ wallet
      log
    end

    # Base names another REGENT than the site knows.
    arrange([revstake: [regent: @other]], draft)
    assert refused.() =~ "agent launch failed: regent_address_mismatch"
    arrange([], draft)

    lose_reads_of("launch_drafts")
    assert refused.() =~ "agent launch connection_lost"
    restore_reads_of("launch_drafts")

    # The treasury's report could not be read, which is not a treasury never
    # checked; the create page says only that it did not go through.
    lose_reads_of("treasury_security_reports")
    assert refused.() =~ "agent launch connection_lost"
    {page, log} = with_log(fn -> LaunchActions.prepare(draft.id, wallet, opts) end)
    assert {:error, error} = page
    assert AutolaunchWeb.OnchainSteps.refusal(error) == :unavailable
    assert [_once] = Regex.scan(~r/\[warning\] launch review read connection_lost/, log)
    refute log =~ wallet or log =~ LaunchFixture.treasury()
    restore_reads_of("treasury_security_reports")

    # A raise anywhere in the operation, here Base's own read naming the
    # wallet, is logged without what it said.
    Application.put_env(:autolaunch, :autolaunch_launch_chain_client, RaisingLaunchChain)
    assert refused.() =~ "agent launch failed: RuntimeError"
    Application.put_env(:autolaunch, :autolaunch_launch_chain_client, WatchedLaunchChain)

    # Base answering nothing is a chain that could not be read just now.
    TestAutolaunchLaunchChainClient.put(%{unavailable: :chain_unavailable})
    route = http(:post, launch_path(draft.id), %{}, agent)
    assert route.status == 503 and route.body["error"]["code"] == "chain_unavailable"

    # Whatever else the operation hands the route, a policy's refusal or a raw
    # Ash error, is answered the same way.
    for error <- [
          Ash.Error.Forbidden.exception([]),
          Ash.Error.Unknown.exception(
            errors: [Ash.Error.Unknown.UnknownError.exception(error: "x")]
          ),
          :unexpected
        ] do
      {answered, log} =
        with_log(fn -> AgentLaunchAnswer.send(conn(:post, "/", ""), {:error, error}) end)

      assert answered.status == 503
      assert Jason.decode!(answered.resp_body)["error"]["code"] == "launch_unavailable"
      assert log =~ "agent launch failed"
    end
  end

  test "a pairing that ends while the request runs is refused agent_not_paired alike on both ways in, and nothing is kept" do
    base = fn -> with_memestock(person!(), %{"stock_address" => @aapl}) end

    robinhood = fn ->
      with_memestock(person!(), %{
        "chain" => "robinhood",
        "stock_address" => RobinhoodBidChain.stock()
      })
    end

    # Where it ends: as the person's draft is read, as the review is about to
    # be kept, and inside the write that keeps it, before its lock on the
    # pairing.
    for {asker, resource, action} <- [
          {fn -> person!() end, LaunchOperation, :agent_prepare},
          {base, StocksLaunchOperation, :agent_prepare},
          {robinhood, LaunchReview, :agent_record}
        ],
        {event, matching} <- [
          {[:ash, :autolaunch, :read, :start], %{action: :agent_read}},
          {[:ash, :autolaunch, :create, :start], %{action: action}},
          {[:ash, :before_action, :start], %{resource: resource, action: action}}
        ],
        way <- [:route, :tool] do
      who = asker.()
      arrange([], who.draft)
      named = "#{inspect(resource)} #{inspect(event)} on the #{way}"
      unpair_during(event, matching, who.agent)
      {body, log} = with_log(fn -> refusal(way, who) end)

      assert_received :unpaired, named

      assert body == plain(AgentLaunchAnswer.body(:agent_not_paired)),
             "#{named}: #{inspect(body)}"

      refute log =~ "agent launch", named
      assert kept(resource, who.account) == [], named
    end

    assert documented?(403, "agent_not_paired")
  end

  test "on the create page, a review whose draft no longer names a treasury is one to build again",
       %{account: account, draft: draft, wallet: wallet, opts: opts} do
    {:ok, page} = LaunchActions.prepare(draft.id, wallet, opts)
    assert LaunchActions.current(page, opts) == :current

    {:ok, _cleared} =
      Autolaunch.autosave_launch_treasury(draft, %{treasury: nil},
        actor: %Human{human_account_id: account.id}
      )

    assert LaunchActions.current(page, opts) == :changed
  end

  test "each reason the reviews, the wallet and the account give has one code, which both ways in answer in a status the contract documents; anything else is launch_unavailable" do
    codes = %{
      authentication_required: :authentication_required,
      wallet_required: :wallet_required,
      wrong_signer: :wrong_signer,
      launch_draft_not_found: :launch_draft_not_found,
      launch_metadata_incomplete: :launch_metadata_incomplete,
      agent_treasury_unconfirmed: :agent_treasury_unconfirmed,
      launch_treasury_invalid: :launch_treasury_invalid,
      launch_treasury_refused: :launch_treasury_refused,
      launches_paused: :launches_paused,
      strategy_not_bound: :strategy_not_bound,
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
      stock_invalid: :stock_invalid,
      unsupported_stock: :stock_invalid,
      invalid_address: :stock_invalid,
      stock_not_admitted: :stock_not_admitted,
      stocks_unavailable: :stocks_unavailable,
      robinhood_unavailable: :robinhood_unavailable,
      too_many_preparations: :too_many_preparations,
      chain_unavailable: :chain_unavailable,
      invalid_chain_response: :chain_unavailable,
      invalid_block_header: :chain_unavailable,
      transaction_missing: :chain_unavailable,
      wrong_chain: :chain_unavailable,
      launch_snapshot_incomplete: :chain_unavailable,
      treasury_observation_incomplete: :chain_unavailable,
      treasury_module_pagination_incomplete: :chain_unavailable,
      regent_address_mismatch: :launch_unavailable,
      lab_contract_missing: :launch_unavailable,
      launch_draft_unavailable: :launch_unavailable,
      session_unavailable: :launch_unavailable
    }

    assert Map.new(codes, fn {reason, _code} -> {reason, AgentLaunch.code(reason)} end) == codes

    for unexpected <- [:unnamed_reason, {:closed, :econnreset}, "text", nil, %{reason: :x}],
        do: assert(AgentLaunch.code(unexpected) == :launch_unavailable)

    for code <- Enum.uniq([:invalid_request | Map.values(codes)]) do
      answered = AgentLaunchAnswer.refuse(conn(:post, "/", ""), code)
      body = Jason.decode!(answered.resp_body)
      assert body == AgentLaunchAnswer.body(code) |> plain(), "#{code}"
      assert body["error"]["code"] == Atom.to_string(code)
      assert documented?(answered.status, body["error"]["code"]), "#{code} at #{answered.status}"
    end
  end

  property "any draft id and signer is answered or refused alike on both ways in, and only the person's own draft for their own wallet reaches a chain",
           %{agent: agent, draft: draft, wallet: wallet} do
    stranger = person!()
    meme = memestock!(agent, %{"stock_address" => @aapl})
    own = [draft.id, String.upcase(draft.id), meme.id]

    id =
      one_of([
        member_of(own ++ [stranger.draft.id, Ecto.UUID.generate(), "nope", "0x1", "1"]),
        string(:alphanumeric, min_length: 1, max_length: 40)
      ])

    signer =
      one_of([
        member_of([:none, wallet, @other, "nope", "", "0x"]),
        string(:printable, max_length: 50),
        integer(),
        boolean(),
        constant(nil),
        list_of(integer(), max_length: 2)
      ])

    check all(id <- id, signer <- signer, max_runs: 50) do
      input = if signer == :none, do: %{}, else: %{signer: signer}
      flush_reads()
      route = http(:post, launch_path(id), input, agent)
      read? = read?()

      assert tool(agent, "prepare_launch", Map.put(input, :draft, id)) == answer(route)
      assert route.status == 200 or route.body["error"]["code"] in @codes
      assert route.status == 200 or documented?(route.status, route.body["error"]["code"])

      # Only the person's own draft, for a wallet that is theirs, is read for;
      # a signer of no text but spaces is none, as Ash reads text.
      assert read? == (id in own and (signer == :none or text_of?(signer, ["", wallet]))),
             "#{inspect(id)} #{inspect(signer)} answered #{inspect(route.body)}"

      assert route.status == 200 == read?, inspect(route.body)
    end
  end

  test "in prelaunch read-only mode the tool is not listed or run, and the route waits",
       %{agent: agent, draft: draft} do
    Application.put_env(:autolaunch, :prelaunch_read_only, true)
    route = http(:post, launch_path(draft.id), %{}, agent)
    assert route.status == 503 and route.body["error"]["code"] == "prelaunch_read_only"
    assert documented?(503, "prelaunch_read_only")

    refute "prepare_launch" in tool_names(agent)
    assert %{"error" => _} = json(mcp(agent, call("prepare_launch", %{draft: draft.id})))
  end

  test "switched on a paired agent lists the tool; off, it is not listed, and a call to it is answered as one to no tool",
       %{agent: agent, draft: draft} do
    assert [%{"annotations" => annotations}] =
             Enum.filter(listed(agent), &(&1["name"] == "prepare_launch"))

    # It keeps the review it prepares, and sends nothing.
    assert annotations["readOnlyHint"] == false
    assert annotations["destructiveHint"] == false

    Application.put_env(:autolaunch, :agent_launches, :off)
    refute "prepare_launch" in tool_names(agent)

    # Off, a call to it, well formed or not, is answered exactly as one to a
    # tool that does not exist, in no words of agent launches.
    for arguments <- [
          %{"input" => %{draft: draft.id}},
          %{"input" => %{draft: draft.id, signer: @other}},
          %{"input" => "not an object"},
          %{"input" => %{bogus: "x"}},
          %{"input" => %{draft: 1, signer: false}},
          %{"input" => %{}},
          %{},
          "not an object"
        ] do
      called =
        mcp(agent, rpc("tools/call", %{"name" => "prepare_launch", "arguments" => arguments}))

      nothing =
        mcp(agent, rpc("tools/call", %{"name" => "no_such_tool", "arguments" => arguments}))

      said =
        called.resp_body
        |> IO.iodata_to_binary()
        |> String.replace("prepare_launch", "no_such_tool")

      assert {called.status, said} == {nothing.status, IO.iodata_to_binary(nothing.resp_body)},
             inspect(arguments)

      refute said =~ ~r/launch|draft|signer|wallet|steps|treasury/i
    end
  end

  # The agent's answer is the page's review for the same draft and wallet: its
  # chain, one step and facts, with the draft it is of, in the contract's shape.
  defp assert_page_answer(data, page, wallet, draft) do
    assert data["steps"] == plain(page.steps)
    assert data["facts"] == plain(page.facts)
    assert data["chain"] == plain(page.chain)
    assert %{"kind" => "launch", "signer" => ^wallet, "draft" => ^draft} = data
    assert data["block"] == page.facts["block_number"]
    assert Enum.sort(Map.keys(data)) == Enum.sort(@schemas["AgentLaunchSteps"]["required"])

    assert Enum.sort(@schemas["AgentLaunchSteps"]["properties"]["facts"]["required"]) --
             Map.keys(data["facts"]) == []

    assert [%{"kind" => "transaction", "step" => "launch", "value" => "0x0", "data" => calldata}] =
             data["steps"]

    assert String.ends_with?(calldata, String.replace_prefix(BuilderCode.suffix(), "0x", ""))
  end

  # The chains as one refusal case finds them, each `chain` names over its
  # defaults, read through the chain `draft` launches on; `unloadable` names a
  # deployment description the site is given at a path holding none.
  defp arrange(chain, draft) do
    TestAutolaunchLaunchChainClient.put(LaunchFixture.fixture(Keyword.get(chain, :revstake, [])))
    TestAutolaunchTreasuryChainClient.install(Keyword.get(chain, :treasury, []))
    RobinhoodBidChain.put(Keyword.get(chain, :robinhood, []))
    Process.delete(BaseLaunchpad)
    BaseLaunchpad.put(Keyword.get(chain, :base, []))

    Application.put_env(:autolaunch, :autolaunch_base_stocks_deployment, @stocks_deployment)
    Application.put_env(:autolaunch, :autolaunch_robinhood_deployment, @robinhood_deployment)

    if key = chain[:unloadable],
      do: Application.put_env(:autolaunch, key, Path.expand("../fixtures/none.json", __DIR__))

    if Map.get(draft, :chain) == :robinhood, do: robinhood_chain(), else: base_chain()
  end

  defp base_chain,
    do: Application.put_env(:autolaunch, :autolaunch_lab_http_client, BaseLaunchpad)

  defp robinhood_chain,
    do: Application.put_env(:autolaunch, :autolaunch_lab_http_client, RobinhoodBidChain)

  # A new person signed in with the launch fixture's wallet, their saved
  # Revstake draft with `draft` fields replaced, and an agent paired with them.
  defp person!(draft \\ %{}) do
    setup = LaunchFixture.actor(draft: draft)
    Map.new(setup) |> Map.put(:agent, paired_agent(setup[:account]))
  end

  # A new person whose Revstake draft their paired agent saved `fields` on.
  defp agent_saved(fields) do
    person = person!()
    {:ok, agent} = Autolaunch.Agents.resolve(person.agent)
    {:ok, draft} = AgentDrafts.save("revstake", fields, agent)
    %{person | draft: draft}
  end

  # `person` asking for the launch of their Memestock draft, as their agent
  # saves it with `fields`.
  defp with_memestock(person, fields), do: %{person | draft: memestock!(person.agent, fields)}

  # `person`'s agent asking for the launch of the draft `id`.
  defp asking(person, id), do: %{person | draft: %{id: id}}

  # The person's Memestock draft as their paired agent saves it: a whole
  # token with its picture, and `fields` over it.
  defp memestock!(agent, fields) do
    {:ok, resolved} = Autolaunch.Agents.resolve(agent)

    picture = %{
      "content_type" => "image/png",
      "data" => Base.encode64(File.read!("test/support/fixtures/launch-draft.png"))
    }

    {:ok, draft} =
      AgentDrafts.save(
        "memestock",
        Map.merge(
          %{
            "name" => "Apple Pair",
            "symbol" => "APLP",
            "description" => "A pair with Apple.",
            "image" => picture
          },
          fields
        ),
        resolved
      )

    draft
  end

  # The reviews `resource` keeps for `account`'s person.
  defp kept(resource, account) do
    resource
    |> Ash.Query.filter(human_account_id == ^account.id)
    |> Ash.read!(actor: %System{})
  end

  # The agent's own preparation of `draft`, as `resource` keeps it: the review
  # `n` names, read at `block`, or `review` itself.
  defp prepare!(resource, draft, agent, n, block \\ 30) do
    {:ok, kept} = prepare(resource, draft, agent, n, block)
    kept
  end

  defp prepare(resource, draft, agent, n, block \\ 30)

  defp prepare(resource, draft, agent, n, block) when is_integer(n) do
    review = %{
      "chain" => %{"chain_id" => 8453},
      "step" => %{"step" => "launch", "data" => "0x0#{n}"},
      "facts" => %{"n" => n, "block_number" => block, "block_hash" => "0x0#{block}"}
    }

    prepare(resource, draft, agent, review, block)
  end

  defp prepare(resource, draft, agent, review, _block) do
    resource
    |> Ash.Changeset.for_create(
      :agent_prepare,
      %{
        action_id: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
        launch_draft_id: draft.id,
        review: review,
        signer: LaunchFixture.wallet(),
        step: :launch
      },
      actor: agent
    )
    |> Ash.create()
  end

  # Whether a preparation was refused for want of room.
  defp too_many?(answer),
    do:
      match?(
        {:error,
         %Ash.Error.Invalid{
           errors: [%Ash.Error.Invalid.Unavailable{reason: :too_many_preparations}]
         }},
        answer
      )

  # `rows` of `resource` as if written more than 24 hours ago, oldest first,
  # one hour apart. No action writes inserted_at, so the test sets it itself.
  defp age!(resource, rows) do
    rows
    |> Enum.with_index()
    |> Enum.each(fn {row, n} ->
      at = DateTime.add(DateTime.utc_now(), n - 24 - length(rows), :hour)

      {1, _rows} =
        Repo.update_all(from(r in resource, where: r.id == ^row.id), set: [inserted_at: at])
    end)
  end

  # The Robinhood launch `n` names, for the launch fixture's wallet.
  defp robinhood_review(n) do
    %{
      chain_id: 4_663,
      signer: LaunchFixture.wallet(),
      name: "Pair #{n}",
      symbol: "PR#{n}",
      stock: RobinhoodBidChain.stock()
    }
  end

  # The agent's own Robinhood review of `fields`, as `LaunchReview` keeps it.
  defp record!(agent, fields) do
    {:ok, kept} = record(agent, fields)
    kept
  end

  defp record(agent, fields) do
    LaunchReview
    |> Ash.Changeset.for_create(:agent_record, fields, actor: agent)
    |> Ash.create()
  end

  # Whether the contract documents `code` for the route answering `status`.
  defp documented?(status, code) do
    response =
      get_in(@contract, ["paths", @path, "post", "responses", Integer.to_string(status)])

    code in @codes and is_map(response) and response["description"] =~ ~r/\b#{code}\b/
  end

  # Whether `value` is text that reads as one of `texts`, its outer spaces aside.
  defp text_of?(value, texts), do: is_binary(value) and String.trim(value) in texts

  defp flush_reads do
    receive do
      {:chain_read, _method} -> flush_reads()
      {:robinhood_read, _method} -> flush_reads()
    after
      0 -> :ok
    end
  end

  # Whether any chain was read since the reads were last flushed.
  defp read? do
    receive do
      {:chain_read, _method} -> true
      {:robinhood_read, _method} -> true
    after
      0 -> false
    end
  end

  defp launch_path(draft),
    do: "/api/agent/v1/launches/#{URI.encode(draft, &URI.char_unreserved?/1)}/steps"

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

  # The error document `who`'s agent is answered with on `way` in: the route's,
  # or the tool's error, or, once the pairing has ended, the whole answer every
  # signed request is given then (`AutolaunchWeb.Plugs.AgentAccess`).
  defp refusal(:route, who) do
    route = http(:post, launch_path(who.draft.id), %{}, who.agent)
    assert route.status == 403
    route.body
  end

  defp refusal(:tool, who) do
    case json(mcp(who.agent, call("prepare_launch", %{draft: who.draft.id}))) do
      %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} -> Jason.decode!(text)
      %{"error" => %{"code" => _code}} = replaced -> replaced
    end
  end

  # Once the request's own `event` starts with `matching` in its metadata, the
  # person unpairs `agent`, once.
  defp unpair_during(event, matching, agent) do
    {:ok, actor} = Autolaunch.Agents.resolve(agent)
    person = %RegentAgents.Person{privy_user_id: actor.privy_user_id}
    id = {__MODULE__, make_ref()}
    test = self()

    :ok =
      :telemetry.attach(
        id,
        event,
        fn _event, _measurements, metadata, _config ->
          if Map.take(metadata, Map.keys(matching)) == matching do
            :telemetry.detach(id)
            [paired] = RegentAgents.list_my_agents!(actor: person)
            :ok = RegentAgents.unpair_agent!(paired, actor: person)
            send(test, :unpaired)
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
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

  # A route's answer as the hosted tool gives it: its `data`, or its refusal.
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
