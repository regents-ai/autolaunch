// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @notice The allowance-transfer slice of Permit2 that the pinned CCA bid path actually calls.
/// @dev The real Permit2 pins `=0.8.17` and cannot be built under this repository's frozen `0.8.26`
///      compiler, and `SPEC.md` section 10 assigns real Permit2 runtime behaviour to the separately
///      authorized fork gate. This double exists only so hermetic tests can drive real bids through
///      the real `ContinuousClearingAuction`; it closes no Permit2 claim of its own.
contract Permit2Double {
    mapping(address owner => mapping(address token => mapping(address spender => uint160))) public allowanceOf;

    error InsufficientPermit2Allowance(uint160 allowed, uint160 requested);

    function approve(address token, address spender, uint160 amount, uint48) external {
        allowanceOf[msg.sender][token][spender] = amount;
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        uint160 allowed = allowanceOf[from][token][msg.sender];
        if (allowed < amount) revert InsufficientPermit2Allowance(allowed, amount);
        if (allowed != type(uint160).max) allowanceOf[from][token][msg.sender] = allowed - amount;

        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory returned) =
            token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, uint256(amount)));
        require(ok && (returned.length == 0 || abi.decode(returned, (bool))), "Permit2Double: transferFrom failed");
    }
}
