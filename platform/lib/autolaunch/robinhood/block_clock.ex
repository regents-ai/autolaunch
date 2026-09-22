defmodule Autolaunch.Robinhood.BlockClock do
  @moduledoc """
  The block number the Robinhood contracts keep time by.

  Robinhood is an Arbitrum Orbit rollup: the Stocks launchpad and every auction
  read the rollup block from the ArbSys precompile (`arbBlockNumber()` at
  `0x…64`), not from `block.number`. So does every comparison the site makes
  with an auction's start, end or claim block, read at the same pinned block as
  the rest of the snapshot. On the real chain it agrees with the chain's own
  block within a few blocks; on the lab only the precompile is right, since the
  lab controller sets it so a whole auction plays out in minutes.
  """

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.LabAbi

  @arb_sys "0x0000000000000000000000000000000000000064"

  @doc "The rollup block the contracts saw at the pinned block."
  @spec read(map(), keyword()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def read(block, opts),
    do: Rpc.call_uint(@arb_sys, LabAbi.selector("arbBlockNumber()"), block, opts)
end
