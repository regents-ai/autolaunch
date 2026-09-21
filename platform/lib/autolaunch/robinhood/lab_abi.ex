defmodule Autolaunch.Robinhood.LabAbi do
  @moduledoc false

  alias Autolaunch.LabAbi

  @core_params "(string,string,string,string,string,uint256)"
  @stocks_launch_params "(#{@core_params},address,uint128)"
  @launch_record "(address,address,address,address,uint64,uint64,uint64,uint64,uint128,uint256,uint8,bytes32,uint160,address,uint256,uint128,uint128,uint256)"
  @launch_record_words 18

  @stock_launch_created "StockLaunchCreated(uint256,address,address,address,address,uint64,uint64,uint256,uint128,uint128,uint128)"
  @splitter_created "MemestockSplitterCreated(uint256,address,address,address)"
  @stock_bid_placed "StockBidPlaced(address,address,uint256,uint256,uint128,uint256)"
  @bid_submitted "BidSubmitted(uint256,address,uint256,uint128)"
  @hook_fee_accrued "HookFeeAccrued(bytes32,uint256,uint256,uint256)"
  @protocol_lane_settled "ProtocolLaneSettled(bytes32,uint256,uint256)"
  @staker_lane_settled "StakerLaneSettled(bytes32,address,uint256)"
  @fees_deposited "FeesDeposited(uint256,address,address,address,uint256,uint256)"
  @claimed "Claimed(address,address,uint256)"
  @bid_record "(uint64,uint24,uint64,uint256,address,uint256,uint256)"
  @checkpoint "(uint256,uint256,uint256,uint24,uint64,uint64)"

  # Everything the site prepares against or decodes. A missing entry refuses the
  # whole configuration rather than failing later inside a review.
  @required %{
    "stocks_launchpad" => [
      f: {"launch(#{@stocks_launch_params})", "nonpayable", ["uint256", "address", "address"]},
      f: {"launches(uint256)", "view", [@launch_record]},
      f: {"launchIdOfAuction(address)", "view", ["uint256"]},
      f: {"launchIdOfToken(address)", "view", ["uint256"]},
      f: {"nextLaunchId()", "view", ["uint256"]},
      f: {"launchesPaused()", "view", ["bool"]},
      f: {"stockAdmission(address)", "view", ["bool", "uint8", "address"]},
      f: {"stockRecords(uint256)", "view", ["(uint256,uint128)"]},
      f: {"hook()", "view", ["address"]},
      f: {"locker()", "view", ["address"]},
      f: {"splitterImplementation()", "view", ["address"]},
      e:
        {@stock_launch_created,
         [true, true, true, false, false, false, false, false, false, false, false]},
      e: {@splitter_created, [true, true, true, false]}
    ],
    "stocks_hook" => [
      f: {"launchpad()", "view", ["address"]},
      f: {"accrued(bytes32)", "view", ["uint256", "uint256"]},
      f: {"settled(bytes32)", "view", ["uint256", "uint256", "uint256"]},
      f: {"settleStakerLane(bytes32)", "nonpayable", ["uint256"]},
      e: {@hook_fee_accrued, [true, false, false, false]},
      e: {@protocol_lane_settled, [true, false, false]},
      e: {@staker_lane_settled, [true, true, false]}
    ],
    "stocks_locker" => [
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
      e: {"Staked(address,uint256)", [true, false]},
      e: {"Unstaked(address,uint256)", [true, false]},
      e: {@claimed, [true, true, false]}
    ],
    "bid_adapter" => [
      f:
        {"bidWithUsdg(address,uint256,uint128,uint256,uint256,uint256)", "nonpayable",
         ["uint256", "uint128"]},
      f: {"launchpad()", "view", ["address"]},
      f: {"usdg()", "view", ["address"]},
      e: {@stock_bid_placed, [true, true, true, false, false, false]}
    ],
    "stock_route" => [
      f: {"quoteExactIn(address,address,uint256)", "view", ["uint256"]}
    ],
    # The Continuous Clearing Auction the Stocks launchpad creates; only what
    # the bid reader reads.
    "auction" => [
      f: {"currency()", "view", ["address"]},
      f: {"floorPrice()", "view", ["uint256"]},
      f: {"tickSpacing()", "view", ["uint256"]},
      f: {"clearingPrice()", "view", ["uint256"]},
      f: {"MAX_BID_PRICE()", "view", ["uint256"]},
      f: {"checkpoint()", "nonpayable", [@checkpoint]},
      f: {"startBlock()", "view", ["uint64"]},
      f: {"endBlock()", "view", ["uint64"]},
      f: {"claimBlock()", "view", ["uint64"]},
      f: {"isGraduated()", "view", ["bool"]},
      f: {"ticks(uint256)", "view", ["(uint256,uint256)"]},
      f: {"bids(uint256)", "view", [@bid_record]},
      e: {@bid_submitted, [true, true, false, false]}
    ],
    "erc20" => [
      f: {"approve(address,uint256)", "nonpayable", ["bool"]},
      f: {"balanceOf(address)", "view", ["uint256"]},
      f: {"allowance(address,address)", "view", ["uint256"]},
      f: {"decimals()", "view", ["uint8"]},
      f: {"symbol()", "view", ["string"]},
      e: {"Approval(address,address,uint256)", [true, true, false]}
    ]
  }

  def launch_record_words, do: @launch_record_words
  def stocks_launch_signature, do: "launch(#{@stocks_launch_params})"
  def stock_launch_created_signature, do: @stock_launch_created
  def splitter_created_signature, do: @splitter_created
  def stock_bid_placed_signature, do: @stock_bid_placed
  def bid_submitted_signature, do: @bid_submitted
  def staker_lane_settled_signature, do: @staker_lane_settled
  def fees_deposited_signature, do: @fees_deposited
  def claimed_signature, do: @claimed
  def validate(abis), do: LabAbi.validate(abis, @required)
end
