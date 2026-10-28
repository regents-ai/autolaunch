// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @title ExposureLegV1
/// @notice One leg of an exposure series, OVERNIGHT or SESSION: an ordinary transferable token. Only
///         the series that created it can mint or burn it, and it burns only from the caller of the
///         series, so holders never approve the series to spend their legs.
contract ExposureLegV1 is ERC20 {
    address public immutable series;
    uint8 internal immutable _decimals;
    string internal _name;
    string internal _symbol;

    error NotSeries();

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        series = msg.sender;
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @dev No standing allowance for Permit2: a holder approves every spender themselves.
    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != series) revert NotSeries();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != series) revert NotSeries();
        _burn(from, amount);
    }
}
