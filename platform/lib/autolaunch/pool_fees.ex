defmodule Autolaunch.PoolFees do
  @moduledoc """
  What a launched token's pool has charged in trading fees: every fee its
  hook recorded since graduation, and those from the first block of the last
  24 hours that the token's trade index knows. Each fee is both lanes, the
  REGENT share and the stakers' share, summed in the pool's currency and, for
  a Revstake pool that can take its fee in its own token, in the token.
  """
  import Ecto.Query

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.{Repo, TokenTrade}

  @day 86_400

  @doc """
  The pool's fees all time and over the last day, as plain decimals of its
  currency and token. The day is `nil` while the token's trades have never
  been read, since nothing then says which block the day starts at.
  """
  def totals(pool, token) do
    charged = pool.fees.charged

    %{
      all_time: sum(charged, 0, pool),
      day: with(block when is_integer(block) <- day_start(token), do: sum(charged, block, pool))
    }
  end

  # The day starts at the token's earliest recorded trade in it. With none,
  # every fee since the block its trade index reads next is in the day: the
  # index keeps within a minute of the chain, and a fee is only charged on a
  # trade.
  defp day_start(token) do
    since = DateTime.add(DateTime.utc_now(), -@day)

    Repo.one(
      from trade in TokenTrade,
        where: trade.token_id == ^token.id and trade.occurred_at >= ^since,
        select: min(trade.block_number)
    ) || token.trades_next_block
  end

  defp sum(charged, from_block, pool) do
    {currency, token} =
      for %{block: block} = fee <- charged, block >= from_block, reduce: {0, 0} do
        {currency, token} -> {currency + fee.currency, token + fee.token}
      end

    %{
      currency: Rpc.format_units(currency, pool.currency.decimals),
      token: Rpc.format_units(token, pool.token.decimals)
    }
  end
end
