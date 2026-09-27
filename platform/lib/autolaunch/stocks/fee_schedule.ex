defmodule Autolaunch.Stocks.FeeSchedule do
  @moduledoc """
  The three trading fees every Memestake pool charges, on Base and on
  Robinhood Chain: the pool fee on the token the trader pays with, and the
  REGENT stakers' and token stakers' fees on the stock side of every trade.
  Every page that states these fees reads them here.
  """

  # Mirrors the contracts: StocksPreset.sol (POOL_FEE, REGENT_LANE_BPS,
  # STAKER_LANE_BPS) on Base, and RobinhoodPreset.sol (PROTOCOL_LANE_BPS,
  # STAKER_LANE_BPS, with StocksPreset's POOL_FEE) on Robinhood Chain. The pool
  # fee is in Uniswap v4's hundredths of a bip, each lane in basis points.
  @schedules %{
    base: %{pool_fee: 3_000, regent_lane_bps: 100, staker_lane_bps: 100},
    robinhood: %{pool_fee: 3_000, regent_lane_bps: 100, staker_lane_bps: 100}
  }

  @type chain :: :base | :robinhood
  @type lane :: %{
          key: :pool | :regent | :stakers,
          label: String.t(),
          rate: String.t(),
          charged_on: :paid | :stock,
          receiver: String.t()
        }

  @doc "The pool's static fee as its pool key carries it: 3_000 is 0.30%."
  @spec pool_fee(chain()) :: pos_integer()
  def pool_fee(chain), do: Map.fetch!(@schedules, chain).pool_fee

  @doc "Each fee a Memestake trade on `chain` pays: its rate, what it is charged on and who receives it."
  @spec lanes(chain()) :: [lane()]
  def lanes(chain) do
    schedule = Map.fetch!(@schedules, chain)

    [
      %{
        key: :pool,
        label: "Pool fee",
        rate: percent(div(schedule.pool_fee, 100)),
        charged_on: :paid,
        receiver:
          "the pool's liquidity; what the locked liquidity earns goes to the token's stakers"
      },
      %{
        key: :regent,
        label: "REGENT stakers' fee",
        rate: percent(schedule.regent_lane_bps),
        charged_on: :stock,
        receiver: "REGENT stakers"
      },
      %{
        key: :stakers,
        label: "Token stakers' fee",
        rate: percent(schedule.staker_lane_bps),
        charged_on: :stock,
        receiver: "the token's stakers"
      }
    ]
  end

  @doc "One of the fees a Memestake trade on `chain` pays."
  @spec lane(chain(), :pool | :regent | :stakers) :: lane()
  def lane(chain, key), do: Enum.find(lanes(chain), &(&1.key == key))

  @doc "What a fee is charged on, in words."
  @spec charged_on(:paid | :stock) :: String.t()
  def charged_on(:paid), do: "the token the trader pays with"
  def charged_on(:stock), do: "the stock side of every trade"

  @doc "The fees as rows of a launch's fixed terms."
  @spec terms(chain()) :: [{String.t(), String.t()}]
  def terms(chain),
    do:
      Enum.map(
        lanes(chain),
        &{&1.label, "#{&1.rate} of #{charged_on(&1.charged_on)}, to #{&1.receiver}"}
      )

  # Hundredths of a percent as a percent with two decimals: 30 is "0.30%".
  defp percent(hundredths),
    do:
      "#{div(hundredths, 100)}.#{hundredths |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}%"
end
