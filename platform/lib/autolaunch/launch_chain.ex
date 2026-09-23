defmodule Autolaunch.LaunchChain do
  @moduledoc """
  The chain a launch draft is prepared for. Base is the live launchpad; Robinhood
  is the second launchpad, prepared on the same page and launched once its
  contracts are live.
  """

  @chains [:base, :robinhood]

  def chains, do: @chains

  @doc "The chain a `/create` request names; anything but `robinhood` is Base."
  def from_param("robinhood"), do: :robinhood
  def from_param(_param), do: :base

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
    seconds = blocks * seconds_per_block(chain)

    cond do
      seconds < 60 -> "less than a minute"
      seconds < 90 * 60 -> about(seconds / 60, "minute")
      seconds < 36 * 3600 -> about(seconds / 3600, "hour")
      true -> about(seconds / 86_400, "day")
    end
  end

  defp seconds_per_block(:base), do: 2
  defp seconds_per_block(:robinhood), do: 0.1

  defp about(amount, unit) do
    case round(amount) do
      1 -> "about 1 #{unit}"
      count -> "about #{count} #{unit}s"
    end
  end
end
