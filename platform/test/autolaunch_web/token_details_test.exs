defmodule AutolaunchWeb.TokenDetailsTest do
  use ExUnit.Case, async: true

  alias AutolaunchWeb.TokenDetails

  # LONG_POOL_PRICES_ARE_CUT_NOT_PARSED: a pool's exact price runs to well over
  # Decimal's 34-digit parsing limit, and a price may end in "…". The copied
  # details cut such prices as the page does; parsing them crashed the token page.
  @aifrog_opening_price "0.000000003455147984287968343500266491653510021182948722200142036742758521835143328884794480320768445225228663429991602299951936112224179010500579867226633723475970327854156494140625"
  @aifrog_price "0.00000000177459605665622333244704924973282246343495144603397587666196677842817386578859924662590637059545441477385722734429838391606083260187975980670671560801565647125244140625"

  test "LONG_POOL_PRICES_ARE_CUT_NOT_PARSED" do
    text = TokenDetails.text(details(), nil, nil)

    assert text =~ "- Latest recorded price: 0.000000001774596056 NVDAc per AIFROG"
    assert text =~ "- Price when the pool opened: 0.000000003455147984 NVDAc per AIFROG"

    cut =
      TokenDetails.text(
        put_in(details().pool.graduation_price, %{
          value: String.slice(@aifrog_opening_price, 0, 30) <> "…",
          exact?: false
        }),
        nil,
        nil
      )

    assert cut =~ "- Price when the pool opened: 0.000000003455147984 NVDAc per AIFROG"
  end

  defp details do
    token = %{
      symbol: "AIFROG",
      address: "0x345fc59ac4fd786c3c2f49e7778e1f14e2e335cf",
      decimals: 18
    }

    currency = %{
      symbol: "NVDAc",
      address: "0x0000000000000000000000000000000000000001",
      decimals: 18
    }

    lane = %{accrued: "0", settled_currency: "0"}

    %{
      name: "AI FROG",
      symbol: "AIFROG",
      url: "https://autolaunch.sh/tokens/AIFROG/85e71",
      auction: %{kind: :stocks, contracts_version: :v1},
      price: "0.000000001774596056",
      supply: nil,
      fees: nil,
      treasury: nil,
      pool: %{
        kind: :stocks,
        chain: :base,
        version: :v1,
        block: %{number: 1},
        token: token,
        currency: currency,
        current: %{price: %{value: @aifrog_price, exact?: true}, tick: 0, liquidity: 0},
        graduation_price: %{value: @aifrog_opening_price, exact?: true},
        hook: "0x0000000000000000000000000000000000000002",
        pool_id: "0x00",
        pool_manager: "0x0000000000000000000000000000000000000003",
        positions: [],
        fees: %{
          stakers: lane,
          regent: Map.put(lane, :settled_usdc, "0"),
          splitter: %{
            address: "0x0000000000000000000000000000000000000004",
            total_staked: "0",
            total_staked_atomic: 0,
            skim_bps: 200
          }
        }
      }
    }
  end
end
