defmodule Autolaunch.Earn.Chain do
  @moduledoc """
  Earn's reads of Base, all at one block, the latest when asked: the pool's
  reserve for the product's asset and its income index, then, with the market's
  token those name, the market's totals and, for a wallet, what it holds. Each
  of the two is one Multicall3 request at that block's own hash, so every
  figure in an answer is from the same block; the second needs the market
  token's address the first returns.

  From the pool (Aave V3's `IPool`):

    * `getReserveData(asset)`, fifteen words: the configuration bitmap (word 0:
      decimals in bits 48–55, active in bit 56, frozen in 57, paused in 60, the
      supply cap in whole tokens in bits 116–151, 0 for none), the current
      liquidity rate (word 2, a yearly rate in ray, 10^27, not compounded),
      the market token (word 8) and what is owed to the treasury in scaled
      units (word 12)
    * `getReserveNormalizedIncome(asset)`, the income index at this block (ray)

  From the market token and the asset: `totalSupply()`, what is supplied in
  all, interest included; `scaledTotalSupply()`, the same in scaled units, for
  the supply cap; the asset's `balanceOf(marketToken)`, what can be withdrawn
  now; and for a wallet its market-token `balanceOf` (its balance in the
  market, interest included), its own asset `balanceOf` and its `allowance` to
  the pool.

  The pool counts against the supply cap every scaled balance and the
  treasury's share at the index of the block a deposit lands in
  (`ValidationLogic.validateSupply`); this reads that sum at the latest block's
  index. The index only grows, so a deposit over the room at this block is over
  it at any later one too.
  """

  alias Autolaunch.Chain.{Multicall, Rpc}
  alias Autolaunch.Earn.States
  alias Autolaunch.Lab
  alias RegentChain.Call

  @ray 10 ** 27

  @type terms :: %{
          block: Rpc.block(),
          a_token: String.t(),
          decimals: non_neg_integer(),
          status: States.status(),
          rate: non_neg_integer(),
          supplied: non_neg_integer(),
          available: non_neg_integer(),
          cap: non_neg_integer(),
          room: States.room()
        }

  @type holding :: %{
          wallet: String.t(),
          balance: non_neg_integer(),
          position: States.position(),
          usdc: non_neg_integer(),
          allowance: non_neg_integer()
        }

  @doc "The latest block on `lab`, with the options every read at it takes."
  def latest(lab) do
    opts = Lab.rpc_opts(lab, "autolaunch earn")
    with {:ok, block} <- Rpc.latest_block(opts), do: {:ok, block, opts}
  end

  @doc """
  `product`'s market at the latest block on `lab`, and what `wallet` holds in
  it at the same block (`nil` for no wallet).
  """
  @spec read(map(), map(), String.t() | nil) ::
          {:ok, terms(), holding() | nil} | {:error, atom()}
  def read(product, lab, wallet) do
    with {:ok, block, opts} <- latest(lab),
         {:ok, reserve, index} <- reserve(product, block, opts),
         {:ok, [supplied, scaled, available | held]} <-
           amounts(totals(product, reserve) ++ holdings(product, reserve, wallet), block, opts) do
      counted = ray_mul(scaled + reserve.accrued_to_treasury, index)

      terms = %{
        block: block,
        a_token: reserve.a_token,
        decimals: reserve.decimals,
        status: States.status(reserve),
        rate: reserve.rate,
        supplied: supplied,
        available: available,
        cap: reserve.cap,
        room: States.room(%{cap: reserve.cap, decimals: reserve.decimals, counted: counted})
      }

      {:ok, terms, holding(wallet, held)}
    end
  end

  defp reserve(product, block, opts) do
    reads = [
      {product.pool, Call.encode("getReserveData(address)", [product.asset_address])},
      {product.pool, Call.encode("getReserveNormalizedIncome(address)", [product.asset_address])}
    ]

    with {:ok, [reserve, index]} <- Multicall.read(reads, block, opts),
         {:ok, words} <- words(reserve, 15),
         {:ok, [index]} <- words(index, 1) do
      {:ok, decode(words), index}
    end
  end

  @doc """
  The reserve's fifteen words as Earn reads them: the configuration's flags,
  decimals and supply cap, the liquidity rate, the market token and the
  treasury's share.
  """
  @spec decode([non_neg_integer()]) :: map()
  def decode([config, _index, rate, _, _, _, _, _, a_token, _, _, _, accrued, _, _]) do
    %{
      decimals: bits(config, 48, 8),
      active: bits(config, 56, 1) == 1,
      frozen: bits(config, 57, 1) == 1,
      paused: bits(config, 60, 1) == 1,
      cap: bits(config, 116, 36),
      rate: rate,
      a_token: address(a_token),
      accrued_to_treasury: accrued
    }
  end

  defp bits(word, from, count), do: word |> Bitwise.bsr(from) |> Bitwise.band(2 ** count - 1)

  defp totals(product, reserve) do
    [
      {reserve.a_token, Call.encode("totalSupply()", [])},
      {reserve.a_token, Call.encode("scaledTotalSupply()", [])},
      {product.asset_address, Call.encode("balanceOf(address)", [reserve.a_token])}
    ]
  end

  defp holdings(_product, _reserve, nil), do: []

  defp holdings(product, reserve, wallet) do
    [
      {reserve.a_token, Call.encode("balanceOf(address)", [wallet])},
      {product.asset_address, Call.encode("balanceOf(address)", [wallet])},
      {product.asset_address, Call.encode("allowance(address,address)", [wallet, product.pool])}
    ]
  end

  defp holding(nil, []), do: nil

  defp holding(wallet, [balance, usdc, allowance]),
    do: %{
      wallet: wallet,
      balance: balance,
      position: States.position(balance),
      usdc: usdc,
      allowance: allowance
    }

  defp amounts(reads, block, opts) do
    with {:ok, answers} <- Multicall.read(reads, block, opts) do
      Enum.reduce_while(answers, {:ok, []}, fn answer, {:ok, kept} ->
        case words(answer, 1) do
          {:ok, [amount]} -> {:cont, {:ok, [amount | kept]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, kept} -> {:ok, Enum.reverse(kept)}
        error -> error
      end
    end
  end

  defp words(answer, count) when is_binary(answer) and byte_size(answer) == count * 32,
    do: {:ok, for(<<word::256 <- answer>>, do: word)}

  defp words(:reverted, _count), do: {:error, :chain_unavailable}
  defp words(_answer, _count), do: {:error, :invalid_chain_response}

  # Aave's `WadRayMath.rayMul`: rounded half up.
  defp ray_mul(a, b), do: div(a * b + div(@ray, 2), @ray)

  defp address(word),
    do: "0x" <> (word |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(40, "0"))
end
