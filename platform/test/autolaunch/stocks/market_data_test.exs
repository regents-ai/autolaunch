defmodule Autolaunch.Stocks.MarketDataTest do
  # A price many pages ask for at once is read once, and a read that failed is
  # kept as no answer until its retry is due, not read again on every ask.
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Stocks.MarketData

  defmodule Market do
    @moduledoc "DexScreener, slow enough for every asker to arrive, counting each read."
    alias Autolaunch.Chain.Abi

    def get(_url, _options) do
      %{reads: reads, status: status} = Application.fetch_env!(:autolaunch, :market_data_test)
      :counters.add(reads, 1, 1)
      Process.sleep(100)

      pair = %{"baseToken" => %{"address" => Abi.regent_address()}, "priceUsd" => "0.5"}
      {:ok, %{status: status, body: %{"pairs" => [pair]}}}
    end
  end

  setup do
    previous = Application.get_env(:autolaunch, :autolaunch_market_http_client)
    Application.put_env(:autolaunch, :autolaunch_market_http_client, Market)
    MarketData.reset()

    on_exit(fn ->
      Application.put_env(:autolaunch, :autolaunch_market_http_client, previous)
      Application.delete_env(:autolaunch, :market_data_test)
      MarketData.reset()
    end)

    %{reads: :counters.new(1, [])}
  end

  test "twenty askers at once share one read", %{reads: reads} do
    Application.put_env(:autolaunch, :market_data_test, %{reads: reads, status: 200})

    prices =
      1..20
      |> Enum.map(fn _asker -> Task.async(&MarketData.regent_price/0) end)
      |> Task.await_many()

    assert Enum.all?(prices, &Decimal.equal?(&1, Decimal.new("0.5")))
    assert :counters.get(reads, 1) == 1
  end

  test "a read that failed is no price until its retry is due", %{reads: reads} do
    Application.put_env(:autolaunch, :market_data_test, %{reads: reads, status: 503})

    assert MarketData.regent_price() == nil
    assert MarketData.regent_price() == nil
    assert :counters.get(reads, 1) == 1
  end

  test "valid prices survive alongside feeds with negative, zero, stale or malformed answers" do
    now = System.os_time(:second)

    replies =
      [
        {"GOODc", round(10_500_000_000, now)},
        {"NEGATIVEc", round(-1, now)},
        {"ZEROc", round(0, now)},
        {"STALEc", round(10_500_000_000, now - 8 * 86_400)},
        {"BADc", "0x" <> String.duplicate("g", 320)}
      ]
      |> Enum.with_index(1)
      |> Map.new(fn {{symbol, reply}, index} ->
        feed = "0x" <> String.pad_leading(Integer.to_string(index), 40, "0")

        Autolaunch.record_stock_admission!(
          %{
            chain_id: 8453,
            address: feed,
            symbol: symbol,
            name: symbol,
            decimals: 8,
            route: "0x" <> String.duplicate("a1", 20),
            feed: feed,
            admitted: true
          },
          actor: %Autolaunch.Actors.System{}
        )

        {feed, reply}
      end)

    Autolaunch.BaseRpcStub.install(:autolaunch_market_http_client, fn call, _state ->
      Map.fetch!(replies, call.to)
    end)

    assert %{"GOOD" => price} = prices = MarketData.prices(:base)
    assert Decimal.equal?(price, Decimal.new(105))
    assert map_size(prices) == 1
  end

  defp round(answer, updated_at) do
    encoded = <<1::256, answer::signed-256, updated_at::256, updated_at::256, 1::256>>
    "0x" <> Base.encode16(encoded, case: :lower)
  end
end
