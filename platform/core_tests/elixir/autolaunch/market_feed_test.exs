defmodule Autolaunch.MarketFeedTest do
  use Autolaunch.DataCase, async: false

  @moduletag :capture_log

  alias Autolaunch.Actors.System
  alias Autolaunch.Auction.MarketState
  alias Autolaunch.{BaseRpcStub, LabAbi, LabMarketFeed, MarketWatch}
  alias Autolaunch.LabMarketFeed.{Projector, Reader}
  alias Autolaunch.Stocks.LabMarketFeed, as: StocksMarketFeed
  alias Autolaunch.TestSupport

  defmodule HangingReader do
    @moduledoc "A chain whose head never verifies: every verification waits forever."
    @head %{binding: :lab, block: %{number: 150, hash: "0x" <> String.duplicate("ab", 32)}}

    def install(test_pid), do: :persistent_term.put(__MODULE__, test_pid)

    def head, do: {:ok, @head}

    def snapshots(_head, watch, attempted),
      do: {:ok, %{snapshots: [], attempted: attempted, watch: watch}}

    def verify_head(_head) do
      send(:persistent_term.get(__MODULE__), {:verifying, self()})
      Process.sleep(:infinity)
    end
  end

  defmodule ChainStub do
    @moduledoc """
    The Base lab chain for the Revstake and Memestake feeds: every auction is
    live and has met its minimum, and any auction named in `:broken` refuses
    every read. Memestake launch records are Active unless `:lifecycle` says
    otherwise; a migrated launch's pool has no price yet.
    """
    @block %{"number" => "0x96", "hash" => "0x" <> String.duplicate("cd", 32)}

    def install(options) do
      previous = Application.get_env(:autolaunch, :autolaunch_lab_http_client)
      Application.put_env(:autolaunch, :autolaunch_lab_http_client, __MODULE__)
      :persistent_term.put(__MODULE__, options)

      ExUnit.Callbacks.on_exit(fn ->
        if previous,
          do: Application.put_env(:autolaunch, :autolaunch_lab_http_client, previous),
          else: Application.delete_env(:autolaunch, :autolaunch_lab_http_client)
      end)
    end

    def post(_url, options) do
      %{method: method, params: params} = options[:json]

      case answer(method, params, :persistent_term.get(__MODULE__)) do
        :refused -> {:ok, %{status: 200, body: %{"error" => %{"message" => "refused"}}}}
        result -> {:ok, %{status: 200, body: %{"result" => result}}}
      end
    end

    defp answer("eth_chainId", _params, _options), do: "0x2105"
    defp answer("eth_getBlockByNumber", _params, _options), do: @block
    defp answer("eth_getCode", _params, _options), do: "0x6080"

    defp answer("eth_call", [%{to: to, data: data}, _block], options) do
      if MapSet.member?(options.broken, String.downcase(to)),
        do: :refused,
        else: call(String.slice(data, 0, 10), Map.get(options, :lifecycle, 1))
    end

    defp call(selector, lifecycle) do
      words =
        %{
          LabAbi.selector("startBlock()") => [100],
          LabAbi.selector("endBlock()") => [200],
          LabAbi.selector("claimBlock()") => [210],
          LabAbi.selector("isGraduated()") => [1],
          LabAbi.selector("clearingPrice()") => [0],
          LabAbi.selector("currencyRaised()") => [10 ** 18],
          LabAbi.selector("remainingSupply()") => [0],
          # Lifecycle 1 (Active) and no pool yet.
          LabAbi.selector("distribution(address)") => [1 | List.duplicate(0, 17)],
          # The Memestake launchpad: every auction's record at `lifecycle`
          # (word 11). It is asked nothing else.
          LabAbi.selector("launchIdOfAuction(address)") => [1],
          # Its token, stock and splitter are words 1, 2 and 4.
          LabAbi.selector("launches(uint256)") =>
            [0, 0x61, 0x62, 0, 0x64] ++
              List.duplicate(0, 6) ++ [lifecycle] ++ List.duplicate(0, 8),
          # The pool manager's slot0 before the first swap.
          LabAbi.selector("extsload(bytes32)") => [0]
        }
        |> Map.fetch!(selector)

      "0x" <> Enum.map_join(words, &BaseRpcStub.hex_word/1)
    end
  end

  describe "state from the launch lifecycle and the auction's schedule" do
    test "a reached minimum never ends bidding; only the end block and migrate do" do
      # Lifecycle 1 is Active: before the start, before the end, after the end.
      assert MarketState.observed(1, 99, 100, 200) == :created
      assert MarketState.observed(1, 150, 100, 200) == :active
      assert MarketState.observed(1, 200, 100, 200) == :ended
      assert MarketState.observed(1, 900, 100, 200) == :ended
      # Only `migrate` sets 2 and 3, whatever the schedule says.
      assert MarketState.observed(2, 150, 100, 200) == :graduated
      assert MarketState.observed(3, 900, 100, 200) == :failed
    end

    test "states move forward only, and a finished state stays" do
      assert MarketState.join(:created, :active) == :active
      assert MarketState.join(:active, :ended) == :ended
      assert MarketState.join(:ended, :graduated) == :graduated
      assert MarketState.join(:ended, :failed) == :failed
      assert MarketState.join(:active, :created) == :active
      assert MarketState.join(:ended, :active) == :ended
      assert MarketState.join(:graduated, :failed) == :graduated
      assert MarketState.join(:failed, :active) == :failed
    end

    test "the feed stores a reached minimum beside the state, and the end block ends it" do
      auction = TestSupport.project_auction(state: :created)

      assert {:ok, [_changed]} =
               Projector.project([snapshot(auction, :active, true)])

      assert %{state: :active, minimum_reached: true} = reload(auction)

      assert {:ok, [_changed]} =
               Projector.project([snapshot(auction, :ended, true)])

      assert %{state: :ended, minimum_reached: true} = reload(auction)

      # An older reading can never move it back.
      assert {:ok, []} = Projector.project([snapshot(auction, :active, true)])
      assert %{state: :ended} = reload(auction)
    end
  end

  describe "one Revstake auction whose write fails" do
    test "is left as it was, and every other auction's state and price still move" do
      # A graduation with no launch row cannot become a token, so its write fails.
      stuck = TestSupport.project_auction(state: :ended)
      moving = for _n <- 1..2, do: TestSupport.project_auction(state: :created)
      Autolaunch.Listings.subscribe()

      snapshots = [
        snapshot(stuck, :graduated, true)
        | Enum.map(moving, &%{snapshot(&1, :active, true) | current_clearing_price: "2.5"})
      ]

      assert {:ok, changed} = Projector.project(snapshots)
      assert Enum.sort(changed) == moving |> Enum.map(& &1.id) |> Enum.sort()

      assert %{state: :ended, minimum_reached: false} = reload(stuck)
      assert {:ok, nil} = Autolaunch.get_token_for_projection(stuck.id, actor: %System{})

      for auction <- moving do
        assert %{state: :active, current_clearing_price: "2.5"} = reload(auction)
        auction_id = auction.id
        assert_received {:autolaunch_listings_changed, ^auction_id}
      end

      stuck_id = stuck.id
      refute_received {:autolaunch_listings_changed, ^stuck_id}
    end
  end

  describe "one auction that cannot be read" do
    test "is skipped and every other auction still refreshes" do
      auctions = for _n <- 1..3, do: TestSupport.project_auction(chain_id: 8453, state: :active)
      [broken | readable] = auctions
      ChainStub.install(%{broken: MapSet.new([String.downcase(broken.auction_address)])})

      assert {:ok, head} = Reader.head()

      assert {:ok, %{snapshots: snapshots}} =
               Reader.snapshots(head, MarketWatch.new(), MapSet.new())

      assert snapshots |> Enum.map(& &1.auction_id) |> Enum.sort() ==
               readable |> Enum.map(& &1.id) |> Enum.sort()

      assert Enum.all?(snapshots, &(&1.state == :active and &1.minimum_reached))
    end
  end

  describe "one Memestake auction that cannot be read" do
    test "is skipped and every other auction is still read and written" do
      creator = TestSupport.register_creator!().id
      auctions = for _n <- 1..3, do: stocks_auction(creator)
      [broken | readable] = auctions
      ChainStub.install(%{broken: MapSet.new([String.downcase(broken.auction_address)])})

      assert {:ok, %{snapshots: snapshots, changed: changed}} =
               StocksMarketFeed.refresh(MarketWatch.new())

      readable_ids = readable |> Enum.map(& &1.id) |> Enum.sort()
      assert snapshots |> Map.values() |> Enum.map(& &1.auction_id) |> Enum.sort() == readable_ids
      assert Enum.sort(changed) == readable_ids
      assert Enum.map(readable, &reload(&1).minimum_reached) == [true, true]
      refute reload(broken).minimum_reached
    end
  end

  describe "the Memestake feed" do
    test "writes only a row's market fields and never creates a row" do
      creator = TestSupport.register_creator!().id
      auction = stocks_auction(creator, :created)
      before = reload(auction)
      rows = stocks_rows()
      ChainStub.install(%{broken: MapSet.new()})

      assert {:ok, %{changed: [changed]}} = StocksMarketFeed.refresh(MarketWatch.new())
      assert changed == auction.id

      after_refresh = reload(auction)
      assert %{state: :active, minimum_reached: true} = after_refresh
      market = [:state, :minimum_reached, :current_clearing_price, :updated_at]
      assert Map.drop(after_refresh, market) == Map.drop(before, market)
      assert stocks_rows() == rows
    end
  end

  describe "a Memestake graduation whose token cannot be written" do
    test "saves nothing, and the next pass graduates it with its token" do
      auction = stocks_auction(TestSupport.register_creator!().id, :ended)
      ChainStub.install(%{broken: MapSet.new(), lifecycle: 2})

      # The tokens table refuses every insert until the trigger is dropped.
      tokens = ~s("#{Repo.default_prefix()}".tokens)

      Repo.query!("""
      CREATE FUNCTION pg_temp.refuse_token() RETURNS trigger LANGUAGE plpgsql
      AS $$ BEGIN RAISE EXCEPTION 'token refused'; END $$
      """)

      Repo.query!(
        "CREATE TRIGGER refuse_token BEFORE INSERT ON #{tokens} FOR EACH ROW EXECUTE FUNCTION pg_temp.refuse_token()"
      )

      assert {:ok, %{changed: []}} = StocksMarketFeed.refresh(MarketWatch.new())
      assert %{state: :ended} = reload(auction)
      assert {:ok, nil} = Autolaunch.get_token_for_projection(auction.id, actor: %System{})

      Repo.query!("DROP TRIGGER refuse_token ON #{tokens}")

      assert {:ok, %{changed: [changed]}} = StocksMarketFeed.refresh(MarketWatch.new())
      assert changed == auction.id
      assert %{state: :graduated} = reload(auction)

      assert {:ok, %{name: "Memestake"}} =
               Autolaunch.get_token_for_projection(auction.id, actor: %System{})
    end
  end

  describe "a page asking the feed for its readings" do
    test "is answered at once while the feed waits on the chain" do
      HangingReader.install(self())
      {:ok, feed} = LabMarketFeed.start_link(name: nil, poll?: false, reader: HangingReader)

      LabMarketFeed.refresh(feed)
      assert_receive {:verifying, _pid}, 1_000

      reply = Task.async(fn -> LabMarketFeed.snapshot(feed) end)
      assert {:ok, %{auctions: %{}, generation: 0}} = Task.yield(reply, 200)
    end
  end

  describe "more auctions than one pass reads" do
    test "every one is read over successive passes, open ones first and every pass" do
      creator = TestSupport.register_creator!().id

      open =
        for _n <- 1..150,
            do:
              TestSupport.project_auction(
                chain_id: 8453,
                state: :active,
                creator_human_account_id: creator
              )

      finished =
        for state <- List.duplicate(:graduated, 90) ++ List.duplicate(:failed, 70),
            do:
              TestSupport.project_auction(
                chain_id: 8453,
                state: state,
                creator_human_account_id: creator
              )

      ChainStub.install(%{broken: MapSet.new()})
      assert {:ok, head} = Reader.head()

      {passes, _watch} =
        Enum.map_reduce(1..8, MarketWatch.new(), fn _pass, watch ->
          assert {:ok, %{snapshots: snapshots, watch: next}} =
                   Reader.snapshots(head, watch, MapSet.new())

          {MapSet.new(snapshots, & &1.auction_id), next}
        end)

      open_ids = MapSet.new(open, & &1.id)
      all_ids = MapSet.union(open_ids, MapSet.new(finished, & &1.id))

      assert Enum.all?(passes, &(MapSet.size(&1) <= 200))

      assert open_ids
             |> MapSet.difference(Enum.at(passes, 0))
             |> MapSet.subset?(Enum.at(passes, 1))

      assert Enum.reduce(passes, &MapSet.union/2) == all_ids
      assert MapSet.size(all_ids) > 257
    end
  end

  defp snapshot(auction, state, minimum_reached) do
    %{
      auction_id: auction.id,
      auction_address: String.downcase(auction.auction_address),
      state: state,
      minimum_reached: minimum_reached,
      current_clearing_price: auction.current_clearing_price,
      price_quote: nil,
      positions: []
    }
  end

  defp stocks_auction(creator, state \\ :active) do
    {:ok, auction} =
      Autolaunch.record_launch_auction(
        %{
          kind: :stocks,
          origin: :site,
          featured: false,
          current_clearing_price: "0",
          chain_id: 8453,
          auction_address:
            "0x" <>
              (Elixir.System.unique_integer([:positive])
               |> Integer.to_string(16)
               |> String.pad_leading(40, "0")),
          creator_human_account_id: creator,
          title: "Memestake",
          summary: "A launch discovery listed",
          token_symbol: "MEME",
          website: "https://example.com",
          image: "https://example.com/meme.png",
          quote_token_address: "0xb200000000000000000000c2e324d24d7eecd1fb",
          quote_token_symbol: "AAPLc",
          quote_token_decimals: 8,
          required_currency_raised: "1000",
          state: state,
          treasury_address: "0x1d36a95112835f81b1b499a808e556020c64cac2"
        },
        actor: %System{}
      )

    auction
  end

  defp stocks_rows do
    Autolaunch.Repo.aggregate(
      from(row in "auctions", where: row.kind == "stocks" and row.chain_id == 8453),
      :count
    )
  end

  defp reload(auction) do
    {:ok, row} = Autolaunch.get_lab_market_auction_for_update(auction.id, actor: %System{})
    row
  end
end
