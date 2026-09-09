defmodule Autolaunch.Stocks.LabAbi do
  @moduledoc false

  alias Autolaunch.LabAbi

  @launch_params "(string,string,string,string,string,address,uint64,uint256,uint128,address,address,uint256)"
  @launch_record "(address,address,address,address,address,uint64,uint64,uint64,uint64,uint128,uint256,uint8,bytes32,uint160,uint256,uint128,uint128,uint256,uint256,uint128)"
  @launch_record_words 20

  @launch_created "StockLaunchCreated(uint256,address,address,address,address,address,uint64,uint64,uint256,uint128,uint256,uint256)"
  @launch_graduated "StockLaunchGraduated(uint256,address,bytes32,uint160,uint256,uint128,uint128,uint256,uint128,uint256,uint256,uint256)"
  @fee_collected "StockLaunchFeeCollected(uint256,address,address,uint256)"
  @bid_placed "StockBidPlaced(address,address,uint256,uint256,uint128,uint256)"
  @subject_configured "SubjectConfigured(uint256,uint32,address,uint16,address)"
  @administrator_transfer_started "FeeAdministratorTransferStarted(uint256,address,address)"
  @administrator_transferred "FeeAdministratorTransferred(uint256,address,address)"
  @hook_fee_accrued "HookFeeAccrued(bytes32,address,uint256,uint256,uint256)"
  @bucket_settled "BucketSettled(bytes32,address,uint256,uint256,bytes32)"

  # Everything the site prepares against or decodes. A missing entry refuses the
  # whole configuration rather than failing later inside a review.
  @required %{
    "launchpad" => [
      f: {"launch(#{@launch_params})", "nonpayable", ["uint256", "address", "address"]},
      f: {"launches(uint256)", "view", [@launch_record]},
      f: {"launchIdOfAuction(address)", "view", ["uint256"]},
      f: {"nextLaunchId()", "view", ["uint256"]},
      f: {"launchesPaused()", "view", ["bool"]},
      f: {"launchFee()", "view", ["uint256"]},
      f: {"setLaunchFee(uint256)", "nonpayable", []},
      f: {"stockAdmission(address)", "view", ["bool", "uint8", "address"]},
      f:
        {"subjectConfig(uint256)", "view", ["uint32", "address", "uint16", "address", "address"]},
      f: {"bidTickSpacingFor(uint256)", "pure", ["uint256"]},
      f: {"hook()", "view", ["address"]},
      f: {"configureSubject(uint256,address,uint32)", "nonpayable", []},
      f: {"proposeFeeAdministrator(uint256,address)", "nonpayable", []},
      f: {"acceptFeeAdministrator(uint256)", "nonpayable", []},
      e:
        {@launch_created,
         [true, true, true, false, false, false, false, false, false, false, false, false]},
      e:
        {@launch_graduated,
         [true, true, false, false, false, false, false, false, false, false, false, false]},
      e: {@fee_collected, [true, true, true, false]},
      e: {"LaunchFeeUpdated(uint256,uint256)", [false, false]},
      e: {@subject_configured, [true, true, true, false, false]},
      e: {@administrator_transfer_started, [true, true, true]},
      e: {@administrator_transferred, [true, true, true]}
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
      f: {"REGENT_DESTINATION()", "pure", ["address"]},
      f: {"accrued(bytes32,address)", "view", ["uint256"]},
      f: {"settled(bytes32,address)", "view", ["uint256", "uint256"]},
      e: {@hook_fee_accrued, [true, true, false, false, false]},
      e: {@bucket_settled, [true, true, false, false, false]}
    ],
    "auction" => [
      f: {"submitBid(uint256,uint128,address,uint256,bytes)", "payable", ["uint256"]},
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
  def fee_collected_signature, do: @fee_collected
  def bid_placed_signature, do: @bid_placed
  def subject_configured_signature, do: @subject_configured
  def administrator_transfer_started_signature, do: @administrator_transfer_started
  def administrator_transferred_signature, do: @administrator_transferred
  def hook_fee_accrued_signature, do: @hook_fee_accrued
  def bucket_settled_signature, do: @bucket_settled
  def validate(abis), do: LabAbi.validate(abis, @required)
end
