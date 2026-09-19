defmodule Autolaunch.Robinhood do
  @moduledoc """
  Stand-in Robinhood launchpad terms, mirroring `contracts/robinhood/src/RobinhoodPreset.sol`.

  The Robinhood stocks launchpad is not deployed, so nothing here is read from a
  chain yet; a chain client replaces these values once the founder supplies
  the Robinhood bindings.
  """

  @doc "The stocks launchpad's USDG minimum raise, in whole USDG."
  def minimum_raise_usdg, do: "1000"

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
      {"Staker revenue lane",
       "1.00% of stock-side pool volume to the token's stakers, always on"},
      {"Pool fee", "0.30%"},
      {"Unsold tokens", "Retired to 0x…dEaD after a successful auction"},
      {"Pool liquidity", "Locked forever in the fee locker; its trading fees go to stakers"},
      {"If the minimum is not raised", "Every bid is refundable through the auction"}
    ]
  end
end
