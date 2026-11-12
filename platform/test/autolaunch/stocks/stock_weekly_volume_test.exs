defmodule Autolaunch.Stocks.StockWeeklyVolumeTest do
  # A stock nobody traded for dollars last week is a read that worked: its
  # volume is stored as zero, so its job ends well and it is read again the
  # next day. Only an answer the site cannot read fails the job.
  use Autolaunch.DataCase, async: false

  @actor %Autolaunch.Actors.System{}
  @stock "0x" <> String.duplicate("a1", 20)
  @pool "0x" <> String.duplicate("b2", 20)
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"

  setup do
    previous = Req.default_options()
    on_exit(fn -> Req.default_options(previous) end)

    stock =
      Autolaunch.record_stock_admission!(
        %{
          chain_id: 8453,
          address: @stock,
          symbol: "QUIETc",
          name: "Quiet Co.",
          decimals: 8,
          admitted: true
        },
        actor: @actor
      )

    %{stock: stock}
  end

  test "a stock with no trade or no dollar pool stores zero; an unreadable answer fails", %{
    stock: stock
  } do
    dollar_pool = %{
      "attributes" => %{"address" => @pool},
      "relationships" => %{
        "base_token" => %{"data" => %{"id" => "base_#{@stock}"}},
        "quote_token" => %{"data" => %{"id" => "base_#{@usdc}"}}
      }
    }

    yesterday = Date.add(Date.utc_today(), -1)

    for pools <- [[dollar_pool], []] do
      gecko_answers(fn
        "/api/v2/networks/base/tokens/" <> _pools -> %{"data" => pools}
        "/api/v2/networks/base/pools/" <> _candles -> candles([])
      end)

      assert {:ok, read} = read_weekly_volume(stock)
      assert Decimal.equal?(read.weekly_volume_usd, 0)
      assert read.weekly_volume_complete
      assert read.weekly_volume_through == yesterday
    end

    gecko_answers(fn
      "/api/v2/networks/base/tokens/" <> _pools -> %{"data" => [dollar_pool]}
      "/api/v2/networks/base/pools/" <> _candles -> candles([[1, 2, 3]])
    end)

    assert {:error, error} = read_weekly_volume(stock)
    assert Exception.message(error) =~ "weekly volume read failed"
  end

  defp candles(list), do: %{"data" => %{"attributes" => %{"ohlcv_list" => list}}}

  defp gecko_answers(answer),
    do: Req.default_options(plug: &Req.Test.json(&1, answer.(&1.request_path)))

  defp read_weekly_volume(stock) do
    stock
    |> Ash.Changeset.for_update(:read_weekly_volume, %{}, actor: @actor)
    |> Ash.update()
  end
end
