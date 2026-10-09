defmodule Autolaunch.Stocks.LabAbi do
  @moduledoc false

  alias Autolaunch.LabAbi

  @launch_params "(string,string,string,string,string,address)"
  @launch_record "(address,address,address,address,address,uint64,uint64,uint64,uint64,uint8,bytes32,uint160,uint256,uint128,uint128,uint256,uint128,uint64,uint128,uint256)"

  # `launches(uint256)`, field by field: the full-range position, the
  # new-token-only position above the opening price, and the creator's vesting.
  @launch_fields [
    :launcher,
    :new_token,
    :stock,
    :auction,
    :splitter,
    :start_block,
    :end_block,
    :claim_block,
    :migration_block,
    :lifecycle,
    :pool_id,
    :final_sqrt_price_x96,
    :lp_token_id,
    :lp_stock_used,
    :lp_new_used,
    :new_only_token_id,
    :new_only_used,
    :vesting_start_block,
    :creator_released,
    :retired_new
  ]

  @launch_created "StockLaunchCreated(uint256,address,address,address,address,uint64,uint64,uint256,uint256,uint256)"
  @launch_graduated "StockLaunchGraduated(uint256,address,bytes32,uint160,uint256,uint128,uint128,uint256,uint128,uint256,uint256,uint256)"
  @creator_vesting_released "CreatorVestingReleased(uint256,address,uint256)"
  @splitter_created "MemestockSplitterCreated(uint256,address,address,address)"
  @bid_placed "StockBidPlaced(address,address,uint256,uint256,uint128,uint256)"
  @hook_fee_accrued "HookFeeAccrued(bytes32,uint256,uint256,uint256,uint256)"
  @creator_lane_settled "CreatorLaneSettled(bytes32,address,uint256)"
  @regent_lane_settled "RegentLaneSettled(bytes32,uint256,uint256)"
  @staker_lane_settled "StakerLaneSettled(bytes32,address,uint256)"
  @fees_deposited "FeesDeposited(uint256,address,address,address,uint256,uint256)"
  @staked "Staked(address,uint256)"
  @unstaked "Unstaked(address,uint256)"
  @claimed "Claimed(address,address,uint256)"

  # The first Memestake launchpad (BITE, JollyB and AGI): a launch record that
  # carries its required raise and floor and ends in the stock-only position,
  # and a hook with only REGENT's and the stakers' lanes.
  @v1_launch_record "(address,address,address,address,address,uint64,uint64,uint64,uint64,uint128,uint256,uint8,bytes32,uint160,uint256,uint128,uint128,uint256,uint256,uint128)"
  @v1_launch_fields [
    :launcher,
    :new_token,
    :stock,
    :auction,
    :splitter,
    :start_block,
    :end_block,
    :claim_block,
    :migration_block,
    :required_stock_raised,
    :floor_price_q96,
    :lifecycle,
    :pool_id,
    :final_sqrt_price_x96,
    :lp_token_id,
    :lp_stock_used,
    :lp_new_used,
    :retired_new,
    :stock_only_token_id,
    :stock_only_used
  ]
  @v1_hook_fee_accrued "HookFeeAccrued(bytes32,uint256,uint256,uint256)"

  # Everything the site prepares against or decodes. A missing entry refuses the
  # whole configuration rather than failing later inside a review.
  @required %{
    "launchpad" => [
      f: {"launch(#{@launch_params})", "nonpayable", ["uint256", "address", "address"]},
      f: {"launches(uint256)", "view", [@launch_record]},
      f: {"launchIdOfAuction(address)", "view", ["uint256"]},
      f: {"launchIdOfToken(address)", "view", ["uint256"]},
      f: {"nextLaunchId()", "view", ["uint256"]},
      f: {"migrate(uint256)", "nonpayable", []},
      f: {"launchesPaused()", "view", ["bool"]},
      f: {"stockAdmission(address)", "view", ["bool", "uint8", "address"]},
      f: {"creatorReleasable(uint256)", "view", ["uint256"]},
      f: {"releaseCreatorVesting(uint256)", "nonpayable", ["uint256"]},
      f: {"hook()", "view", ["address"]},
      f: {"locker()", "view", ["address"]},
      f: {"splitterImplementation()", "view", ["address"]},
      e: {@launch_created, [true, true, true, false, false, false, false, false, false, false]},
      e:
        {@launch_graduated,
         [true, true, false, false, false, false, false, false, false, false, false, false]},
      e: {@splitter_created, [true, true, true, false]},
      e: {@creator_vesting_released, [true, true, false]}
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
      f: {"accrued(bytes32)", "view", ["uint256", "uint256", "uint256"]},
      f: {"settled(bytes32)", "view", ["uint256", "uint256", "uint256", "uint256"]},
      f: {"settleCreatorLane(bytes32)", "nonpayable", ["uint256"]},
      f: {"settleStakerLane(bytes32)", "nonpayable", ["uint256"]},
      f: {"executor()", "view", ["address"]},
      f: {"settleRegentLane(bytes32,uint256,uint256)", "nonpayable", []},
      e: {@hook_fee_accrued, [true, false, false, false, false]},
      e: {@creator_lane_settled, [true, true, false]},
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

  # What the site reads from the first launchpad, hook and locker.
  @v1_required %{
    "launchpad" => [
      f: {"launches(uint256)", "view", [@v1_launch_record]},
      f: {"launchIdOfAuction(address)", "view", ["uint256"]},
      f: {"migrate(uint256)", "nonpayable", []},
      f: {"stockAdmission(address)", "view", ["bool", "uint8", "address"]}
    ],
    "hook" => [
      f: {"accrued(bytes32)", "view", ["uint256", "uint256"]},
      f: {"settled(bytes32)", "view", ["uint256", "uint256", "uint256"]},
      f: {"settleStakerLane(bytes32)", "nonpayable", ["uint256"]},
      f: {"executor()", "view", ["address"]},
      f: {"settleRegentLane(bytes32,uint256,uint256)", "nonpayable", []},
      e: {@v1_hook_fee_accrued, [true, false, false, false]},
      e: {@regent_lane_settled, [true, false, false]},
      e: {@staker_lane_settled, [true, true, false]}
    ],
    "locker" => @required["locker"]
  }

  @doc """
  The shape of one Memestake launchpad version's records and hook: the fields
  of a launch record in word order, the hook's lanes in the order `accrued`
  returns them, its fee event, and the event each lane's settlement emits.
  """
  def shape(:v2),
    do: %{
      record_fields: @launch_fields,
      record_words: length(@launch_fields),
      lanes: [:creator, :regent, :stakers],
      fee_accrued: @hook_fee_accrued,
      lane_settled: %{
        creator: @creator_lane_settled,
        regent: @regent_lane_settled,
        stakers: @staker_lane_settled
      }
    }

  def shape(:v1),
    do: %{
      record_fields: @v1_launch_fields,
      record_words: length(@v1_launch_fields),
      lanes: [:regent, :stakers],
      fee_accrued: @v1_hook_fee_accrued,
      lane_settled: %{regent: @regent_lane_settled, stakers: @staker_lane_settled}
    }

  def requirements, do: @required
  def launch_record_words, do: length(@launch_fields)

  @doc "One `launches(uint256)` answer, by field, read with its version's shape."
  def record(%{record_fields: fields}, words) when length(words) == length(fields),
    do: fields |> Enum.zip(words) |> Map.new()

  def launch_signature, do: "launch(#{@launch_params})"
  def launch_created_signature, do: @launch_created
  def launch_graduated_signature, do: @launch_graduated
  def splitter_created_signature, do: @splitter_created
  def bid_placed_signature, do: @bid_placed
  def hook_fee_accrued_signature, do: @hook_fee_accrued
  def creator_lane_settled_signature, do: @creator_lane_settled
  def regent_lane_settled_signature, do: @regent_lane_settled
  def staker_lane_settled_signature, do: @staker_lane_settled
  def fees_deposited_signature, do: @fees_deposited
  def staked_signature, do: @staked
  def unstaked_signature, do: @unstaked
  def claimed_signature, do: @claimed
  def creator_vesting_released_signature, do: @creator_vesting_released
  def validate(abis), do: LabAbi.validate(abis, @required)
  def validate_v1(abis), do: LabAbi.validate(abis, @v1_required)
end
