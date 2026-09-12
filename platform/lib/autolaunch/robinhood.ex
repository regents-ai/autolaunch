defmodule Autolaunch.Robinhood do
  @moduledoc """
  Stand-in Robinhood launchpad terms, mirroring `contracts/robinhood/src/RobinhoodPreset.sol`.

  The Robinhood launchpads are not deployed, so nothing here is read from a
  chain yet; a chain client replaces these values once the founder supplies
  the Robinhood bindings.
  """

  @minimum_raise_usdg %{revshare: "5000", stocks: "1000"}

  @doc "The launchpad's USDG minimum raise for one launch kind, in whole USDG."
  def minimum_raise_usdg(kind) when kind in [:revshare, :stocks],
    do: Map.fetch!(@minimum_raise_usdg, kind)

  @doc "The fixed terms every Robinhood stock launch uses, worded for the create page."
  def stock_terms do
    [
      {"Launch fee", "None"},
      {"Token decimals", "18"},
      {"Initial supply", "1,000,000,000 NEW"},
      {"Sold at auction", "800,000,000 NEW (80%)"},
      {"Pool reserve", "200,000,000 NEW (20%)"},
      {"Creator allocation", "None"},
      {"Vesting", "None"},
      {"Treasury", "None"},
      {"Protocol revenue lane", "1.00% of stock-side pool volume"},
      {"Subject revenue lane", "Off, or 1.00% when enabled"},
      {"Pool fee", "0.30%"},
      {"Unsold tokens", "Retired to 0x…dEaD after a successful auction"},
      {"Pool liquidity", "Locked forever at 0x…dEaD"},
      {"If the minimum is not raised", "Every bid is refundable through the auction"}
    ]
  end
end
