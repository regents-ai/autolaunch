defmodule Autolaunch.MarketFeedTest do
  use Autolaunch.DataCase, async: false

  @moduletag :capture_log

  alias Autolaunch.Actors.System
  alias Autolaunch.Auction.MarketState
  alias Autolaunch.{BaseRpcStub, LabAbi, LabMarketFeed}
  alias Autolaunch.LabMarketFeed.{Projector, Reader}
  alias Autolaunch.TestSupport

  @head %{binding: :lab, block: %{number: 150, hash: "0x" <> String.duplicate("ab", 32)}}

  defmodule Verifier do
    @moduledoc false
    def verify_head(_head), do: :ok
  end

  defmodule HangingReader do
    @moduledoc "A chain whose head never verifies: every verification waits forever."
    @head %{binding: :lab, block: %{number: 150, hash: "0x" <> String.duplicate("ab", 32)}}

    def install(test_pid), do: :persistent_term.put(__MODULE__, test_pid)

    def head, do: {:ok, @head}
    def snapshots(_head, _capacity, attempted), do: {:ok, %{snapshots: [], attempted: attempted}}

    def verify_head(_head) do
      send(:persistent_term.get(__MODULE__), {:verifying, self()})
      Process.sleep(:infinity)
    end
  end

  defmodule ChainStub do
    @moduledoc """
    The Base lab chain for the Revstake feed: every auction is live and has met
    its minimum, and any auction named in `:broken` refuses every read.
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
        else: call(String.slice(data, 0, 10))
    end

    defp call(selector) do
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
          LabAbi.selector("distribution(address)") => [1 | List.duplicate(0, 17)]
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
               Projector.project([snapshot(auction, :active, true)], @head, Verifier)

      assert %{state: :active, minimum_reached: true} = reload(auction)

      assert {:ok, [_changed]} =
               Projector.project([snapshot(auction, :ended, true)], @head, Verifier)

      assert %{state: :ended, minimum_reached: true} = reload(auction)

      # An older reading can never move it back.
      assert {:ok, []} = Projector.project([snapshot(auction, :active, true)], @head, Verifier)
      assert %{state: :ended} = reload(auction)
    end
  end

  describe "one auction that cannot be read" do
    test "is skipped and every other auction still refreshes" do
      auctions = for _n <- 1..3, do: TestSupport.project_auction(chain_id: 8453, state: :active)
      [broken | readable] = auctions
      ChainStub.install(%{broken: MapSet.new([String.downcase(broken.auction_address)])})

      assert {:ok, head} = Reader.head()
      assert {:ok, %{snapshots: snapshots}} = Reader.snapshots(head, 256, MapSet.new())

      assert snapshots |> Enum.map(& &1.auction_id) |> Enum.sort() ==
               readable |> Enum.map(& &1.id) |> Enum.sort()

      assert Enum.all?(snapshots, &(&1.state == :active and &1.minimum_reached))
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

  defp reload(auction) do
    {:ok, row} = Autolaunch.get_lab_market_auction_for_update(auction.id, actor: %System{})
    row
  end
end
