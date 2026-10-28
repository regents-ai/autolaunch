defmodule Autolaunch.MemestockDiscoveryTest do
  @moduledoc """
  A Base Memestock launch is listed from the launchpad's own record and the
  transaction that created it, with no browser report: once, for the account
  whose review sent it, and not until the chain can answer for it. A launch
  this site did not review is listed too, under the wallet that sent it, with
  only what passes the create page's checks.
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
  # The launchpad the first Memestock launches used, which this site no longer runs.
  @retired "0x7777777777777777777777777777777777777777"
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
      blocks: %{
        "latest" => %{
          "number" => "0x20",
          "hash" => BaseRpcStub.safe_hash(),
          "timestamp" => "0x6700"
        }
      },
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
        "did:privy:memestock-#{Elixir.System.unique_integer([:positive])}",
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

  test "a launch made outside the site is listed under the wallet that sent it, with only what passes the site's checks",
       %{launchpad: launchpad} do
    admit_stock()

    BaseRpcStub.put(%{
      launcher: @stranger,
      token: %{
        "name()" => <<0xFF, 0xFE>> <> " Stranger\u202E\n Coin\u200B\u0007 ",
        "symbol()" => "STRG",
        "tokenURI()" =>
          token_uri(%{
            "description" => "Made\u0000 elsewhere.\nSecond line.",
            "website" => "javascript:alert(1)",
            "image" =>
              "https://elsewhere.example/stock-images/#{Ecto.UUID.generate()}/#{String.duplicate("a", 64)}"
          })
      }
    })

    mined(launchpad)
    Autolaunch.Listings.subscribe()

    discover()
    run_triggers()

    assert [%{state: :listed, creator_human_account_id: nil, reason: nil, launcher: @stranger}] =
             discoveries()

    assert [auction] = auctions()

    assert %{
             origin: :chain,
             kind: :stocks,
             state: :created,
             auction_address: @auction,
             token_address: @new_token,
             creator_human_account_id: nil,
             creator_address: @stranger,
             title: "Stranger Coin",
             token_symbol: "STRG",
             summary: "Made elsewhere.\nSecond line.",
             website: nil,
             image: nil,
             quote_token_symbol: "AAPLc",
             quote_token_decimals: 8
           } = auction

    auction_id = auction.id
    assert_received {:autolaunch_listings_changed, ^auction_id}

    # The public lists carry it and its page opens, as for every listed launch.
    assert [%{id: ^auction_id}] =
             Auction |> Ash.Query.for_read(:listed, %{}, actor: nil) |> Ash.read!()

    assert %{id: ^auction_id} =
             Auction
             |> Ash.Query.for_read(:public_by_id, %{id: auction_id}, actor: nil)
             |> Ash.read_one!()

    # An operator can still hide it, as any listed launch.
    {:ok, _hidden} = Autolaunch.hide_auction(auction, actor: @actor)

    assert nil ==
             Auction
             |> Ash.Query.for_read(:public_by_id, %{id: auction_id}, actor: nil)
             |> Ash.read_one!()
  end

  test "a launch whose ticker breaks the site's rule is not listed", %{launchpad: launchpad} do
    admit_stock()

    BaseRpcStub.put(%{
      launcher: @stranger,
      token: %{"name()" => "Dots", "symbol()" => "..", "tokenURI()" => token_uri(%{})}
    })

    mined(launchpad)
    discover()
    run_triggers()

    assert [%{state: :unlisted, reason: "invalid_metadata"}] = discoveries()
    assert auctions() == []
  end

  test "a launch whose metadata is not readable is not listed", %{launchpad: launchpad} do
    admit_stock()

    BaseRpcStub.put(%{
      launcher: @stranger,
      token: %{
        "name()" => "Garbled",
        "symbol()" => "GRBL",
        "tokenURI()" => "data:application/json;base64,not base64"
      }
    })

    mined(launchpad)
    discover()
    run_triggers()

    assert [%{state: :unlisted, reason: "invalid_metadata"}] = discoveries()
    assert auctions() == []
  end

  test "a description cut inside a character is listed with its whole characters",
       %{launchpad: launchpad} do
    admit_stock()
    json = ~s({"description":"caf) <> <<0xC3>> <> ~s("})

    BaseRpcStub.put(%{
      launcher: @stranger,
      token: %{
        "name()" => "Cut",
        "symbol()" => "CUT",
        "tokenURI()" => "data:application/json;base64," <> Base.encode64(json)
      }
    })

    mined(launchpad)
    discover()
    run_triggers()

    assert [%{state: :listed}] = discoveries()
    assert [%{summary: "caf"}] = auctions()
  end

  test "a launch taken again that the site cannot list yet waits, and is listed once it can",
       %{launchpad: launchpad} do
    BaseRpcStub.put(%{
      launcher: @stranger,
      token: %{"name()" => "Waiting", "symbol()" => "WAIT", "tokenURI()" => token_uri(%{})}
    })

    mined(launchpad)
    discover()

    {1, _rows} =
      Autolaunch.Repo.update_all("launch_discoveries",
        set: [state: "unlisted", reason: "no_matching_review"]
      )

    # Its stock is not saved yet: the launch waits for it.
    run_triggers()
    assert [%{state: :pending, reason: "unsupported_stock"}] = discoveries()

    admit_stock()
    Autolaunch.Stocks.Assets.changed()
    run_triggers()

    assert [%{state: :listed}] = discoveries()
    assert [%{token_symbol: "WAIT"}] = auctions()
  end

  test "a launch an earlier pass left unlisted is listed on the next; one on a retired launchpad stays unlisted",
       %{launchpad: launchpad} do
    admit_stock()

    BaseRpcStub.put(%{
      launcher: @stranger,
      token: %{"name()" => "Earlier", "symbol()" => "EARLY", "tokenURI()" => token_uri(%{})}
    })

    mined(launchpad)
    discover()
    [discovery] = discoveries()

    {:ok, _retired} =
      Autolaunch.record_launch_discovery(
        %{Map.take(discovery, record_fields()) | contract: @retired},
        actor: @actor
      )

    # As the site left them before every Base Memestock launch was listed.
    {2, _rows} =
      Autolaunch.Repo.update_all("launch_discoveries",
        set: [state: "unlisted", reason: "no_matching_review"]
      )

    run_triggers()

    assert [
             %{state: :listed, contract: ^launchpad},
             %{state: :unlisted, reason: "launchpad_retired"}
           ] =
             Enum.sort_by(discoveries(), &(&1.contract != launchpad))

    assert [%{token_symbol: "EARLY", origin: :chain}] = auctions()
  end

  test "a launch seen only on another chain is stored but not listed" do
    for chain_id <- [46_630, 84_532] do
      {:ok, _row} =
        Autolaunch.record_launch_auction(
          %{
            kind: :stocks,
            origin: :chain,
            chain_id: chain_id,
            auction_address: "0x" <> String.duplicate(Integer.to_string(rem(chain_id, 10)), 40),
            creator_address: @stranger,
            title: "Elsewhere",
            token_symbol: "ELSE",
            featured: false,
            state: :active,
            current_clearing_price: "0",
            quote_token_address: @stock,
            quote_token_symbol: "AAPLc",
            quote_token_decimals: 8,
            required_currency_raised: "1",
            treasury_address: @stranger
          },
          actor: @actor
        )
    end

    assert [] = Auction |> Ash.Query.for_read(:listed, %{}, actor: nil) |> Ash.read!()
    assert [] = Auction |> Ash.Query.for_read(:list_public, %{}, actor: nil) |> Ash.read!()
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

  # One reviewed Memestock launch for `account`, as `prepare` stores it.
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
          "description" => "A Memestock launch awaiting review.",
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
            BaseRpcStub.hex_word(4975 * 10 ** 23),
            BaseRpcStub.hex_word(4975 * 10 ** 23),
            BaseRpcStub.hex_word(5 * 10 ** 24)
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

        true ->
          token_string(selector, Map.get(state, :token, %{}))
      end

    "0x" <> Enum.join(words)
  end

  # The launch's token: its name, symbol and metadata, as the launch wrote them.
  # Its bytes as the contract holds them, which need not be valid text.
  defp token_string(selector, strings) do
    {_signature, value} =
      Enum.find(strings, fn {signature, _value} -> LabAbi.selector(signature) == selector end)

    hex = Base.encode16(value, case: :lower)
    padded = String.pad_trailing(hex, div(byte_size(hex) + 63, 64) * 64, "0")
    [BaseRpcStub.hex_word(32), BaseRpcStub.hex_word(byte_size(value)), padded]
  end

  defp token_uri(metadata),
    do: "data:application/json;base64," <> Base.encode64(Jason.encode!(metadata))

  defp admit_stock do
    Autolaunch.record_stock_admission!(
      %{
        chain_id: 8453,
        address: @stock,
        symbol: "AAPLc",
        name: "Apple Inc.",
        decimals: 8,
        route: "0x" <> String.duplicate("66", 20),
        admitted: true
      },
      actor: @actor
    )
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
    |> Ash.ActionInput.for_action(:discover_memestock, %{}, actor: @actor)
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
