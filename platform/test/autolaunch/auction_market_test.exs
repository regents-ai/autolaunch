defmodule Autolaunch.AuctionMarketTest do
  use Autolaunch.DataCase, async: false
  use Oban.Testing, repo: Autolaunch.Repo

  @moduletag :capture_log

  alias Autolaunch.Actors.System
  alias Autolaunch.Auction.MarketState
  alias Autolaunch.{AuctionMarket, AuctionReading, BaseRpcStub, LabAbi, TestSupport}

  defmodule ChainStub do
    @moduledoc """
    The Base lab chain for Revstake and Memestock auctions: every auction runs
    from block 100 to 200 and has met its minimum, and answers everything its
    own page reads unless `:page_broken`. Memestock launch records are Active
    unless `:lifecycle` says otherwise; a migrated launch's pool has no price
    yet. Any call the chain was not given is refused.

    `:chain` is an Agent holding `%{latest: number, rewritten_from: number |
    nil}`: the chain moves on one block each time its newest block is asked
    for, and every block from `rewritten_from` on has another hash, as if the
    chain rewrote them.
    """
    @no_tick Integer.pow(2, 256) - 1
    @pointer "0x0000000000000000000000000000000000000065"

    def install(options) do
      previous = Application.get_env(:autolaunch, :autolaunch_lab_http_client)
      Application.put_env(:autolaunch, :autolaunch_lab_http_client, __MODULE__)
      :persistent_term.put(__MODULE__, Map.merge(%{lifecycle: 1, page_broken: false}, options))

      ExUnit.Callbacks.on_exit(fn ->
        if previous,
          do: Application.put_env(:autolaunch, :autolaunch_lab_http_client, previous),
          else: Application.delete_env(:autolaunch, :autolaunch_lab_http_client)
      end)
    end

    def update(changes),
      do: :persistent_term.put(__MODULE__, Map.merge(:persistent_term.get(__MODULE__), changes))

    def post(_url, options) do
      %{method: method, params: params} = options[:json]

      case answer(method, params, :persistent_term.get(__MODULE__)) do
        :refused -> {:ok, %{status: 200, body: %{"error" => %{"message" => "refused"}}}}
        result -> {:ok, %{status: 200, body: %{"result" => result}}}
      end
    end

    defp answer("eth_chainId", _params, _options), do: "0x2105"

    defp answer("eth_getBlockByNumber", [tag, _full?], %{chain: chain}) do
      chain
      |> Agent.get_and_update(fn chain ->
        case tag do
          "latest" -> {chain.latest + 1, %{chain | latest: chain.latest + 1}}
          "0x" <> number -> {String.to_integer(number, 16), chain}
        end
      end)
      |> block(Agent.get(chain, & &1.rewritten_from))
    end

    # The release schedule SSTORE2 keeps after one zero byte: one step of
    # 100,000 millionths of a tenth a block for 100 blocks.
    defp answer("eth_getCode", [@pointer, _block], %{page_broken: false}),
      do: "0x00" <> "0186a0" <> "0000000064"

    defp answer("eth_getCode", _params, _options), do: "0x6080"

    defp answer("eth_call", [%{data: data}, _block], options) do
      case words(String.slice(data, 0, 10), options) do
        nil -> :refused
        words -> "0x" <> Enum.map_join(words, &BaseRpcStub.hex_word/1)
      end
    end

    defp words(selector, options) do
      Map.get(
        %{
          LabAbi.selector("startBlock()") => [100],
          LabAbi.selector("endBlock()") => [200],
          LabAbi.selector("claimBlock()") => [210],
          LabAbi.selector("isGraduated()") => [1],
          LabAbi.selector("clearingPrice()") => [2 ** 96],
          LabAbi.selector("currencyRaised()") => [10 ** 18],
          LabAbi.selector("remainingSupply()") => [0],
          # The floor, the token it sells and that token's supply (the
          # auction's own supply answers the same).
          LabAbi.selector("floorPrice()") => [2 ** 96],
          LabAbi.selector("token()") => [0x61],
          LabAbi.selector("totalSupply()") => [100 * 10 ** 18],
          # The lab strategy's record: lifecycle first, no pool yet.
          LabAbi.selector("distribution(address)") => [
            options.lifecycle | List.duplicate(0, LabAbi.distribution_words() - 1)
          ],
          # The Memestock launchpad: every auction's record at `lifecycle`
          # (word 9); its token, stock and splitter are words 1, 2 and 4.
          LabAbi.selector("launchIdOfAuction(address)") => [1],
          LabAbi.selector("launches(uint256)") =>
            [0, 0x61, 0x62, 0, 0x64] ++
              List.duplicate(0, 4) ++ [options.lifecycle] ++ List.duplicate(0, 10),
          # The pool manager's slot0 before the first swap.
          LabAbi.selector("extsload(bytes32)") => [0],
          # What the auction's own page reads: its book, its schedule's
          # pointer and its ladder, which has no price above the clearing one.
          LabAbi.selector("tickSpacing()") => [div(2 ** 96, 100)],
          LabAbi.selector("MAX_BID_PRICE()") => [1_000 * 2 ** 96],
          LabAbi.selector("checkpoint()") => [2 ** 96, 0, 0, 0, 0, 0],
          LabAbi.selector("totalCleared()") => [0],
          LabAbi.selector("pointer()") => [0x65],
          LabAbi.selector("nextActiveTickPrice()") => [@no_tick],
          LabAbi.selector("lastCheckpointedBlock()") => [140],
          LabAbi.selector("latestCheckpoint()") => [2 ** 96, 0, 0, 5_000_000, 0, 0],
          LabAbi.selector("remainingSupplyQ96X7()") => [0],
          LabAbi.selector("sumCurrencyDemandAboveClearingQ96()") => [0]
        },
        selector
      )
    end

    defp block(number, rewritten_from) do
      side = if rewritten_from && number >= rewritten_from, do: "bb", else: "aa"
      hex = number |> Integer.to_string(16) |> String.downcase()

      %{
        "number" => "0x" <> hex,
        "hash" => hash(number, side),
        "timestamp" => "0x" <> (Integer.to_string(0x6700 + number, 16) |> String.downcase())
      }
    end

    def hash(number, side),
      do:
        "0x" <>
          String.pad_leading(Integer.to_string(number, 16) |> String.downcase(), 62, "0") <> side
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
  end

  describe "a Revstake auction's reading job" do
    setup do
      auction = TestSupport.project_auction(chain_id: 8453, state: :created)
      {:ok, chain} = Agent.start_link(fn -> %{latest: 150, rewritten_from: nil} end)
      ChainStub.install(%{chain: chain})
      %{auction: auction, chain: chain}
    end

    test "writes the state and reached minimum with the page, and the end block ends it",
         %{auction: auction, chain: chain} do
      Phoenix.PubSub.subscribe(Autolaunch.PubSub, AuctionReading.page_topic(auction.id))

      assert {:snooze, 300} = pass(auction)
      assert %{state: :active, minimum_reached: true} = reload(auction)

      assert %{degraded: false, page: %{stage: %{stage: :open}, clearing: "1"}} =
               reading(auction)

      assert_receive %{
        topic: "public:auction_page:" <> _id,
        payload: %{page: %{stage: %{stage: :open}}}
      }

      Agent.update(chain, &%{&1 | latest: 250})
      assert {:snooze, 300} = pass(auction)
      assert %{state: :ended, minimum_reached: true} = reload(auction)
    end

    # A chain that goes back past the reading's block is read again, and the
    # auction's state still never moves back.
    test "a chain that went back never moves a finished state back",
         %{auction: auction, chain: chain} do
      Agent.update(chain, &%{&1 | latest: 250})
      assert {:snooze, 300} = pass(auction)
      assert %{state: :ended} = reload(auction)

      Agent.update(chain, &%{&1 | latest: 150})
      assert {:snooze, 300} = pass(auction)
      assert %{state: :ended} = reload(auction)
      assert reading(auction).read_block == 151
    end

    test "a second pass that finds nothing new leaves the reading as it was",
         %{auction: auction} do
      assert {:snooze, 300} = pass(auction)
      before = reading(auction)

      assert {:snooze, 300} = pass(auction)
      assert reading(auction) == before
    end

    test "a reading from a block the chain rewrote is replaced by the new block's",
         %{auction: auction, chain: chain} do
      assert {:snooze, 300} = pass(auction)
      first = reading(auction)
      Agent.update(chain, &%{&1 | rewritten_from: first.read_block})

      assert {:snooze, 300} = pass(auction)
      second = reading(auction)
      assert second.read_block > first.read_block
      assert second.block_hash == ChainStub.hash(second.read_block, "bb")
      assert second.version == first.version + 1
    end

    # A page that cannot be read must not hold back the auction's own figures,
    # or a page that keeps failing would stop the auction ever graduating.
    test "a page that cannot be read still writes the auction's figures and marks the reading",
         %{auction: auction} do
      ChainStub.update(%{page_broken: true})

      assert {:snooze, 300} = pass(auction)
      assert %{state: :active, minimum_reached: true} = reload(auction)
      assert %{degraded: true, page: nil} = reading(auction)

      ChainStub.update(%{page_broken: false})
      assert {:snooze, 300} = pass(auction)
      assert %{degraded: false, page: %{stage: %{stage: :open}}} = reading(auction)
    end

    test "a node that does not answer marks the reading and is read again a minute later",
         %{auction: auction} do
      assert {:snooze, 300} = pass(auction)
      before = reading(auction)
      row = reload(auction)

      Application.put_env(:autolaunch, :autolaunch_lab_http_client, BaseRpcStub.Timeout)

      assert {:snooze, 60} = pass(auction)
      assert %{degraded: true} = after_outage = reading(auction)
      assert after_outage.version == before.version + 1
      assert after_outage.page == before.page
      assert reload(auction) == row
    end
  end

  describe "a Memestock auction's reading job" do
    setup do
      {:ok, chain} = Agent.start_link(fn -> %{latest: 150, rewritten_from: nil} end)
      ChainStub.install(%{chain: chain})
      %{creator: TestSupport.register_creator!().id}
    end

    test "writes only the row's market fields and never creates a row", %{creator: creator} do
      auction = stocks_auction(creator, :created)
      before = reload(auction)
      rows = stocks_rows()

      assert {:snooze, 300} = pass(auction)

      after_pass = reload(auction)
      assert %{state: :active, minimum_reached: true} = after_pass

      market = [
        :state,
        :minimum_reached,
        :current_clearing_price,
        :currency_raised,
        :floor_price,
        :token_supply,
        :updated_at
      ]

      assert Map.drop(after_pass, market) == Map.drop(before, market)
      assert stocks_rows() == rows
    end

    test "a graduation whose token cannot be written saves nothing, and the next pass graduates it",
         %{creator: creator} do
      auction = stocks_auction(creator, :ended)
      ChainStub.update(%{lifecycle: 2})

      # The tokens table refuses every insert until the trigger is dropped.
      tokens = ~s("#{Repo.default_prefix()}".tokens)

      Repo.query!("""
      CREATE FUNCTION pg_temp.refuse_token() RETURNS trigger LANGUAGE plpgsql
      AS $$ BEGIN RAISE EXCEPTION 'token refused'; END $$
      """)

      Repo.query!(
        "CREATE TRIGGER refuse_token BEFORE INSERT ON #{tokens} FOR EACH ROW EXECUTE FUNCTION pg_temp.refuse_token()"
      )

      assert {:error, _reason} = pass(auction)
      assert %{state: :ended} = reload(auction)
      assert {:ok, nil} = Autolaunch.get_token_for_projection(auction.id, actor: %System{})
      assert {:ok, nil} = Autolaunch.get_auction_reading(auction.id, actor: %System{})

      Repo.query!("DROP TRIGGER refuse_token ON #{tokens}")

      assert {:snooze, 300} = pass(auction)
      assert %{state: :graduated} = reload(auction)

      assert {:ok, %{name: "Memestock"}} =
               Autolaunch.get_token_for_projection(auction.id, actor: %System{})
    end
  end

  test "every auction on a deployment this site describes has its own reading job" do
    revstake = TestSupport.project_auction(chain_id: 8453, state: :active)
    memestock = stocks_auction(TestSupport.register_creator!().id)
    _elsewhere = TestSupport.project_auction(chain_id: 31_337, state: :active)

    assert AuctionMarket.jobs() |> Enum.map(& &1.changes.args.auction_id) |> Enum.sort() ==
             Enum.sort([revstake.id, memestock.id])
  end

  defp pass(auction), do: perform_job(AuctionMarket, %{auction_id: auction.id})

  defp reading(auction) do
    {:ok, reading} = Autolaunch.get_auction_reading(auction.id, actor: nil)
    reading
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
          creator_address: "0x1414141414141414141414141414141414141414",
          title: "Memestock",
          summary: "A launch discovery listed",
          token_symbol: "MEME",
          website: "https://example.com",
          image: "https://example.com/meme.png",
          quote_token_address: "0xb200000000000000000000c2e324d24d7eecd1fb",
          quote_token_symbol: "AAPLc",
          quote_token_decimals: 8,
          required_currency_raised: "1000",
          state: state,
          treasury_address: "0x0f8955a7f09ec713bb71c30e07b512ecee69a044"
        },
        actor: %System{}
      )

    auction
  end

  defp stocks_rows do
    # Counts the rows the job wrote, whatever policies would show a reader.
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
