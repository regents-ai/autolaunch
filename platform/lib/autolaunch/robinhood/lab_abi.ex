defmodule Autolaunch.Robinhood.LabAbi do
  @moduledoc false

  alias Autolaunch.LabAbi

  @core_params "(string,string,string,string,string,uint64,uint256,uint256)"
  @launch_params "(#{@core_params},address,uint128)"
  @launch_record "(address,address,address,address,uint64,uint64,uint64,uint64,uint128,uint256,uint8,bytes32,uint160,uint256,uint128,uint128,uint256)"
  @launch_record_words 17

  @launch_created "RevshareLaunchCreated(uint256,address,address,address,address,uint64,uint64,uint256,uint128,uint128,uint128)"

  # Everything the site prepares against or decodes. A missing entry refuses the
  # whole configuration rather than failing later inside a review.
  @required %{
    "launchpad" => [
      f: {"launch(#{@launch_params})", "nonpayable", ["uint256", "address", "address"]},
      f: {"launches(uint256)", "view", [@launch_record]},
      f: {"launchIdOfAuction(address)", "view", ["uint256"]},
      f: {"launchesPaused()", "view", ["bool"]},
      f: {"launchFee()", "view", ["uint256"]},
      f: {"minimumRaiseUsdg()", "view", ["uint256"]},
      f: {"hook()", "view", ["address"]},
      e:
        {@launch_created,
         [true, true, true, false, false, false, false, false, false, false, false]}
    ],
    "erc20" => [
      f: {"approve(address,uint256)", "nonpayable", ["bool"]},
      f: {"balanceOf(address)", "view", ["uint256"]},
      f: {"allowance(address,address)", "view", ["uint256"]},
      f: {"decimals()", "view", ["uint8"]},
      e: {"Approval(address,address,uint256)", [true, true, false]}
    ]
  }

  def launch_record_words, do: @launch_record_words
  def launch_signature, do: "launch(#{@launch_params})"
  def launch_created_signature, do: @launch_created
  def validate(abis), do: LabAbi.validate(abis, @required)
end
