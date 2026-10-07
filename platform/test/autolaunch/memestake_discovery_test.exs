defmodule Autolaunch.MemestakeDiscoveryTest do
  @moduledoc """
  A Base Memestake launch is listed from the launchpad's own record and the
  transaction that created it, with no browser report: once, for the account
  whose review sent it, never for a launch this site did not review, and not
  until the chain can answer for it.
  """

  use AutolaunchWeb.ConnCase, async: false

  require Ash.Query

  alias Autolaunch.{Accounts, Auction, BaseRpcStub, LabAbi, LaunchDiscovery, LaunchReviews}
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.Chain.{Abi, Client}
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi
  alias Autolaunch.Stocks.{LaunchOperation, LaunchOperations}

  @actor %System{}
  @launcher "0x1414141414141414141414141414141414141414"
  @stranger "0x9999999999999999999999999999999999999999"
  @new_token "0xa2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2"
  @auction "0xa1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
  @stock "0xb200000000000000000000c2e324d24d7eecd1fb"
  @hash "0x" <> String.duplicate("4d", 32)
  @data "0x" <> String.duplicate("ab", 36)
  @launch_id 1
  # Bidding opens START_LEAD_BLOCKS (300) after the block the launch was made in.
  @created_block 10
  @start_block @created_block + 300
  @end_block @start_block + 1_000
  @floor 79_228_162_514_264_337_593_543_900
  @required 100_000_000

  setup do
    config = StocksLab.current!()
    launchpad = StocksLab.address!(config, :launchpad)

    BaseRpcStub.install(:autolaunch_lab_http_client, &answer(&1, &2))

    BaseRpcStub.put(%{
      blocks: %{"latest" => %{"number" => "0x20", "hash" => BaseRpcStub.safe_hash()}},
      launchpad: launchpad,
      launcher: @launcher
    })

    start_supervised!(
      {Oban,
       AshOban.config(
         Application.fetch_env!(:autolaunch, :ash_domains),
         Application.fetch_env!(:autolaunch, Oban)
       )}
    )

    account =
      Accounts.register_verified!(
        "did:privy:memestake-#{Elixir.System.unique_integer([:positive])}",
        @launcher,
        [@launcher],
        actor: @actor
      )

    %{config: config, launchpad: launchpad, account: account, operation: review!(account, config)}
  end

  test "a launch whose page closed before it was confirmed is listed once, for its creator",
       %{account: account, operation: operation, launchpad: launchpad} do
    mined(launchpad)
    Autolaunch.Listings.subscribe()

    discover()
    run_triggers()

    assert [%{state: :listed, creator_human_account_id: creator, reason: nil}] = discoveries()
    assert creator == account.id

    assert [%{kind: :stocks, state: :created, auction_address: @auction} = auction] = auctions()
    assert auction.creator_human_account_id == account.id

    auction_id = auction.id
    assert_received {:autolaunch_listings_changed, ^auction_id}
    refute_received {:autolaunch_listings_changed, _another}

    assert %{state: :chain_verified} = reload(operation)
  end

  # Ash sends a notification only outside every transaction, so receiving it
  # proves it went out after the session's transaction committed.
  test "the creator's own browser confirming a new launch announces it exactly once",
       %{account: account, operation: operation, launchpad: launchpad} do
    mined(launchpad)
    Autolaunch.Listings.subscribe()

    assert {:listed, _account_id, _result} = confirm_in_browser(operation)

    assert [%{id: auction_id, creator_human_account_id: creator}] = auctions()
    assert creator == account.id
    assert_received {:autolaunch_listings_changed, ^auction_id}
    refute_received {:autolaunch_listings_changed, _another}
  end

  test "a replayed launch lists nothing twice and takes no auction back to its start",
       %{account: account, operation: operation, launchpad: launchpad} do
    mined(launchpad)
    discover()
    run_triggers()

    [auction] = auctions()
    Ash.update!(auction, %{state: :graduated}, action: :refresh_lab_market, actor: @actor)

    # The job runs again and records the same launch again, and the page that
    # sent it sees it confirmed after all.
    discover()
    [discovery] = discoveries()

    {:ok, _} =
      Autolaunch.record_launch_discovery(Map.take(discovery, record_fields()), actor: @actor)

    run_triggers()

    assert {:listed, _account_id, _result} = confirm_in_browser(operation)

    assert [%{state: :listed, creator_human_account_id: creator}] = discoveries()
    assert creator == account.id
    assert [%{state: :graduated, creator_human_account_id: ^creator}] = auctions()
  end

  test "a launch made outside the site is not listed", %{launchpad: launchpad} do
    BaseRpcStub.put(%{launcher: @stranger})
    mined(launchpad)

    discover()
    run_triggers()

    assert [%{state: :unlisted, reason: "no_matching_review", launcher: @stranger}] =
             discoveries()

    assert auctions() == []
  end

  test "a launch the chain cannot answer for yet stays pending with the reason",
       %{account: account, operation: operation, launchpad: launchpad} do
    mined(launchpad)
    BaseRpcStub.put(%{receipts: %{@hash => :unavailable}})

    discover()
    run_triggers()

    assert [%{state: :pending, reason: "chain_unavailable"}] = discoveries()
    assert auctions() == []
    assert %{state: :prepared} = reload(operation)

    mined(launchpad)
    run_triggers()

    assert [%{state: :listed, creator_human_account_id: creator, reason: nil}] = discoveries()
    assert creator == account.id
    assert [_auction] = auctions()
  end

  # The page sees its own press confirmed and lists the launch at once.
  defp confirm_in_browser(operation),
    do: LaunchReviews.confirm(:stocks_launch, operation.action_id, @hash)

  # One reviewed Memestake launch for `account`, as `prepare` stores it.
  defp review!(account, config) do
    draft =
      Autolaunch.create_stocks_launch_draft!(%{}, actor: %Human{human_account_id: account.id})

    launchpad = StocksLab.address!(config, :launchpad)

    review =
      %{
        "chain" => Client.chain(config),
        "signer" => @launcher,
        "step" => %{
          "kind" => "transaction",
          "step" => "launch",
          "to" => launchpad,
          "data" => @data
        },
        "facts" => %{
          "draft_id" => draft.id,
          "name" => "Mint Research",
          "symbol" => "MINT",
          "description" => "A Memestake launch awaiting review.",
          "website" => "https://example.test/mint",
          "links" => [],
          "image" => nil,
          "stock" => @stock,
          "stock_symbol" => "AAPLc",
          "stock_decimals" => "8",
          "required_stock_raised" => Integer.to_string(@required),
          "floor_price_q96" => Integer.to_string(@floor),
          "launchpad" => launchpad
        }
      }
      |> Jason.encode!()
      |> Jason.decode!()

    {:ok, operation} =
      LaunchOperations.create(account, %{
        action_id: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
        launch_draft_id: draft.id,
        review: review,
        signer: @launcher,
        step: :launch
      })

    operation
  end

  # The launch transaction, mined and past the safe head, with its one
  # `StockLaunchCreated`.
  defp mined(launchpad) do
    %{launcher: launcher} = BaseRpcStub.state()
    log = launch_log(launchpad, launcher)
    number = "0x" <> Integer.to_string(@created_block, 16)

    BaseRpcStub.put(%{
      logs: [log],
      receipts: %{@hash => BaseRpcStub.receipt(@hash, number, [log])},
      transactions: %{
        @hash => %{
          "hash" => @hash,
          "from" => launcher,
          "to" => launchpad,
          "input" => @data,
          "value" => "0x0"
        }
      }
    })
  end

  defp launch_log(launchpad, launcher) do
    %{
      "address" => launchpad,
      "blockHash" => BaseRpcStub.receipt_block_hash(),
      "transactionHash" => @hash,
      "topics" => [
        Abi.topic0(StocksLabAbi.launch_created_signature()),
        BaseRpcStub.uint(@launch_id),
        BaseRpcStub.address_topic(launcher),
        BaseRpcStub.address_topic(@new_token)
      ],
      "data" =>
        "0x" <>
          Enum.join([
            BaseRpcStub.address_word(@stock),
            BaseRpcStub.address_word(@auction),
            BaseRpcStub.hex_word(@start_block),
            BaseRpcStub.hex_word(@end_block),
            BaseRpcStub.hex_word(495 * 10 ** 24),
            BaseRpcStub.hex_word(495 * 10 ** 24),
            BaseRpcStub.hex_word(10 ** 25)
          ])
    }
  end

  # The launchpad's reads: one launch so far, its record, and its auction index.
  defp answer(data, state) do
    selector = String.slice(data, 0, 10)

    words =
      cond do
        selector == LabAbi.selector("nextLaunchId()") ->
          [BaseRpcStub.hex_word(@launch_id + 1)]

        selector == LabAbi.selector("launchIdOfAuction(address)") ->
          [BaseRpcStub.hex_word(@launch_id)]

        selector == LabAbi.selector("launches(uint256)") ->
          launch_record(state.launcher)
      end

    "0x" <> Enum.join(words)
  end

  # launcher, newToken, stock, auction, splitter, startBlock, endBlock,
  # claimBlock, migrationBlock, lifecycle, then the rest of the twenty words.
  defp launch_record(launcher) do
    [
      BaseRpcStub.address_word(launcher),
      BaseRpcStub.address_word(@new_token),
      BaseRpcStub.address_word(@stock),
      BaseRpcStub.address_word(@auction),
      BaseRpcStub.hex_word(0),
      BaseRpcStub.hex_word(@start_block),
      BaseRpcStub.hex_word(@end_block),
      BaseRpcStub.hex_word(@end_block + 64),
      BaseRpcStub.hex_word(@end_block + 128),
      BaseRpcStub.hex_word(1)
    ] ++ List.duplicate(BaseRpcStub.hex_word(0), 10)
  end

  defp discover do
    LaunchDiscovery
    |> Ash.ActionInput.for_action(:discover_memestake, %{}, actor: @actor)
    |> Ash.run_action!()
  end

  defp run_triggers,
    do: AshOban.Test.schedule_and_run_triggers(LaunchDiscovery, actor: @actor)

  defp record_fields,
    do: [:launchpad, :chain_id, :contract, :launch_id, :launcher, :auction, :transaction_hash]

  defp discoveries, do: Ash.read!(LaunchDiscovery, actor: @actor)

  defp auctions, do: Ash.read!(Auction, actor: @actor)

  defp reload(operation),
    do: LaunchOperation |> Ash.Query.filter(id == ^operation.id) |> Ash.read_one!(actor: @actor)
end
