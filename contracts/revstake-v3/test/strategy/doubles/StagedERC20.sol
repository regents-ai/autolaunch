// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @notice The one configurable C3 token double. It is an ordinary ERC20 until it is armed.
/// @dev Graduation and retirement move REGENT and SUBJECT through a fixed, ordered sequence of
///      external stages. Arming this token at movement `n` therefore selects one exact stage — the
///      auction sweep, either PositionManager funding transfer, either PositionManager settlement,
///      either `TAKE_PAIR` refund, the treasury payout, the escrow payout, or the escrow's own
///      auction sweep — without needing one bespoke mock per stage. Every test that arms it still
///      asserts its own distinct pre-call state and balances explicitly.
contract StagedERC20 {
    /// @notice How an armed movement misbehaves.
    enum Fault {
        None,
        Revert,
        ReturnFalse,
        ShortTransfer,
        Reenter
    }

    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    /// @notice Every `transfer` and `transferFrom` this token has been asked to perform.
    uint256 public movements;

    /// @notice The 1-based movement index that misbehaves. Zero means the token is disarmed.
    uint256 public armedMovement;

    /// @notice The misbehaviour the armed movement performs.
    Fault public armedFault;

    /// @notice The call an armed `Reenter` movement makes while the transfer is in flight.
    address public reentryTarget;
    bytes public reentryCalldata;

    /// @notice Whether the last attempted re-entrant call succeeded, and how many were attempted.
    bool public lastReentrySucceeded;
    uint256 public reentryAttempts;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    error ArmedRevert(uint256 movement);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice Make movement `movement` (1-based) misbehave in the named way.
    function arm(uint256 movement, Fault fault) external {
        armedMovement = movement;
        armedFault = fault;
    }

    /// @notice Reset the movement counter so a test can index stages from a known point.
    function resetMovements() external {
        movements = 0;
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
        uint256 movement = ++movements;
        Fault fault = movement == armedMovement ? armedFault : Fault.None;

        if (fault == Fault.Revert) revert ArmedRevert(movement);
        if (fault == Fault.ReturnFalse) return false;
        if (fault == Fault.Reenter) {
            reentryAttempts += 1;
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok,) = reentryTarget.call(reentryCalldata);
            lastReentrySucceeded = ok;
        }

        uint256 moved = fault == Fault.ShortTransfer ? amount - 1 : amount;

        balanceOf[from] -= amount;
        balanceOf[to] += moved;
        if (moved != amount) totalSupply -= amount - moved;

        emit Transfer(from, to, moved);
        return true;
    }
}
