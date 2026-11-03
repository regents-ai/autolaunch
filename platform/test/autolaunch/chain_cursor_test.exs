defmodule Autolaunch.ChainCursorTest do
  @moduledoc """
  A launch's bid activity and its token's trades and revenue are read pass by
  pass from a cursor: the next block to read and the hash of the block before
  it. Read from a scripted Base chain whose newest block can fall behind the
  last pass's, and whose blocks from 105 on can be replaced by another fork
  while a pass reads. A graduated Revstake launch's splitter recognized one
  USDC payment at block 110.
  """
  use Autolaunch.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Autolaunch.{Auction, AuctionActivity, BaseRpcStub, LabAbi, TestSupport, TokenTrades}
  alias Autolaunch.Actors.System

  @subject "0x5100000000000000000000000000000000000051"
  @splitter "0x5400000000000000000000000000000000000054"

  defmodule Chain do
    @moduledoc false
    use Agent

    alias Autolaunch.{BaseRpcStub, LabAbi}

    def start_link(_opts),
      do: Agent.start_link(fn -> %{latest: 120, fork: :old, reorg_on_read?: false} end, name: __MODULE__)

    def put(changes), do: Agent.update(__MODULE__, &Map.merge(&1, changes))
    def state, do: Agent.get(__MODULE__, & &1)

    def post(_url, options) do
      %{method: method, params: params} = options[:json]
      {:ok, %{status: 200, body: %{"result" => answer(method, params, state())}}}
    end

    defp answer("eth_chainId", _params, _state), do: "0x2105"
    defp answer("eth_getBlockByNumber", ["latest", _full?], state), do: block(state.latest, state.fork)

    defp answer("eth_getBlockByNumber", ["0x" <> number, _full?], state),
      do: block(String.to_integer(number, 16), state.fork)

    defp answer("eth_call", [%{data: data}, _block], _state) do
      cond do
        String.starts_with?(data, LabAbi.selector("startBlock()")) -> word(100)
        String.starts_with?(data, LabAbi.selector("endBlock()")) -> word(200)
        true -> strategy_record()
      end
    end

    # The splitter's one payment, at block 110 of the fork read. A pass set to
    # meet a reorg finds the old fork's logs, which hold none, and the new fork
    # takes their place before it reads any block.
    defp answer("eth_getLogs", [%{address: address, fromBlock: from, toBlock: to}], state) do
      splitter? = String.downcase(address) == "0x5400000000000000000000000000000000000054"

      cond do
        splitter? and state.reorg_on_read? ->
          put(%{fork: :new, reorg_on_read?: false})
          []

        splitter? and state.fork == :new and quantity(from) <= 110 and 110 <= quantity(to) ->
          [Autolaunch.ChainCursorTest.revenue_log(hash(110, :new))]

        true ->
          []
      end
    end

    # The strategy's record of a migrated launch: migrated at block 100, its
    # subject token, splitter and pool.
    defp strategy_record do
      words =
        [2, 0, 0, 0, 100, 0, 0, 0, 0, 1, 0x51 * Integer.pow(2, 152) + 0x51, 0x52, 0x53] ++
          [0x54 * Integer.pow(2, 152) + 0x54, 0x55, 0xABC, 1]

      "0x" <> Enum.map_join(words, &BaseRpcStub.hex_word/1)
    end

    defp word(value), do: "0x" <> BaseRpcStub.hex_word(value)
    defp quantity("0x" <> hex), do: String.to_integer(hex, 16)

    defp block(number, fork),
      do: %{
        "number" => "0x" <> Integer.to_string(number, 16),
        "hash" => hash(number, fork),
        "timestamp" => "0x" <> Integer.to_string(1_760_000_000 + number, 16)
      }

    # Blocks before 105 are the same on both forks.
    def hash(number, :new) when number >= 105,
      do: "0x" <> String.pad_leading(Integer.to_string(number, 16), 64, "f")

    def hash(number, _fork), do: "0x" <> String.pad_leading(Integer.to_string(number, 16), 64, "0")
  end

  # One USDC recognized: 1.00 gross, 0.02 skimmed, 0.49 to stakers and 0.49 to
  # the treasury.
  def revenue_log(block_hash) do
    usdc = Autolaunch.Chain.Abi.usdc_address() |> String.trim_leading("0x") |> String.downcase()

    %{
      "removed" => false,
      "address" => @splitter,
      "blockNumber" => "0x6e",
      "blockHash" => block_hash,
      "logIndex" => "0x3",
      "transactionHash" => "0x" <> String.duplicate("ab", 32),
      "topics" => [
        LabAbi.topic(
          "RevenueRecognized(address,address,bytes32,uint256,uint256,uint256,uint256,uint256)"
        ),
        "0x" <> String.pad_leading(usdc, 64, "0"),
        "0x" <> String.pad_leading("99", 64, "0"),
        "0x" <> String.duplicate("0", 64)
      ],
      "data" =>
        "0x" <>
          Enum.map_join([1_000_000, 20_000, 980_000, 490_000, 490_000], &BaseRpcStub.hex_word/1)
    }
  end

  setup do
    start_supervised!(Chain)
    previous = Application.get_env(:autolaunch, :autolaunch_lab_http_client)
    Application.put_env(:autolaunch, :autolaunch_lab_http_client, Chain)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:autolaunch, :autolaunch_lab_http_client, previous),
        else: Application.delete_env(:autolaunch, :autolaunch_lab_http_client)
    end)

    auction = TestSupport.project_auction(chain_id: 8453, state: :graduated, token_address: @subject)
    token = TestSupport.project_token(auction_id: auction.id, graduated_at: DateTime.utc_now())

    %{auction: auction, token: token}
  end

  test "TRADES_REREAD_AFTER_REORG: a reorg while a pass reads is read again, so its revenue is recorded",
       %{token: token} do
    Chain.put(%{reorg_on_read?: true})

    # The pass read the old fork's logs and then met the new fork's blocks: it
    # records nothing and moves no cursor.
    assert {:error, :head_moved} = TokenTrades.read(trades(token))
    assert %{trades_next_block: nil} = trades(token)

    # The next pass reads the new fork, payment and all.
    assert {:ok, :caught_up} = TokenTrades.read(trades(token))
    assert {:ok, [revenue]} = Autolaunch.token_revenue(token.id, actor: nil)
    assert revenue.block_number == 110
    assert %{trades_next_block: 121} = trades(token)
  end

  test "CURSOR_KEPT_WHEN_NODE_BEHIND: a node behind the last pass keeps the token's trades and cursor",
       %{token: token} do
    Chain.put(%{fork: :new})
    assert {:ok, :caught_up} = TokenTrades.read(trades(token))
    assert {:ok, [_revenue]} = Autolaunch.token_revenue(token.id, actor: nil)

    # A node a few blocks behind the head the last pass read.
    Chain.put(%{latest: 117})
    assert {:error, :head_moved} = TokenTrades.read(trades(token))
    assert {:ok, [_kept]} = Autolaunch.token_revenue(token.id, actor: nil)
    assert %{trades_next_block: 121} = trades(token)

    # Once the node has caught up, reading goes on from the same cursor.
    Chain.put(%{latest: 125})
    assert {:ok, :caught_up} = TokenTrades.read(trades(token))
    assert {:ok, [_one]} = Autolaunch.token_revenue(token.id, actor: nil)
    assert %{trades_next_block: 126} = trades(token)
  end

  test "CURSOR_KEPT_WHEN_NODE_BEHIND: a node behind the last pass keeps the auction's activity cursor",
       %{auction: auction} do
    Repo.update_all(
      from(a in "auctions", where: a.id == type(^auction.id, :binary_id)),
      set: [activity_next_block: 131, activity_last_hash: Chain.hash(130, :old)]
    )

    assert {:error, :head_moved} = AuctionActivity.read(activity(auction))
    assert %{activity_next_block: 131} = activity(auction)
  end

  defp trades(token),
    do: token |> Ash.reload!(authorize?: false) |> Ash.load!(:auction, authorize?: false)

  defp activity(auction) do
    {:ok, auction} = Ash.get(Auction, auction.id, action: :activity, actor: %System{})
    auction
  end
end
