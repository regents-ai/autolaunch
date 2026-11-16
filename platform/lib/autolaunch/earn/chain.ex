defmodule Autolaunch.Earn.Chain do
  @moduledoc """
  Earn's reads of Base, all at one block, the latest when asked: the pool's
  reserve for the product's asset, its income index and what it can pay out,
  then, with the market's token those name, the market's totals and, for a
  wallet, what it holds. Each of the two is one Multicall3 request at that
  block's own hash, so every figure in an answer is from the same block; the
  second needs the market token's address the first returns.

  From the pool (Aave V3's `IPool`; Base's runs revision 12, newer than Aave
  V3.7's 11, with virtual accounting and the supply-cap rounding of V3.5 on):

    * `getReserveData(asset)`, fifteen words: the configuration bitmap (word 0:
      decimals in bits 48–55, active in bit 56, frozen in 57, paused in 60, the
      supply cap in whole tokens in bits 116–151, 0 for none), the current
      liquidity rate (word 2, a yearly rate in ray, 10^27, not compounded),
      the market token (word 8) and what is owed to the treasury in scaled
      units (word 12)
    * `getReserveNormalizedIncome(asset)`, the income index at this block (ray)
    * `getVirtualUnderlyingBalance(asset)`, the asset the pool counts as its
      own and so can pay out now: a withdrawal past it fails. Asset sent to the
      market token directly is not counted, so the token's own `balanceOf`
      could be more than can be withdrawn.

  From the market token: `totalSupply()`, what is supplied in all, interest
  included; `scaledTotalSupply()`, the same in scaled units, for the supply
  cap; and for a wallet its `balanceOf` (its balance in the market, interest
  included), with the asset's `balanceOf` for the wallet and its `allowance`
  to the pool.

  The supply cap's capacity is the pool's own check at this block's index
  (`States.capacity/1`), with the treasury's share as the pool last stored it:
  at a block where the reserve is up to date, the pool takes exactly the
  capacity and refuses one unit more. By the block a deposit lands in,
  interest has raised the index and the treasury's share, so the capacity
  there is smaller: a deposit near it can still be refused when it lands,
  and one past it is refused at this block.
  """

  alias Autolaunch.Chain.{Multicall, Rpc}
  alias Autolaunch.Earn.States
  alias Autolaunch.Lab
  alias RegentChain.Call

  @type terms :: %{
          block: Rpc.block(),
          a_token: String.t(),
          decimals: non_neg_integer(),
          status: States.status(),
          rate: non_neg_integer(),
          supplied: non_neg_integer(),
          available: non_neg_integer(),
          cap: non_neg_integer(),
          capacity: States.capacity()
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
         {:ok, reserve, index, available} <- reserve(product, block, opts),
         {:ok, [supplied, scaled | held]} <-
           amounts(totals(reserve) ++ holdings(product, reserve, wallet), block, opts) do
      capacity =
        States.capacity(%{
          cap: reserve.cap,
          decimals: reserve.decimals,
          scaled: scaled + reserve.accrued_to_treasury,
          index: index
        })

      terms = %{
        block: block,
        a_token: reserve.a_token,
        decimals: reserve.decimals,
        status: States.status(reserve),
        rate: reserve.rate,
        supplied: supplied,
        available: available,
        cap: reserve.cap,
        capacity: capacity
      }

      {:ok, terms, holding(wallet, held)}
    end
  end

  defp reserve(product, block, opts) do
    reads =
      for signature <- ~w|getReserveData(address) getReserveNormalizedIncome(address)
                          getVirtualUnderlyingBalance(address)|,
          do: {product.pool, Call.encode(signature, [product.asset_address])}

    with {:ok, [reserve, index, available]} <- Multicall.read(reads, block, opts),
         {:ok, words} <- words(reserve, 15),
         {:ok, [index]} <- words(index, 1),
         {:ok, [available]} <- words(available, 1) do
      {:ok, decode(words), index, available}
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

  defp totals(reserve) do
    [
      {reserve.a_token, Call.encode("totalSupply()", [])},
      {reserve.a_token, Call.encode("scaledTotalSupply()", [])}
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
      answers |> Enum.map(&words(&1, 1)) |> one_word_each()
    end
  end

  # Each answer's one word, or the first answer that is not one word.
  defp one_word_each(read) do
    case Enum.find(read, &match?({:error, _reason}, &1)) do
      nil -> {:ok, Enum.map(read, fn {:ok, [amount]} -> amount end)}
      error -> error
    end
  end

  defp words(answer, count) when is_binary(answer) and byte_size(answer) == count * 32,
    do: {:ok, for(<<word::256 <- answer>>, do: word)}

  defp words(:reverted, _count), do: {:error, :chain_unavailable}
  defp words(_answer, _count), do: {:error, :invalid_chain_response}

  defp address(word),
    do:
      "0x" <> (word |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(40, "0"))
end
