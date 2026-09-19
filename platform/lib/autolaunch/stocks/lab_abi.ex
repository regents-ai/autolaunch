defmodule Autolaunch.Stocks.LabAbi do
  @moduledoc false

  alias Autolaunch.LabAbi

  @launch_params "(string,string,string,string,string,address,uint64,uint256,uint256)"
  @launch_record "(address,address,address,address,address,uint64,uint64,uint64,uint64,uint128,uint256,uint8,bytes32,uint160,uint256,uint128,uint128,uint256,uint256,uint128)"
  @launch_record_words 20

  @launch_created "StockLaunchCreated(uint256,address,address,address,address,uint64,uint64,uint256,uint128,uint256,uint256)"
  @launch_graduated "StockLaunchGraduated(uint256,address,bytes32,uint160,uint256,uint128,uint128,uint256,uint128,uint256,uint256,uint256)"
  @splitter_created "MemestockSplitterCreated(uint256,address,address,address)"
  @fee_collected "StockLaunchFeeCollected(uint256,address,address,uint256)"
  @bid_placed "StockBidPlaced(address,address,uint256,uint256,uint128,uint256)"
  @hook_fee_accrued "HookFeeAccrued(bytes32,uint256,uint256,uint256)"
  @regent_lane_settled "RegentLaneSettled(bytes32,uint256,uint256)"
  @staker_lane_settled "StakerLaneSettled(bytes32,address,uint256)"
  @fees_deposited "FeesDeposited(uint256,address,address,address,uint256,uint256)"
  @staked "Staked(address,uint256)"
  @unstaked "Unstaked(address,uint256)"
  @claimed "Claimed(address,address,uint256)"

  # Everything the site prepares against or decodes. A missing entry refuses the
  # whole configuration rather than failing later inside a review.
  @required %{
    "launchpad" => [
      f: {"launch(#{@launch_params})", "nonpayable", ["uint256", "address", "address"]},
      f: {"launches(uint256)", "view", [@launch_record]},
      f: {"launchIdOfAuction(address)", "view", ["uint256"]},
      f: {"launchIdOfToken(address)", "view", ["uint256"]},
      f: {"nextLaunchId()", "view", ["uint256"]},
      f: {"launchesPaused()", "view", ["bool"]},
      f: {"launchFee()", "view", ["uint256"]},
      f: {"setLaunchFee(uint256)", "nonpayable", []},
      f: {"minimumRaiseUsdc()", "view", ["uint256"]},
      f: {"setMinimumRaiseUsdc(uint256)", "nonpayable", []},
      f: {"stockAdmission(address)", "view", ["bool", "uint8", "address"]},
      f: {"bidTickSpacingFor(uint256)", "pure", ["uint256"]},
      f: {"hook()", "view", ["address"]},
      f: {"locker()", "view", ["address"]},
      f: {"splitterImplementation()", "view", ["address"]},
      e:
        {@launch_created,
         [true, true, true, false, false, false, false, false, false, false, false]},
      e:
        {@launch_graduated,
         [true, true, false, false, false, false, false, false, false, false, false, false]},
      e: {@splitter_created, [true, true, true, false]},
      e: {@fee_collected, [true, true, true, false]},
      e: {"LaunchFeeUpdated(uint256,uint256)", [false, false]},
      e: {"MinimumRaiseUsdcUpdated(uint256,uint256)", [false, false]}
    ],
    "bid_adapter" => [
      f:
        {"bidWithUsdc(address,uint256,uint128,uint256,uint256,uint256)", "nonpayable",
         ["uint256", "uint128"]},
      f: {"usdc()", "view", ["address"]},
      f: {"launchpad()", "view", ["address"]},
      e: {@bid_placed, [true, true, true, false, false, false]}
    ],
    "route" => [
      f: {"quoteExactIn(address,address,uint256)", "view", ["uint256"]},
      f: {"stock()", "view", ["address"]},
      f: {"usdc()", "view", ["address"]}
    ],
    "hook" => [
      f: {"launchpad()", "view", ["address"]},
      f: {"accrued(bytes32)", "view", ["uint256", "uint256"]},
      f: {"settled(bytes32)", "view", ["uint256", "uint256", "uint256"]},
      f: {"settleStakerLane(bytes32)", "nonpayable", ["uint256"]},
      e: {@hook_fee_accrued, [true, false, false, false]},
      e: {@regent_lane_settled, [true, false, false]},
      e: {@staker_lane_settled, [true, true, false]}
    ],
    "locker" => [
      f: {"collect(uint256)", "nonpayable", ["uint256", "uint256"]},
      f: {"splitterOf(uint256)", "view", ["address"]},
      e: {"PositionLocked(uint256,bytes32,address)", [true, true, true]},
      e: {@fees_deposited, [true, true, false, false, false, false]}
    ],
    "splitter" => [
      f: {"memestock()", "view", ["address"]},
      f: {"stock()", "view", ["address"]},
      f: {"dollar()", "view", ["address"]},
      f: {"totalStaked()", "view", ["uint256"]},
      f: {"stakedOf(address)", "view", ["uint256"]},
      f: {"claimable(address,address)", "view", ["uint256"]},
      f: {"SKIM_BPS()", "view", ["uint256"]},
      f: {"stake(uint256)", "nonpayable", []},
      f: {"unstake(uint256)", "nonpayable", []},
      f: {"claim(address)", "nonpayable", []},
      f: {"claimAll()", "nonpayable", []},
      e: {@staked, [true, false]},
      e: {@unstaked, [true, false]},
      e: {@claimed, [true, true, false]}
    ],
    "auction" => [
      f: {"submitBid(uint256,uint128,address,uint256,bytes)", "payable", ["uint256"]},
      f: {"bids(uint256)", "view", ["(uint64,uint24,uint64,uint256,address,uint256,uint256)"]},
      f: {"startBlock()", "view", ["uint64"]},
      f: {"endBlock()", "view", ["uint64"]},
      f: {"claimBlock()", "view", ["uint64"]},
      f: {"isGraduated()", "view", ["bool"]},
      f: {"clearingPrice()", "view", ["uint256"]},
      f: {"currency()", "view", ["address"]},
      f: {"floorPrice()", "view", ["uint256"]},
      f: {"tickSpacing()", "view", ["uint256"]},
      f: {"MAX_BID_PRICE()", "view", ["uint256"]},
      f: {"checkpoint()", "nonpayable", ["(uint256,uint256,uint256,uint24,uint64,uint64)"]},
      f: {"ticks(uint256)", "view", ["(uint256,uint256)"]},
      e: {"BidSubmitted(uint256,address,uint256,uint128)", [true, true, false, false]}
    ],
    "erc20" => [
      f: {"approve(address,uint256)", "nonpayable", ["bool"]},
      f: {"transfer(address,uint256)", "nonpayable", ["bool"]},
      f: {"balanceOf(address)", "view", ["uint256"]},
      f: {"allowance(address,address)", "view", ["uint256"]},
      f: {"decimals()", "view", ["uint8"]},
      e: {"Approval(address,address,uint256)", [true, true, false]}
    ],
    "permit2" => [
      f: {"approve(address,address,uint160,uint48)", "nonpayable", []},
      f: {"allowance(address,address,address)", "view", ["uint160", "uint48", "uint48"]}
    ]
  }

  def requirements, do: @required
  def launch_record_words, do: @launch_record_words
  def launch_signature, do: "launch(#{@launch_params})"
  def launch_created_signature, do: @launch_created
  def launch_graduated_signature, do: @launch_graduated
  def splitter_created_signature, do: @splitter_created
  def fee_collected_signature, do: @fee_collected
  def bid_placed_signature, do: @bid_placed
  def hook_fee_accrued_signature, do: @hook_fee_accrued
  def regent_lane_settled_signature, do: @regent_lane_settled
  def staker_lane_settled_signature, do: @staker_lane_settled
  def fees_deposited_signature, do: @fees_deposited
  def staked_signature, do: @staked
  def unstaked_signature, do: @unstaked
  def claimed_signature, do: @claimed
  def validate(abis), do: LabAbi.validate(abis, @required)
end
