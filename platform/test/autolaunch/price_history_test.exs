defmodule Autolaunch.PriceHistoryTest do
  use ExUnit.Case, async: true

  alias Autolaunch.LabAbi
  alias Autolaunch.PriceHistory

  # A pool's chart reads two lines from the same logs: one step per trade, and
  # 100 moments evenly spread in time, each the price the last trade at or
  # before it left. The line by time needs time to have passed since the pool
  # opened; until then only the line by trade is drawn.

  @initialize "Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)"
  @swap "Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"
  @pool_id "0x" <> String.duplicate("ab", 32)
  @q96 Integer.pow(2, 96)

  defmodule Node do
    def post(_url, _options),
      do: {:ok, %{status: 200, body: %{"result" => Process.get(:price_history_logs)}}}
  end

  setup do
    Application.put_env(:autolaunch, :price_history_node, Node)
    :ok
  end

  defp read(logs, block) do
    Process.put(:price_history_logs, logs)

    PriceHistory.pool(
      %{
        pool_manager: "0x" <> String.duplicate("1", 40),
        pool_id: @pool_id,
        token_is_currency0?: true,
        currency_decimals: 18
      },
      0,
      block,
      client_key: :price_history_node,
      rpc_url: "https://node.invalid"
    )
  end

  # A log whose price is `root` squared: the sqrt price is root * 2^96.
  defp log(signature, number, at, root) do
    words =
      case signature do
        @initialize -> [0, 0, 0, root * @q96]
        @swap -> [0, 0, root * @q96]
      end

    %{
      "removed" => false,
      "blockNumber" => "0x" <> Integer.to_string(number, 16),
      "blockTimestamp" => "0x" <> Integer.to_string(at, 16),
      "topics" => [LabAbi.topic(signature), @pool_id],
      "data" =>
        "0x" <> Enum.map_join(words, &String.pad_leading(Integer.to_string(&1, 16), 64, "0"))
    }
  end

  test "the line by time holds the price the last trade at or before each moment left" do
    logs = [log(@initialize, 10, 1_000, 1), log(@swap, 20, 1_500, 2), log(@swap, 30, 1_990, 3)]

    assert {:ok, history} = read(logs, %{number: 40, timestamp: 1_990})

    assert history.points == [[10, 1.0], [20, 4.0], [30, 9.0], [40, 9.0]]
    assert {history.low, history.high, history.trades} == {1.0, 9.0, 2}

    assert length(history.times) == 100
    assert hd(history.times) == [1_000, 1.0]
    assert List.last(history.times) == [1_990, 9.0]
    assert [1_490, 1.0] in history.times and [1_500, 4.0] in history.times

    for [at, price] <- history.times,
        do: assert(price == if(at < 1_500, do: 1.0, else: if(at < 1_990, do: 4.0, else: 9.0)))
  end

  test "read in the same second the pool opened, there is a line by trade and none by time" do
    logs = [log(@initialize, 10, 1_000, 1), log(@swap, 11, 1_000, 2)]

    assert {:ok, %{points: [_, _, _], times: nil}} = read(logs, %{number: 12, timestamp: 1_000})
  end

  test "a pool with no logs yet has no history" do
    assert {:ok, nil} = read([], %{number: 12, timestamp: 1_000})
  end

  test "a removed log means the history moved under the read" do
    logs = [%{log(@initialize, 10, 1_000, 1) | "removed" => true}]

    assert {:error, :invalid_chain_response} = read(logs, %{number: 12, timestamp: 2_000})
  end
end
