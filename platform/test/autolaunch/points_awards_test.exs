defmodule Autolaunch.PointsAwardsTest do
  # A launch, a graduation or a Base bid the site saves offers Regent Points its
  # awards in the same transaction, and the site's own check (Autolaunch.Points.Launch,
  # .Graduation and .Bid) answers from those saved rows. Autolaunch earns nothing (no
  # start time, no rule approved), so each test opens the four rules for itself, runs
  # the real library's queue, and reads what it wrote. Bids reach the site through the
  # auction's real reader, over a chain double.
  use Autolaunch.DataCase, async: false
  use Oban.Testing, repo: Autolaunch.Repo
  import Autolaunch.PointsTesting

  alias Autolaunch.{
    Accounts,
    Auction,
    AuctionActivity,
    BaseRpcStub,
    Lab,
    LabAbi,
    LabProjection,
    TestSupport
  }

  alias Autolaunch.Actors.System
  alias Autolaunch.Points.{Bid, Graduation, Launch}
  alias RegentPoints.Store

  @bid "autolaunch.auction_bid"
  @rules [
    "autolaunch.first_launch",
    "autolaunch.auction_created",
    "autolaunch.first_graduation",
    @bid
  ]
  @wallet "0x" <> String.duplicate("c", 40)
  @stranger "0x" <> String.duplicate("d", 40)
  @unit RegentPoints.Rules.unit()

  # The chain double's auction: opened at block 900, its bids in block 950, the head
  # at block 1,000.
  @auction "0x" <> String.duplicate("b1", 20)
  @head 1_000
  @bid_block 950
  @start_block 900
  @end_block 2_000
  @now 1_790_000_000
  @head_hash "0x" <> String.duplicate("5a", 32)
  @bid_hash "0x" <> String.duplicate("7b", 32)
  @transaction "0x" <> String.duplicate("4d", 32)
  @atomic 2_000_000_000_000_000_000
  @q96 79_228_162_514_264_337_593_543_950_336

  setup do
    starts_at = open(@rules)

    account =
      Accounts.register_verified!("did:privy:points-awards", @wallet, [@wallet], actor: %System{})

    %{account: account, starts_at: starts_at}
  end

  test "a launch earns its creator the first launch once, though a second one follows",
       %{account: account} do
    first = launch(account)
    queued = length(all_enqueued(queue: :points))

    # Recording the same launch again keeps the saved row and offers nothing new.
    assert %Auction{id: id} = launch(account, address: first.auction_address)
    assert id == first.id
    assert length(all_enqueued(queue: :points)) == queued

    second = launch(account)
    drain()

    # Both launches are recorded for the creator; the first earns, and the second
    # ends capped with no entry of its own.
    assert outcomes("autolaunch.first_launch") ==
             Enum.sort([{first.id, :confirmed}, {second.id, :capped}])

    assert Enum.all?(
             events("autolaunch.first_launch"),
             &(&1.account_id == account.id and &1.actor_kind == "human")
           )

    key = first.id
    assert [{^key, 25}] = earned("autolaunch.first_launch")

    # The second launch still earns the day's launch award, as its own action.
    assert second.id in Enum.map(events("autolaunch.auction_created"), & &1.source_event_key)
  end

  test "the day's launch award counts once each UTC day", %{
    account: account,
    starts_at: starts_at
  } do
    # The wallet was the account's before any of the days below.
    held_since(account, @wallet, DateTime.add(starts_at, -86_400))

    two_days_ago = Date.add(Date.utc_today(), -2)
    yesterday = Date.add(Date.utc_today(), -1)

    first = account |> launch() |> saved_at(two_days_ago, ~T[10:00:00])
    same_day = account |> launch() |> saved_at(two_days_ago, ~T[11:00:00])
    next_day = account |> launch() |> saved_at(yesterday, ~T[10:00:00])
    drain()

    assert Map.new(earned("autolaunch.auction_created")) == %{
             first.id => 20,
             same_day.id => 0,
             next_day.id => 20
           }

    assert [%{reason_code: "allowance_used", cap_reduction_micro: cut}] =
             entries("autolaunch.auction_created", 0)

    assert cut == 20 * @unit
  end

  test "a graduation earns the launch's creator the first graduation once",
       %{account: account} do
    first = account |> launch(kind: :stocks, state: :graduated) |> graduate()
    queued = length(all_enqueued(queue: :points))

    # Seeing the same graduation again keeps the saved token and offers nothing new.
    {:ok, auction} = Autolaunch.get_listed_auction(first.auction_id, actor: %System{})
    assert :ok = LabProjection.project_graduated_token(auction)
    assert length(all_enqueued(queue: :points)) == queued

    second = account |> launch(kind: :stocks, state: :graduated) |> graduate()
    drain()

    key = first.id
    assert [{^key, 25}] = earned("autolaunch.first_graduation")

    # Both graduations are recorded for the creator; the second ends capped.
    assert outcomes("autolaunch.first_graduation") ==
             Enum.sort([{first.id, :confirmed}, {second.id, :capped}])

    assert Enum.all?(events("autolaunch.first_graduation"), &(&1.account_id == account.id))
  end

  test "a launch from a wallet no account holds is saved and earns nothing" do
    auction =
      Autolaunch.record_launch_auction!(
        %{
          kind: :stocks,
          origin: :chain,
          contracts_version: :v2,
          featured: false,
          current_clearing_price: "0",
          chain_id: 8453,
          auction_address: "0x" <> String.duplicate("e", 40),
          token_address: "0x" <> String.duplicate("f", 40),
          creator_human_account_id: nil,
          creator_address: @stranger,
          title: "Stranger Coin",
          token_symbol: "STRG",
          quote_token_address: "0x" <> String.duplicate("a", 40),
          quote_token_symbol: "AAPLc",
          quote_token_decimals: 8,
          required_currency_raised: "1000",
          state: :created,
          treasury_address: "0x" <> String.duplicate("b", 40)
        },
        actor: %System{}
      )

    assert {:ok, %Auction{id: id}} = Autolaunch.get_listed_auction(auction.id, actor: %System{})
    drain()

    assert events() == []
    assert RegentPoints.read_entries!(actor: Store.system()) == []

    assert [
             {"autolaunch.auction_created", "creator_wallet_not_linked"},
             {"autolaunch.first_launch", "creator_wallet_not_linked"}
           ] =
             RegentPoints.read_rejections!(actor: Store.system())
             |> Enum.filter(&(&1.source["source_event_key"] == id))
             |> Enum.map(&{&1.source["rule_id"], &1.reason_code})
             |> Enum.sort()
  end

  test "while no rule is approved, launches and graduations offer nothing", %{account: account} do
    Application.put_env(:regent_points, :approved_rules, [])

    token = account |> launch(kind: :stocks, state: :graduated) |> graduate()

    assert token.graduated_at
    assert all_enqueued(queue: :points) == []
    drain()
    assert events() == []
    assert RegentPoints.read_rejections!(actor: Store.system()) == []
  end

  test "the site's checks answer the same each time they are asked", %{account: account} do
    auction = launch(account, kind: :stocks, state: :graduated)
    token = graduate(auction)
    stranger = launch(account, creator_address: @stranger)
    hidden = launch(account)
    Autolaunch.hide_auction!(hidden, actor: %System{})

    # Bids the bidder's page saved: on a listed launch, from a wallet no account
    # holds, on the hidden launch, and on a launch the lists leave out.
    bid = place(auction, 1, @wallet)
    stranger_bid = place(auction, 2, @stranger)
    hidden_bid = place(hidden, 3, @wallet)
    unlisted_bid = account |> launch(origin: :chain) |> place(4, @wallet)

    for {check, record} <- [
          {Launch, auction},
          {Launch, stranger},
          {Launch, hidden},
          {Graduation, token},
          {Bid, bid},
          {Bid, stranger_bid},
          {Bid, hidden_bid},
          {Bid, unlisted_bid}
        ] do
      assert check.verify(key(record)) == check.verify(key(record))
    end

    account_id = account.id
    id = auction.id
    assert {:ok, %{account_id: ^account_id, source_event_key: ^id}} = Launch.verify(key(auction))
    assert {:error, :creator_wallet_not_linked} = Launch.verify(key(stranger))
    assert {:error, :launch_not_listed} = Launch.verify(key(hidden))

    token_id = token.id

    assert {:ok, %{account_id: ^account_id, source_event_key: ^token_id}} =
             Graduation.verify(key(token))

    # The launch's creator bidding on it earns like any other bidder.
    bid_id = bid.id
    assert {:ok, %{account_id: ^account_id, source_event_key: ^bid_id}} = Bid.verify(key(bid))
    assert {:error, :bidder_wallet_not_linked} = Bid.verify(key(stranger_bid))
    assert {:error, :bid_not_listed} = Bid.verify(key(hidden_bid))
    assert {:error, :bid_not_listed} = Bid.verify(key(unlisted_bid))
  end

  test "a bid from a linked wallet earns the day's bid award once, a second that day counting at nothing",
       %{account: account} do
    auction = bid_auction()
    chain([bid_log(1, 7, @wallet), bid_log(2, 8, @wallet)])

    assert {:snooze, 300} = pass(auction)
    assert [%{owner_address: @wallet}, %{owner_address: @wallet}] = bids = positions(auction)
    drain()

    # Whichever of the two Points checks first earns the day's award.
    earned = Map.new(earned(@bid))
    assert Enum.sort(Map.keys(earned)) == Enum.sort(Enum.map(bids, & &1.id))
    assert Enum.sort(Map.values(earned)) == [0, 20]

    assert [%{reason_code: "allowance_used", cap_reduction_micro: cut}] = entries(@bid, 0)
    assert cut == 20 * @unit

    account_id = account.id
    assert [%{account_id: ^account_id}, %{account_id: ^account_id}] = events(@bid)
  end

  test "a bid from a wallet no account holds is saved and earns nothing" do
    auction = bid_auction()
    chain([bid_log(1, 7, @stranger)])

    assert {:snooze, 300} = pass(auction)
    assert [%{id: id, owner_address: @stranger, onchain_bid_id: "7"}] = positions(auction)
    drain()

    assert events(@bid) == []

    assert [{@bid, "bidder_wallet_not_linked"}] =
             RegentPoints.read_rejections!(actor: Store.system())
             |> Enum.filter(&(&1.source["source_event_key"] == id))
             |> Enum.map(&{&1.source["rule_id"], &1.reason_code})
  end

  test "a bid saved by the bidder's page earns once, and the reader's rebuild keeps it and offers nothing" do
    auction = bid_auction()
    %{id: id, inserted_at: at} = place(auction, 7, @wallet)
    drain()
    assert [{^id, 20}] = earned(@bid)

    # The page reading the same receipt again keeps the saved row and offers nothing.
    assert %{id: ^id, inserted_at: ^at} = saved = place(auction, 7, @wallet)
    assert all_enqueued(queue: :points) == []
    assert {:ok, facts} = Bid.verify(key(saved))

    # The auction's reader then sees the same bid on the chain, and the chain
    # changes under its cursor, so it clears the auction's activity and rebuilds it.
    chain([bid_log(1, 7, @wallet)])
    assert {:snooze, 300} = pass(auction)
    assert [%{bid_id: "7"}] = Autolaunch.auction_bids!(auction.id)

    reorged = block(@head, "0x" <> String.duplicate("3d", 32))
    put_blocks(%{"latest" => reorged, hex(@head) => reorged})
    assert {:snooze, 1} = pass(auction)
    assert Autolaunch.auction_bids!(auction.id) == []
    assert {:snooze, 300} = pass(auction)
    assert [%{bid_id: "7"}] = Autolaunch.auction_bids!(auction.id)

    assert positions(auction) == [saved]
    assert all_enqueued(queue: :points) == []
    assert Bid.verify(key(saved)) == {:ok, facts}
    assert [%{source_event_key: ^id}] = events(@bid)
    assert [{^id, 20}] = earned(@bid)
  end

  test "while earning is closed, the reader still saves a bid and Points gets nothing" do
    Application.put_env(:regent_points, :starts_at, nil)
    Application.put_env(:regent_points, :approved_rules, [])

    auction = bid_auction()
    chain([bid_log(1, 7, @wallet)])

    assert {:snooze, 300} = pass(auction)
    assert [%{bid_id: "7", bidder: @wallet}] = Autolaunch.auction_bids!(auction.id)
    assert [%{onchain_bid_id: "7", owner_address: @wallet}] = positions(auction)

    assert all_enqueued(queue: :points) == []
    drain()
    assert events() == []
    assert RegentPoints.read_rejections!(actor: Store.system()) == []
  end

  defp launch(account, opts \\ []) do
    [creator_address: @wallet, creator_human_account_id: account.id]
    |> Keyword.merge(opts)
    |> TestSupport.project_auction()
  end

  # The token the site saves once it sees the launch's auction graduated.
  defp graduate(auction) do
    assert :ok = LabProjection.project_graduated_token(auction)
    Repo.one!(from t in Autolaunch.Token, where: t.auction_id == ^auction.id)
  end

  # The launch as though the site had saved it at that time on that day (UTC).
  defp saved_at(auction, date, time) do
    at = DateTime.new!(date, time, "Etc/UTC")

    {1, _} =
      Repo.update_all(from(a in Auction, where: a.id == ^auction.id), set: [inserted_at: at])

    auction
  end

  # A listed Base launch, open for bids, the chain double's auction. Someone else
  # launched it.
  defp bid_auction,
    do:
      TestSupport.project_auction(
        chain_id: Lab.current!().chain_id,
        address: @auction,
        state: :active
      )

  # A bid the bidder's page read from its receipt, as the position row it saved.
  defp place(auction, onchain_bid_id, wallet) do
    id = to_string(onchain_bid_id)

    context = %{
      auction_id: auction.id,
      auction_address: auction.auction_address,
      signer: wallet,
      max_price: "1"
    }

    assert :ok = LabProjection.project_bid(context, %{"onchain_bid_id" => id, "amount" => "2"})

    Repo.one!(
      from b in Autolaunch.Bid, where: b.auction_id == ^auction.id and b.onchain_bid_id == ^id
    )
  end

  # A saved position has no read without a signed-in wallet, so the test reads
  # the auction's rows back.
  defp positions(auction) do
    Repo.all(
      from b in Autolaunch.Bid, where: b.auction_id == ^auction.id, order_by: b.onchain_bid_id
    )
  end

  # One pass of the auction's reader (Autolaunch.AuctionActivity) over the chain double.
  defp pass(auction), do: perform_job(AuctionActivity, %{auction_id: auction.id})

  # The chain the reader reads: the auction's price checkpoint and then `bids`, all
  # in one block.
  defp chain(bids) do
    BaseRpcStub.install(:autolaunch_lab_http_client, &call/2)
    head = block(@head, @head_hash)

    BaseRpcStub.put(%{
      chain_id: hex(Lab.current!().chain_id),
      blocks: %{
        "latest" => head,
        hex(@head) => head,
        hex(@start_block) => block(@start_block, @bid_hash),
        hex(@bid_block) => block(@bid_block, @bid_hash)
      },
      logs: [log(0, ["CheckpointUpdated(uint256,uint256,uint24)"], [@bid_block, @q96, 0]) | bids]
    })
  end

  defp put_blocks(blocks),
    do: BaseRpcStub.put(%{blocks: Map.merge(BaseRpcStub.state().blocks, blocks)})

  defp block(number, hash),
    do: %{"number" => hex(number), "hash" => hash, "timestamp" => hex(@now + number - @head)}

  defp call(%{data: data}, _state) do
    cond do
      data == LabAbi.selector("startBlock()") -> BaseRpcStub.uint(@start_block)
      data == LabAbi.selector("endBlock()") -> BaseRpcStub.uint(@end_block)
      data == LabAbi.selector("currencyRaised()") -> BaseRpcStub.uint(@atomic)
    end
  end

  # The auction's `BidSubmitted` for on-chain bid `id`, owned by `wallet`.
  defp bid_log(index, id, wallet) do
    log(
      index,
      [
        "BidSubmitted(uint256,address,uint256,uint128)",
        BaseRpcStub.uint(id),
        BaseRpcStub.address_topic(wallet)
      ],
      [@q96, @atomic]
    )
  end

  defp log(index, [event | indexed], words) do
    %{
      "address" => @auction,
      "blockNumber" => hex(@bid_block),
      "blockHash" => @bid_hash,
      "transactionHash" => @transaction,
      "logIndex" => hex(index),
      "removed" => false,
      "topics" => [LabAbi.topic(event) | indexed],
      "data" => "0x" <> Enum.map_join(words, &BaseRpcStub.hex_word/1)
    }
  end

  defp hex(value), do: "0x" <> Integer.to_string(value, 16)

  defp key(record), do: %{"source_event_key" => record.id}
end
