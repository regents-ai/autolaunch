defmodule Autolaunch.LaunchChain do
  @moduledoc """
  The chain a launch draft is prepared for. Base is the live launchpad; Robinhood
  is the second launchpad, prepared on the same memestock form and launched once its
  contracts are live.
  """

  @chains [:base, :robinhood]

  def chains, do: @chains

  def label(:base), do: "Base"
  def label(:robinhood), do: "Robinhood"

  @doc "The auction currency each chain's Stocks launchpad measures its minimum in."
  def raise_currency(:base), do: "USDC"
  def raise_currency(:robinhood), do: "USDG"

  @doc """
  How long a number of blocks takes on the chain, in words. Base makes a block
  every two seconds and Robinhood's auctions count ten blocks a second, so this
  is always an estimate, never a promise.
  """
  def time_estimate(chain, blocks) when is_integer(blocks) and blocks >= 0 do
    seconds = seconds(chain, blocks)

    cond do
      seconds < 60 -> "less than a minute"
      seconds < 90 * 60 -> about(seconds / 60, "minute")
      seconds < 36 * 3600 -> about(seconds / 3600, "hour")
      true -> about(seconds / 86_400, "day")
    end
  end

  @doc "How many seconds a number of blocks takes on the chain, by its usual block time."
  def seconds(chain, blocks) when is_integer(blocks) and blocks >= 0,
    do: blocks * seconds_per_block(chain)

  defp seconds_per_block(:base), do: 2
  defp seconds_per_block(:robinhood), do: 0.1

  defp about(amount, unit) do
    case round(amount) do
      1 -> "about 1 #{unit}"
      count -> "about #{count} #{unit}s"
    end
  end
end
