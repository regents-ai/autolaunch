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
    second = LaunchActions.schedule(:base, :v2)
    third = LaunchActions.schedule(:base, :v3)
    robinhood = LaunchActions.schedule(:robinhood)

    # Base's second launchpad, five blocks a second: 43,200 blocks and 300
    # blocks, and the creator's release over 1,296,000 blocks.
    assert LaunchChain.time_estimate(:base, second.length) == "about 2 hours"
    assert LaunchChain.time_estimate(:base, second.opens) == "about 1 minute"
    assert LaunchActions.release(:base, :v2) == "block by block over about 3 days"

    # Base's third: 431,991 blocks and 3,000 blocks, and the release by the
    # clock over 30 days.
    assert LaunchChain.time_estimate(:base, third.length) == "about 24 hours"
    assert LaunchChain.time_estimate(:base, third.opens) == "about 10 minutes"
    assert LaunchActions.release(:base, :v3) == "steadily over 30 days"
    assert LaunchActions.vesting_seconds(:base, :v3) == 30 * 86_400

    # A Revstake auction on Base: 86,401 blocks on the second factory, 864,001
    # on the third.
    assert LaunchChain.time_estimate(:base, RevstakeLaunchActions.schedule(:v2).length) ==
             "about 5 hours"

    assert LaunchChain.time_estimate(:base, RevstakeLaunchActions.schedule(:v3).length) ==
             "about 2 days"

    # Robinhood, ten blocks a second: 864,000 blocks and 25,920,000 blocks.
    assert LaunchChain.time_estimate(:robinhood, robinhood.length) == "about 24 hours"
    assert LaunchActions.release(:robinhood) == "block by block over about 30 days"
  end

  test "a new launch's schedule is that of the launchers the descriptions name" do
    # The tests' descriptions name the third launchers, as today's do.
    assert LaunchActions.schedule(:base) == LaunchActions.schedule(:base, :v3)
    assert LaunchActions.release(:base) == "steadily over 30 days"
    assert RevstakeLaunchActions.schedule() == RevstakeLaunchActions.schedule(:v3)
  end
end
