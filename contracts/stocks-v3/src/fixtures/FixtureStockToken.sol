// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";
import {FixtureStockCatalog} from "./FixtureStockCatalog.sol";

/// @title FixtureStockToken
/// @notice The ERC-20 the local Base-fork lab installs at the catalog addresses with `anvil_setCode`.
/// @dev LAB ONLY. This is a fixture: eight decimals like the live tokens, mintable by anyone so the
///      lab faucet and the fixture routes can be funded, and NOT the Base-native stock token whose
///      `0xef` runtime code Anvil cannot execute. Nothing tested against it is B20-verified.
///
///      The runtime code is address-independent by construction — no immutables, no constructor
///      state — so one compiled `deployedBytecode` can be installed at every catalog address, and
///      `name()`/`symbol()` resolve from `address(this)` against the catalog, so no initialization
///      transaction is needed after installation.
contract FixtureStockToken is ERC20 {
    function name() public view override returns (string memory) {
        return string.concat("Fixture ", FixtureStockCatalog.symbolOf(address(this)));
    }

    function symbol() public view override returns (string memory) {
        return FixtureStockCatalog.symbolOf(address(this));
    }

    function decimals() public pure override returns (uint8) {
        return FixtureStockCatalog.DECIMALS;
    }

    /// @dev A plain ERC-20 allowance model: no implicit infinite Permit2 allowance, so the exact
    ///      approve-then-restore discipline of the adapter is exercised against ordinary semantics.
    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }

    /// @notice Anyone may mint. Lab faucet only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
