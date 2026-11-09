defmodule Autolaunch.LaunchDiscoveryTest do
  use AutolaunchWeb.ConnCase, async: false

  require Ash.Query

  alias Autolaunch.{
    Accounts,
    Auction,
    BaseRpcStub,
    Lab,
    LabAbi,
    LaunchDiscovery,
    LaunchFixture,
    LaunchOperation,
    LaunchReviews
  }

  alias Autolaunch.Actors.System
  alias Autolaunch.Chain.{Abi, LaunchAbi}
  alias Autolaunch.Stocks.Lab, as: StocksLab

  @actor %System{}
  @hash "0x" <> String.duplicate("4c", 32)
  @auction "0xa1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
  @subject "0xb2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"
  @escrow "0xc3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3"
  @stranger "0x9999999999999999999999999999999999999999"
  @other_wallet "0x2222222222222222222222222222222222222222"
  @launch_id 1
  # Bidding opens START_DELAY_BLOCKS after the block the launch was made in.
  @start_delay 300
  @start_block 30_001_800

  setup do
    LaunchFixture.install(
      outcomes: %{
        launch: %{
          outcome: :confirmed,
          result: %{
            "launch_id" => "1",
            "subject" => @subject,
            "auction" => @auction,
            "escrow" => @escrow,
            "treasury" => LaunchFixture.treasury(),
            "start_block" => "30001800",
            "end_block" => "30088201"
          }
        }
      }
    )

    BaseRpcStub.install(:autolaunch_lab_http_client, &answer(&1, &2))

    BaseRpcStub.put(%{
      blocks: %{
        "latest" => %{
          "number" => "0x1c9caf0",
          "hash" => BaseRpcStub.safe_hash(),
          "timestamp" => "0x6700"
        }
      },
      memestock: StocksLab.address!(StocksLab.current!(), :launchpad),
      logs: [%{"transactionHash" => @hash}]
    })

    # The site starts its jobs only once launches open; the test runs them by hand.
    start_supervised!(
      {Oban,
       AshOban.config(
         Application.fetch_env!(:autolaunch, :ash_domains),
         Application.fetch_env!(:autolaunch, Oban)
       )}
    )

    context = LaunchFixture.actor()
    operation = review!(context[:account], context[:draft], LaunchFixture.wallet())
    context |> Map.new() |> Map.put(:operation, operation)
  end

  test "a launch whose page closed before it was confirmed is listed once, for its creator",
       %{account: account, operation: operation} do
    # The wallet sent the review's step, and the page was closed.
    record_launch(LaunchFixture.wallet())
    run_triggers()

    # The transaction is the one whose `LaunchCreated` names this launch, in
    # the block the launch was made in.
    created = quantity(@start_block - @start_delay)

    assert_received {:rpc, "eth_getLogs",
                     [%{fromBlock: ^created, toBlock: ^created, topics: [topic, launch]}]}

    assert topic == LaunchAbi.selector(:launch_created)
    assert launch == word(@launch_id)

    assert [%{state: :listed, creator_human_account_id: creator}] = discoveries()
    assert creator == account.id
    assert [auction] = auctions()
    assert auction.creator_human_account_id == account.id
    assert auction.state == :created

    assert %{state: :chain_verified, terminal_at: %DateTime{}} = reload(operation)
  end

  test "a replayed launch lists nothing twice and takes no auction back to its start",
       %{account: account, operation: operation} do
    record_launch(LaunchFixture.wallet())
    run_triggers()

    [auction] = auctions()

    {:ok, _} =
      auction
      |> Ash.Changeset.for_update(:refresh_lab_market, %{state: :graduated}, actor: @actor)
      |> Ash.update(actor: @actor)

    # Discovery runs again, and the page that sent it sees it confirmed after all.
    record_launch(LaunchFixture.wallet())
    run_triggers()

    assert {:listed, _account_id, _result} = confirm_in_browser(operation)

    assert [%{state: :listed, creator_human_account_id: creator}] = discoveries()
    assert creator == account.id
    assert [%{state: :graduated, creator_human_account_id: ^creator}] = auctions()
  end

  test "a creator who signs in with another wallet after sending still gets the launch",
       %{account: account} do
    {:ok, _} =
      Accounts.refresh_verified(account, @other_wallet, [@other_wallet], actor: @actor)

    record_launch(LaunchFixture.wallet())
    run_triggers()

    assert [%{state: :listed, creator_human_account_id: creator}] = discoveries()
    assert creator == account.id
    assert [%{creator_human_account_id: ^creator}] = auctions()
  end

  describe "the creator's own browser confirming a new launch" do
    # Ash sends a notification only outside every transaction, so receiving
    # it proves it went out after the session's transaction committed.
    test "announces the new auction exactly once, after commit",
         %{operation: operation} do
      Autolaunch.Listings.subscribe()

      assert {:listed, _account_id, _result} = confirm_in_browser(operation)

      assert [%{id: auction_id}] = auctions()
      assert_received {:autolaunch_listings_changed, ^auction_id}
      refute_received {:autolaunch_listings_changed, _another}
    end

    test "announces nothing when the confirmation rolls back",
         %{operation: operation} do
      refuse_inserts("launch_jobs")
      Autolaunch.Listings.subscribe()

      # The launch job is written after the auction, inside the same transaction.
      assert {:pending, _reason} = confirm_in_browser(operation)

      assert auctions() == []
      refute_received {:autolaunch_listings_changed, _auction_id}
    end
  end

  test "a launch no review of this site carried out stays unlisted" do
    record_launch(@stranger)
    run_triggers()

    assert [%{state: :unlisted, reason: "no_matching_review"}] = discoveries()
    assert auctions() == []
  end

  test "another account's review for another wallet is never matched to this launch",
       %{account: account, operation: operation} do
    other =
      Accounts.register_verified!(
        "did:privy:other-#{Elixir.System.unique_integer([:positive])}",
        @other_wallet,
        [@other_wallet],
        actor: @actor
      )

    other_draft = LaunchFixture.draft!(%Autolaunch.Actors.Human{human_account_id: other.id})
    other_operation = review!(other, other_draft, @other_wallet)

    record_launch(LaunchFixture.wallet())
    run_triggers()

    assert [%{state: :listed, creator_human_account_id: creator}] = discoveries()
    assert creator == account.id
    assert [%{creator_human_account_id: ^creator}] = auctions()
    assert %{state: :chain_verified} = reload(operation)
    assert %{state: :prepared, terminal_at: nil} = reload(other_operation)
  end

  # The page sees its own press confirmed and lists the launch at once.
  defp confirm_in_browser(operation),
    do: LaunchReviews.confirm(:launch, operation.action_id, @hash)

  defp refuse_inserts(table) do
    Autolaunch.Repo.query!("""
    CREATE FUNCTION pg_temp.refuse_insert() RETURNS trigger LANGUAGE plpgsql
    AS $$ BEGIN RAISE EXCEPTION 'insert refused'; END $$
    """)

    Autolaunch.Repo.query!(
      ~s(CREATE TRIGGER refuse_insert BEFORE INSERT ON "#{Autolaunch.Repo.default_prefix()}".#{table} ) <>
        "FOR EACH ROW EXECUTE FUNCTION pg_temp.refuse_insert()"
    )
  end

  # One saved launch review, as `LaunchActions.prepare` stores it for `account`.
  defp review!(account, draft, signer) do
    deployment = Lab.current!()
    factory = Lab.address!(deployment, :factory)

    review = %{
      "chain" => %{
        "chain_id" => deployment.chain_id,
        "name" => "Base",
        "rpc_url" => deployment.public_rpc_url
      },
      "signer" => signer,
      "step" => %{"kind" => "transaction", "step" => "launch", "to" => factory, "data" => "0x"},
      "facts" => %{
        "name" => "Open Research",
        "symbol" => "OPEN",
        "description" => "A launch profile awaiting review.",
        "website" => "https://example.test/open",
        "links" => [],
        "image" => nil,
        "regent" => Abi.regent_address(),
        "terms" => %{"required_regent_raised" => "1084202174"},
        "factory" => factory,
        "treasury" => LaunchFixture.treasury(),
        "hook" => LaunchFixture.hook()
      }
    }

    LaunchOperation
    |> Ash.Changeset.for_create(
      :prepare,
      %{
        action_id: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
        review: review,
        signer: signer,
        step: :launch,
        human_account_id: account.id,
        launch_draft_id: draft.id
      },
      actor: @actor
    )
    |> Ash.create!(actor: @actor)
  end

  # Discovery reads the factory's launch, sent from `launcher`.
  defp record_launch(launcher) do
    BaseRpcStub.put(%{launcher: launcher})

    LaunchDiscovery
    |> Ash.ActionInput.for_action(:discover, %{}, actor: @actor)
    |> Ash.run_action!()
  end

  # The factory's one launch and the strategy's record of its auction. The
  # Memestock launchpad on the same chain has made none.
  defp answer(%{to: to, data: data}, state) do
    selector = String.slice(data, 0, 10)

    words =
      cond do
        to == state.memestock ->
          [BaseRpcStub.hex_word(1)]

        selector == LabAbi.selector("nextLaunchId()") ->
          [BaseRpcStub.hex_word(@launch_id + 1)]

        selector == LabAbi.selector("launches(uint256)") ->
          Enum.map(
            [state.launcher, @subject, @auction, @escrow, LaunchFixture.treasury()],
            &BaseRpcStub.address_word/1
          )

        selector == LabAbi.selector("distribution(address)") ->
          List.duplicate(0, LabAbi.distribution_words())
          |> List.replace_at(0, 1)
          |> List.replace_at(1, @start_block)
          |> Enum.map(&BaseRpcStub.hex_word/1)

        selector == LabAbi.selector("START_DELAY_BLOCKS()") ->
          [BaseRpcStub.hex_word(@start_delay)]
      end

    "0x" <> Enum.join(words)
  end

  defp run_triggers,
    do: AshOban.Test.schedule_and_run_triggers(LaunchDiscovery, actor: @actor)

  defp discoveries, do: Ash.read!(LaunchDiscovery, actor: @actor)

  defp auctions,
    do: Ash.read!(Auction, actor: @actor)

  defp reload(operation),
    do: LaunchOperation |> Ash.Query.filter(id == ^operation.id) |> Ash.read_one!(actor: @actor)

  defp quantity(number), do: "0x" <> String.downcase(Integer.to_string(number, 16))

  defp word(number),
    do: "0x" <> String.pad_leading(String.downcase(Integer.to_string(number, 16)), 64, "0")
end
