// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {HookFixture} from "../mocks/HookFixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice The smallest production-realistic proof of the FA-07 operating path.
contract FA07OperatingPathTest is HookFixture {
    function setUp() public {
        _deployHookSystem();
    }

    function test_HOK_007_FA07_I7_OfficialPathChargesRealizedSubjectOutputInKind() public {
        Pool memory pool = _openPool(SUBJECT_LOW, DEFAULT_LIQUIDITY);
        _assertExactInputOutputFee(pool, _regentIsInput(pool), pool.subject, regent, 1e18);
    }

    function test_HOK_007_FA07_I7_OfficialPathChargesRealizedRegentOutputInKind() public {
        Pool memory pool = _openPool(SUBJECT_HIGH, DEFAULT_LIQUIDITY);
        _assertExactInputOutputFee(pool, !_regentIsInput(pool), regent, pool.subject, 1e18);
    }

    function _assertExactInputOutputFee(
        Pool memory pool,
        bool zeroForOne,
        MockERC20 feeToken,
        MockERC20 specifiedToken,
        uint256 amountSpecified
    ) private {
        uint256 safeBefore = feeToken.balanceOf(REGENT_SAFE);
        uint256 stakingBefore = feeToken.balanceOf(LIVE_STAKING);
        uint256 treasuryBefore = feeToken.balanceOf(treasury);
        uint256 hookBefore = feeToken.balanceOf(address(hook));
        uint256 allowanceBefore = feeToken.allowance(address(hook), address(pool.splitter));
        uint256 specifiedBefore = specifiedToken.balanceOf(address(this));

        vm.recordLogs();
        BalanceDelta delta = _swap(pool, zeroForOne, -int256(amountSpecified));
        Settlement memory settled = _onlySettlement();

        assertEq(settled.feeToken, address(feeToken), "FA07-I1 fee token is realized unspecified output");
        assertEq(settled.regentLane, settled.charged / 100, "FA07-I2 floored 1% Regent lane");
        assertEq(settled.stakerLane, settled.charged * 200 / 10_000 - settled.regentLane, "FA07-I2 staker lane");
        assertGt(settled.regentLane, 0, "FA07-I2 operating path must charge both lanes");
        assertTrue(settled.exactInput, "FA07-I1 event shape");

        int128 specifiedDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 netUnspecifiedDelta = zeroForOne ? delta.amount1() : delta.amount0();
        assertEq(specifiedDelta, -int128(int256(amountSpecified)), "FA07-I1 specified input changed");
        assertEq(
            netUnspecifiedDelta + int128(int256(_fee(settled))),
            int128(int256(settled.charged)),
            "FA07-I1 fee base is actual gross unspecified output"
        );
        assertEq(
            specifiedToken.balanceOf(address(this)),
            specifiedBefore - amountSpecified,
            "FA07-I1 wallet specified input changed"
        );

        (uint256 toSafe, uint256 toStaking, uint256 toTreasury) = _expectedRoutes(pool.splitter, settled);
        assertEq(feeToken.balanceOf(REGENT_SAFE), safeBefore + toSafe, "FA07-I2 Safe lane");
        assertEq(feeToken.balanceOf(LIVE_STAKING), stakingBefore + toStaking, "FA07-I2 staking lane");
        assertEq(feeToken.balanceOf(treasury), treasuryBefore + toTreasury, "FA07-I2 splitter lane");
        assertEq(feeToken.balanceOf(address(hook)), hookBefore, "FA07-I4 hook balance restored");
        assertEq(
            feeToken.allowance(address(hook), address(pool.splitter)),
            allowanceBefore,
            "FA07-I4 hook allowance restored"
        );
    }
}
