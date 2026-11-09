// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @notice One configurable ERC20 standing in for every external token at the C1 boundary.
/// @dev A single fault-injection surface rather than one mock per misbehavior: fee-on-transfer,
///      a `false` return, an outright revert, and a re-entrant callback are switches on the same
///      token, so each test still asserts its own distinct property.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice Basis points of every transfer burned in flight, simulating fee-on-transfer.
    uint256 public feeBps;
    /// @notice When set, `transfer` and `transferFrom` move nothing and return `false`.
    bool public returnsFalse;
    /// @notice When set, `transfer` and `transferFrom` revert.
    bool public reverts;

    /// @notice Optional call this token makes back into the system while a transfer is in flight.
    address public reentryTarget;
    bytes public reentryCalldata;
    /// @notice Whether the last attempted re-entrant call succeeded.
    bool public lastReentrySucceeded;
    uint256 public reentryAttempts;

    bool private _reentering;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function setFeeBps(uint256 feeBps_) external {
        feeBps = feeBps_;
    }

    function setReturnsFalse(bool value) external {
        returnsFalse = value;
    }

    function setReverts(bool value) external {
        reverts = value;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryCalldata = data;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) private returns (bool) {
        if (reverts) revert("MockERC20: transfer reverted");
        if (returnsFalse) return false;

        balanceOf[from] -= amount;
        uint256 fee = (amount * feeBps) / 10_000;
        uint256 delivered = amount - fee;
        balanceOf[to] += delivered;
        if (fee != 0) totalSupply -= fee;
        emit Transfer(from, to, delivered);

        _attemptReentry();
        return true;
    }

    function _attemptReentry() private {
        address target = reentryTarget;
        if (target == address(0) || _reentering) return;

        _reentering = true;
        reentryAttempts += 1;
        (bool ok,) = target.call(reentryCalldata);
        lastReentrySucceeded = ok;
        _reentering = false;
    }
}
