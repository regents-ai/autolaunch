defmodule Autolaunch.PoolRange do
  @moduledoc """
  Where one Uniswap v4 position sits and what it holds now: its tick range and
  liquidity read from the PositionManager, and its two amounts worked out
  from them at the pool's current price with Uniswap's own integer math
  (`TickMath.getSqrtPriceAtTick` and `SqrtPriceMath`'s amount deltas,
  rounded down as a withdrawal would be).

  Nothing here writes, signs or caches.
  """

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.LabAbi

  @q96 Integer.pow(2, 96)
  @max_tick 887_272
  @uint256_max Integer.pow(2, 256) - 1
  # TickMath's 1/sqrt(1.0001^(2^i)) factors in Q128.128, for bits 1 through 19.
  @ratios [
    {0x2, 0xFFF97272373D413259A46990580E213A},
    {0x4, 0xFFF2E50F5F656932EF12357CF3C7FDCC},
    {0x8, 0xFFE5CACA7E10E4E61C3624EAA0941CD0},
    {0x10, 0xFFCB9843D60F6159C9DB58835C926644},
    {0x20, 0xFF973B41FA98C081472E6896DFB254C0},
    {0x40, 0xFF2EA16466C96A3843EC78B326B52861},
    {0x80, 0xFE5DEE046A99A2A811C461F1969C3053},
    {0x100, 0xFCBE86C7900A88AEDCFFC83B479AA3A4},
    {0x200, 0xF987A7253AC413176F2B074CF7815E54},
    {0x400, 0xF3392B0822B70005940C7A398E4B70F3},
    {0x800, 0xE7159475A2C29B7443B29C7FA6E889D9},
    {0x1000, 0xD097F3BDFD2022B8845AD8F792AA5825},
    {0x2000, 0xA9F746462D870FDF8A65DC1F90E061E5},
    {0x4000, 0x70D869A156D2A1B890BB3DF62BAF32F7},
    {0x8000, 0x31BE135F97D08FD981231505542FCFA6},
    {0x10000, 0x9AA508B5B7A84E1C677DE54F3E99BC9},
    {0x20000, 0x5D6AF8DEDB81196699C329225EE604},
    {0x40000, 0x2216E584F5FA1EA926041BEDFE98},
    {0x80000, 0x48A170391F7DC42444E8FA2}
  ]

  @doc "A position's tick range and liquidity, read from the PositionManager."
  @spec read(String.t(), non_neg_integer(), Rpc.block(), keyword()) ::
          {:ok, %{lower: integer(), upper: integer(), liquidity: non_neg_integer()}}
          | {:error, atom()}
  def read(position_manager, token_id, block, opts) do
    id = token_id |> Integer.to_string(16) |> String.pad_leading(64, "0")

    with {:ok, info} <-
           Rpc.call_uint(
             position_manager,
             LabAbi.selector("positionInfo(uint256)") <> id,
             block,
             opts
           ),
         {:ok, liquidity} <-
           Rpc.call_uint(
             position_manager,
             LabAbi.selector("getPositionLiquidity(uint256)") <> id,
             block,
             opts
           ) do
      # PositionInfo packs `poolId | tickUpper | tickLower | hasSubscriber`.
      {:ok, %{lower: int24(info, 8), upper: int24(info, 32), liquidity: liquidity}}
    end
  end

  @doc """
  The two amounts a position holds at `sqrt_price_x96`, as `{amount0, amount1}`
  in atomic units of the pool's currency0 and currency1.
  """
  @spec amounts(map(), pos_integer()) :: {non_neg_integer(), non_neg_integer()}
  def amounts(%{lower: lower, upper: upper, liquidity: liquidity}, sqrt_price_x96) do
    low = sqrt_price_at_tick(lower)
    high = sqrt_price_at_tick(upper)
    price = sqrt_price_x96 |> max(low) |> min(high)
    {amount0(price, high, liquidity), amount1(low, price, liquidity)}
  end

  @doc "Whether the pool's current tick is inside the position's range, where it earns fees."
  def in_range?(%{lower: lower, upper: upper}, tick), do: lower <= tick and tick < upper

  @doc "Uniswap's `TickMath.getSqrtPriceAtTick`, exactly."
  def sqrt_price_at_tick(tick) when is_integer(tick) and abs(tick) <= @max_tick do
    magnitude = abs(tick)

    start =
      if Bitwise.band(magnitude, 1) != 0,
        do: 0xFFFCB933BD6FAD37AA2D162D1A594001,
        else: Integer.pow(2, 128)

    ratio =
      Enum.reduce(@ratios, start, fn {bit, factor}, ratio ->
        if Bitwise.band(magnitude, bit) != 0,
          do: Bitwise.bsr(ratio * factor, 128),
          else: ratio
      end)

    ratio = if tick > 0, do: div(@uint256_max, ratio), else: ratio
    Bitwise.bsr(ratio + Integer.pow(2, 32) - 1, 32)
  end

  # SqrtPriceMath.getAmount0Delta and getAmount1Delta, rounded down.
  defp amount0(low, high, _liquidity) when low >= high, do: 0
  defp amount0(low, high, liquidity), do: div(div(liquidity * @q96 * (high - low), high), low)

  defp amount1(low, high, _liquidity) when low >= high, do: 0
  defp amount1(low, high, liquidity), do: div(liquidity * (high - low), @q96)

  defp int24(word, offset) do
    value = word |> Bitwise.bsr(offset) |> Bitwise.band(0xFFFFFF)
    if value >= 0x800000, do: value - 0x1000000, else: value
  end
end
