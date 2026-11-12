defmodule Autolaunch.Stocks.MarketDataTest do
  # A price many pages ask for at once is read once, and a read that failed is
  # kept as no answer until its retry is due, not read again on every ask.
  use ExUnit.Case, async: false

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
end
