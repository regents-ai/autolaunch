// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @title LabStockToken
/// @notice LAB ONLY. The AMZNc stand-in the local Base copy runs covered calls against
///         (platform/test/journeys/support/base_fork.py, `covered-calls`). A local chain cannot run
///         Base's B20 precompiles, so the journeys install contracts/stocks-v2's FixtureStockToken at
///         each stock; this is that same token, installed over it at AMZNc, with the two B20 Asset
///         reads covered calls make: `multiplier()` and `effectiveAt()`, plus `schedule` to stage a
///         corporate action and `setPaused` to stage an issuer's transfer pause on the copy (as on
///         Base, a pause stops `transfer` and `transferFrom` but not `approve`).
/// @dev Solady's ERC20 keeps balances and allowances in hashed slots and this contract's own state
///      sits in slots 0 and 1, so installing this over FixtureStockToken keeps every balance minted.
contract LabStockToken is ERC20 {
    /// @notice When a scheduled multiplier change takes effect; 0, as on Base, when none is.
    uint256 public effectiveAt;
    /// @notice Whether the issuer has paused transfers on the copy.
    bool public transfersPaused;

    error ContractPaused();

    function name() public pure override returns (string memory) {
        return "Fixture AMZNc";
    }

    function symbol() public pure override returns (string memory) {
        return "AMZNc";
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    /// @notice The B20 multiplier, WAD: AMZNc's reads exactly 1.0 on Base.
    function multiplier() external pure returns (uint256) {
        return 1e18;
    }

    /// @dev As FixtureStockToken: a plain allowance model, no implicit Permit2 allowance.
    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }

    /// @notice Anyone may mint. Lab faucet only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (transfersPaused) revert ContractPaused();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (transfersPaused) revert ContractPaused();
        return super.transferFrom(from, to, amount);
    }

    /// @notice Stages or lifts an issuer's transfer pause. Lab only.
    function setPaused(bool paused) external {
        transfersPaused = paused;
    }

    /// @notice Stages a scheduled multiplier change at `at` (0 clears it). Lab only.
    function schedule(uint256 at) external {
        effectiveAt = at;
    }
}
