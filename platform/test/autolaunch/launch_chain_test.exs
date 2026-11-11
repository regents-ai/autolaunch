defmodule Autolaunch.LaunchChainTest do
  @moduledoc """
  The durations the pages and public documents state, worked out from each
  launch's fixed schedule in blocks at its chain's block time.
  """
  use ExUnit.Case, async: true

  alias Autolaunch.LaunchActions, as: RevstakeLaunchActions
  alias Autolaunch.LaunchChain
  alias Autolaunch.Stocks.LaunchActions

  test "each launch's schedule gives its auction length and a creator's release on its chain" do
    base = LaunchActions.schedule(:base)
    robinhood = LaunchActions.schedule(:robinhood)

    # Base, five blocks a second: 43,200 blocks, 1,296,000 blocks and 300 blocks.
    assert LaunchChain.time_estimate(:base, base.length) == "about 2 hours"
    assert LaunchChain.time_estimate(:base, base.vesting) == "about 3 days"
    assert LaunchChain.time_estimate(:base, base.opens) == "about 1 minute"
    # A Revstake auction on Base: 86,401 blocks.
    assert LaunchChain.time_estimate(:base, RevstakeLaunchActions.schedule().length) ==
             "about 5 hours"

    # Robinhood, ten blocks a second: 864,000 blocks and 25,920,000 blocks.
    assert LaunchChain.time_estimate(:robinhood, robinhood.length) == "about 24 hours"
    assert LaunchChain.time_estimate(:robinhood, robinhood.vesting) == "about 30 days"
  end
end
