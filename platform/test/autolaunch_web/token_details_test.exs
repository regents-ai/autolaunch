defmodule AutolaunchWeb.TokenDetailsTest do
  use ExUnit.Case, async: true

  alias AutolaunchWeb.TokenDetails

  # LONG_POOL_PRICES_ARE_CUT_NOT_PARSED: a pool's exact price runs to well over
  # Decimal's 34-digit parsing limit, and a price may end in "…". The copied
  # details cut such prices as the page does; parsing them crashed the token page.
  @aifrog_price "0.00000000177459605665622333244704924973282246343495144603397587666196677842817386578859924662590637059545441477385722734429838391606083260187975980670671560801565647125244140625"

  test "LONG_POOL_PRICES_ARE_CUT_NOT_PARSED" do
    text = TokenDetails.text(details(), nil, nil)

    assert text =~ "- Latest recorded price: 0.000000001774596056 NVDAc per AIFROG"
    assert text =~ "- Price when the pool opened: 0.0000000034551479 NVDAc per AIFROG"
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
        graduation_price: %{value: "0.0000000034551479" <> "…", exact?: false},
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
