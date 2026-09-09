defmodule Autolaunch.Stocks.LabAbi do
  @moduledoc false

  alias Autolaunch.LabAbi

  @launch_params "(string,string,string,string,string,address,uint64,uint256,uint128,address,address)"
  @launch_record "(address,address,address,address,address,uint64,uint64,uint64,uint64,uint128,uint256,uint8,bytes32,uint160,uint256,uint128,uint128,uint256,uint256,uint128)"
  @launch_record_words 20

  @launch_created "StockLaunchCreated(uint256,address,address,address,address,address,uint64,uint64,uint256,uint128,uint256,uint256)"
  @bid_placed "StockBidPlaced(address,address,uint256,uint256,uint128,uint256)"

  # Everything the site prepares against or decodes. A missing entry refuses the
  # whole configuration rather than failing later inside a review.
  @required %{
    "launchpad" => [
      f: {"launch(#{@launch_params})", "nonpayable", ["uint256", "address", "address"]},
      f: {"launches(uint256)", "view", [@launch_record]},
      f: {"launchIdOfAuction(address)", "view", ["uint256"]},
      f: {"nextLaunchId()", "view", ["uint256"]},
      f: {"launchesPaused()", "view", ["bool"]},
      f: {"stockAdmission(address)", "view", ["bool", "uint8", "address"]},
      f:
        {"subjectConfig(uint256)", "view", ["uint32", "address", "uint16", "address", "address"]},
      f: {"bidTickSpacingFor(uint256)", "pure", ["uint256"]},
      f: {"hook()", "view", ["address"]},
      e:
        {@launch_created,
         [true, true, true, false, false, false, false, false, false, false, false, false]}
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
      f: {"accrued(bytes32,address)", "view", ["uint256"]}
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
  def bid_placed_signature, do: @bid_placed
  def validate(abis), do: LabAbi.validate(abis, @required)
end
