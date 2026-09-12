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
end
