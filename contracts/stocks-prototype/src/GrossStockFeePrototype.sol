// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseTestHooks} from "@uniswap/v4-core/src/test/BaseTestHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @dev PROPOSED fee base, NOT an admitted production hook:
/// STOCK input: actual trader debit, including the STOCK allocation.
/// STOCK output: actual pool output, before the STOCK allocation.
/// Each enabled lane floors 1% of that gross amount. This deliberately differs
/// from charging 1% of the core pool's input delta; the decision is not frozen.
contract GrossStockFeePrototype is BaseTestHooks {
    IPoolManager public immutable manager;
    address public immutable stock;
    address public immutable administrator;
    address public subject;
    mapping(address => uint256) public subjectAccrued;
    uint256 public regentAccrued;
    uint256 public lastBase;
    uint256 public lastFee;
    bool private inSwap;
    bool private specifiedStock;
    bool private inputStock;
    uint256 private expectedFee;
    bytes32 private expectedPool;

    error BadCallback();
    error UnsupportedPool();
    error BadQuote();
    error QuoteResult(int128 stockDelta);
    error FeeMismatch();

    constructor(IPoolManager manager_, address stock_, address administrator_) {
        manager = manager_;
        stock = stock_;
        administrator = administrator_;
    }

    // Prototype configuration only. Production two-step administration and
    // allowlist admission must precede adoption; no old bucket is redirected.
    function setSubject(address destination) external {
        require(msg.sender == administrator && !inSwap);
        subject = destination;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external override returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(manager) || inSwap) revert BadCallback();
        if (address(key.hooks) != address(this) || key.fee != 3000 || key.tickSpacing != 60 ||
            (Currency.unwrap(key.currency0) != stock && Currency.unwrap(key.currency1) != stock)) revert UnsupportedPool();
        inSwap = true;
        expectedPool = keccak256(abi.encode(key));
        inputStock = params.zeroForOne == (Currency.unwrap(key.currency0) == stock);
        specifiedStock = inputStock == (params.amountSpecified < 0);
        expectedFee = 0;
        if (specifiedStock) {
            uint256 lanes = subject == address(0) ? 1 : 2;
            SwapParams memory probe = params;
            uint256 requested;
            if (inputStock) {
                // Bound this experiment to native signed-delta-sized orders.
                require(params.amountSpecified >= -int256(type(int128).max));
                requested = uint256(-params.amountSpecified);
                uint256 fullFee = lanes * (requested / 100);
                probe.amountSpecified = -int256(requested - fullFee);
                uint256 realized = magnitude(quote(key, probe));
                expectedFee = realized == requested - fullFee ? fullFee : lanes * inputLane(realized, lanes);
            } else {
                require(params.amountSpecified <= int256(type(int128).max));
                requested = uint256(params.amountSpecified);
                probe.amountSpecified = int256(requested + lanes * inputLane(requested, lanes));
                uint256 realized = magnitude(quote(key, probe));
                expectedFee = lanes * (realized / 100);
            }
        }
        require(expectedFee <= uint256(uint128(type(int128).max)));
        return (this.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(expectedFee)), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        external override returns (bytes4, int128)
    {
        if (msg.sender != address(manager) || !inSwap || keccak256(abi.encode(key)) != expectedPool) revert BadCallback();
        uint256 realized = magnitude(Currency.unwrap(key.currency0) == stock ? delta.amount0() : delta.amount1());
        uint256 lanes = subject == address(0) ? 1 : 2;
        uint256 perLane;
        if (inputStock) {
            perLane = specifiedStock ? (realized + expectedFee) / 100 : inputLane(realized, lanes);
            lastBase = realized + lanes * perLane;
        } else {
            perLane = realized / 100;
            lastBase = realized;
        }
        uint256 fee = lanes * perLane;
        if (specifiedStock && fee != expectedFee) revert FeeMismatch();
        if (lastBase / 100 != perLane) revert FeeMismatch();
        lastFee = fee;
        regentAccrued += perLane;
        if (subject != address(0)) subjectAccrued[subject] += perLane;
        if (fee > 0) manager.take(Currency.wrap(stock), address(this), fee);
        inSwap = false;
        require(fee <= uint256(uint128(type(int128).max)));
        return (this.afterSwap.selector, specifiedStock ? int128(0) : int128(uint128(fee)));
    }

    // Quoting runs the actual native pool from a SELF call, so v4's no-self-call
    // hook guard avoids recursion. The deliberate revert rolls back pool state,
    // transient accounting, fee growth and emitted events before the real swap.
    function simulate(PoolKey calldata key, SwapParams calldata params) external {
        if (msg.sender != address(this) || !inSwap) revert BadCallback();
        BalanceDelta delta = manager.swap(key, params, "");
        revert QuoteResult(Currency.unwrap(key.currency0) == stock ? delta.amount0() : delta.amount1());
    }

    function quote(PoolKey calldata key, SwapParams memory params) private returns (int128 result) {
        try this.simulate(key, params) { revert BadQuote(); }
        catch (bytes memory reason) {
            if (reason.length != 36 || bytes4(reason) != QuoteResult.selector) revert BadQuote();
            assembly ("memory-safe") { result := mload(add(reason, 36)) }
        }
    }

    // Smallest nonnegative q with q == floor((net + lanes*q)/100).
    function inputLane(uint256 net, uint256 lanes) private pure returns (uint256) {
        return net < 100 ? 0 : (net - 100) / (100 - lanes) + 1;
    }

    function magnitude(int128 value) private pure returns (uint256) {
        return uint256(value < 0 ? -int256(value) : int256(value));
    }
}
