defmodule Autolaunch.Stocks.FeeSchedule do
  @moduledoc """
  The trading fees every Memestake pool charges, on Base and on Robinhood
  Chain: the pool fee on the token the trader pays with, and the creator's,
  REGENT stakers' and token stakers' fees on the stock side of every trade.
  The first four Memestake tokens (`:v1`) charge no creator's fee and 1% to
  their stakers. Every page that states these fees reads them here.
  """

  # Mirrors the contracts: StocksPreset.sol (POOL_FEE, CREATOR_LANE_BPS,
  # REGENT_LANE_BPS, STAKER_LANE_BPS) on Base, and RobinhoodPreset.sol
  # (CREATOR_LANE_BPS, PROTOCOL_LANE_BPS, STAKER_LANE_BPS, with StocksPreset's
  # POOL_FEE) on Robinhood Chain; the first launchpads' presets for `:v1`. The
  # pool fee is in Uniswap v4's hundredths of a bip, each lane in basis points.
  @v2 %{pool_fee: 3_000, lanes: [creator: 30, regent: 100, stakers: 300]}
  @v1 %{pool_fee: 3_000, lanes: [regent: 100, stakers: 100]}
  @schedules %{
    {:base, :v2} => @v2,
    {:robinhood, :v2} => @v2,
    {:base, :v1} => @v1,
    {:robinhood, :v1} => @v1
  }

  @receivers %{
    creator: {"Creator's fee", "the wallet that created the launch"},
    regent: {"REGENT stakers' fee", "REGENT staking"},
    stakers:
      {"Token stakers' fee", "the token’s staking splitter before its 2% protocol deduction"}
  }

  @type chain :: :base | :robinhood
  @type version :: :v1 | :v2
  @type lane :: %{
          key: :pool | :creator | :regent | :stakers,
          label: String.t(),
          rate: String.t(),
          charged_on: :paid | :stock,
          receiver: String.t()
        }

  @doc "The pool's static fee as its pool key carries it: 3_000 is 0.30%."
  @spec pool_fee(chain(), version()) :: pos_integer()
  def pool_fee(chain, version), do: Map.fetch!(@schedules, {chain, version}).pool_fee

  @doc """
  Each fee a Memestake trade on `chain` pays on a launch of `version`: its
  rate, what it is charged on and who receives it.
  """
  @spec lanes(chain(), version()) :: [lane()]
  def lanes(chain, version) do
    schedule = Map.fetch!(@schedules, {chain, version})

    pool = %{
      key: :pool,
      label: "Pool fee",
      rate: percent(div(schedule.pool_fee, 100)),
      charged_on: :paid,
      receiver:
        "the pool’s liquidity; collected fees from locked liquidity enter the token’s staking splitter"
    }

    [
      pool
      | Enum.map(schedule.lanes, fn {key, bps} ->
          {label, receiver} = Map.fetch!(@receivers, key)

          %{
            key: key,
            label: label,
            rate: percent(bps),
            charged_on: :stock,
            receiver: receiver(key, chain, receiver)
          }
        end)
    ]
  end

  @doc "One of the fees a Memestake trade on `chain` pays on a launch of `version`."
  @spec lane(chain(), version(), :pool | :creator | :regent | :stakers) :: lane() | nil
  def lane(chain, version, key), do: Enum.find(lanes(chain, version), &(&1.key == key))

  @doc "What a fee is charged on, in words."
  @spec charged_on(:paid | :stock) :: String.t()
  def charged_on(:paid), do: "the token the trader pays with"
  def charged_on(:stock), do: "the gross stock side of every trade"

  @doc "A new launch's fees as rows of its fixed terms."
  @spec terms(chain()) :: [{String.t(), String.t()}]
  def terms(chain),
    do:
      Enum.map(
        lanes(chain, :v2),
        &{&1.label, "#{&1.rate} of #{charged_on(&1.charged_on)}, to #{&1.receiver}"}
      )

  defp receiver(:regent, :base, _default), do: "REGENT staking after conversion to USDC"

  defp receiver(:regent, :robinhood, _default),
    do: "the protocol inbox as USDG, held until the bridge to Base is configured"

  defp receiver(_lane, _chain, default), do: default

  # Hundredths of a percent as a percent with two decimals: 30 is "0.30%".
  defp percent(hundredths),
    do:
      "#{div(hundredths, 100)}.#{hundredths |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}%"
end
