defmodule Autolaunch.CCA.QuoteEngineTest do
  use ExUnit.Case, async: true

  alias Autolaunch.CCA.Abi
  alias Autolaunch.CCA.QuoteEngine

  @q96 79_228_162_514_264_337_593_543_950_336

  test "fully filled bid spends full budget when projected clearing stays below max price" do
    snapshot =
      snapshot_fixture(0, %{
        total_supply: 100,
        floor_price_q96: @q96,
        tick_spacing_q96: @q96,
        max_bid_price_q96: 10 * @q96
      })

    ticks = %{@q96 => %{price_q96: @q96, next_price_q96: Abi.max_u256(), currency_demand_q96: 0}}

    {:ok, quote} = QuoteEngine.build_quote(snapshot, ticks, 200, 3 * @q96)

    assert quote.status_band == "active"
    assert quote.would_be_active_now
    assert quote.projected_clearing_price_q96 == 2 * @q96
    assert quote.estimated_tokens_if_no_other_bids_change_units == 100
    assert quote.currency_spent_q96 == 200 * @q96
  end

  test "partial bid lands exactly on the projected clearing price" do
    snapshot =
      snapshot_fixture(0, %{
        total_supply: 100,
        floor_price_q96: @q96,
        tick_spacing_q96: @q96,
        max_bid_price_q96: 10 * @q96
      })

    ticks = %{@q96 => %{price_q96: @q96, next_price_q96: Abi.max_u256(), currency_demand_q96: 0}}

    {:ok, quote} = QuoteEngine.build_quote(snapshot, ticks, 200, 2 * @q96)

    assert quote.status_band == "partial"
    assert quote.would_be_active_now
    assert quote.projected_clearing_price_q96 == 2 * @q96
    assert quote.estimated_tokens_if_no_other_bids_change_units == 100
  end

  test "inactive bid would be outbid on the next checkpoint" do
    snapshot =
      snapshot_fixture(250 * @q96, %{
        total_supply: 100,
        floor_price_q96: @q96,
        tick_spacing_q96: @q96,
        max_bid_price_q96: 10 * @q96
      })

    ticks = %{
      @q96 => %{price_q96: @q96, next_price_q96: 3 * @q96, currency_demand_q96: 0},
      (3 * @q96) => %{
        price_q96: 3 * @q96,
        next_price_q96: Abi.max_u256(),
        currency_demand_q96: 250 * @q96
      }
    }

    {:ok, quote} = QuoteEngine.build_quote(snapshot, ticks, 1, 2 * @q96)

    assert quote.status_band == "inactive"
    refute quote.would_be_active_now
    assert quote.projected_clearing_price_q96 > 2 * @q96
    assert quote.estimated_tokens_if_no_other_bids_change_units == 0
  end

  defp snapshot_fixture(sum_currency_demand_above_clearing_q96, overrides) do
    %{
      chain_id: 84_532,
      auction_address: "0x0000000000000000000000000000000000000011",
      block_number: 10,
      total_supply: 100,
      floor_price_q96: @q96,
      tick_spacing_q96: @q96,
      next_active_tick_price_q96: Abi.max_u256(),
      sum_currency_demand_above_clearing_q96: sum_currency_demand_above_clearing_q96,
      currency_raised_wei: 0,
      total_cleared_units: 0,
      start_block: 1,
      end_block: 100,
      claim_block: 100,
      max_bid_price_q96: 10 * @q96,
      is_graduated: false,
      checkpoint: %{
        clearing_price_q96: @q96,
        currency_raised_at_clearing_price_q96_x7: 0,
        cumulative_mps_per_price: 0,
        cumulative_mps: 0,
        prev_block: 0,
        next_block: 0
      }
    }
    |> Map.merge(overrides)
  end
end
