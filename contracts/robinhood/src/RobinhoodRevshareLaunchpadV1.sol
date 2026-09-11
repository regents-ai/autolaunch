// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Position} from "liquidity-launcher/src/types/PositionPlannerTypes.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IRobinhoodRevshareLaunchpadV1} from "./interfaces/IRobinhoodRevshareLaunchpadV1.sol";
import {RobinhoodLaunchpadBase} from "./RobinhoodLaunchpadBase.sol";
import {RobinhoodPreset} from "./RobinhoodPreset.sol";
import {RobinhoodSubjectSplitterV1} from "./RobinhoodSubjectSplitterV1.sol";

/// @title RobinhoodRevshareLaunchpadV1
/// @notice The frozen Base Revshare allocation on the Robinhood chain with USDG as the dollar: 10% of
///         a 100B NEW sold for USDG, 5% reserved for the official NEW/USDG pool's full range, 85%
///         (plus whatever the auction and the full range did not use) vesting linearly to the launch
///         treasury for a year from graduation. Graduation creates the launch's own revenue splitter
///         and registers it as the pool's subject destination; the splitter is the only revenue
///         surface, and this launchpad's registry is the provenance every other component checks.
/// @dev The launcher sets the required raise, never below the Safe's USDG minimum. Failure retires
///      every unit of NEW; nothing vests and no splitter is created.
contract RobinhoodRevshareLaunchpadV1 is RobinhoodLaunchpadBase, IRobinhoodRevshareLaunchpadV1 {
    using SafeTransferLib for address;

    address public immutable override splitterImplementation;

    uint256 public override minimumRaiseUsdg = RobinhoodPreset.MINIMUM_RAISE_USDG_REVSHARE;

    mapping(uint256 launchId => RevshareRecord) private _revshareRecords;
    mapping(address newToken => address splitter) public override splitterOf;

    error RefusedTreasury(address treasury);
    error RequiredRaiseBelowMinimum(uint128 required, uint256 minimum);
    error ZeroMinimumRaise();
    error UnexpectedPositionCount(uint256 found);
    error NothingToRelease(uint256 launchId);
    error SplitterBindingMismatch(address expected, address found);

    constructor(Bindings memory bindings, bytes32 hookSalt) RobinhoodLaunchpadBase(bindings, hookSalt) {
        splitterImplementation = address(new RobinhoodSubjectSplitterV1());
    }

    // -------------------------------------------------------------------------
    // launcher surface
    // -------------------------------------------------------------------------

    /// @inheritdoc IRobinhoodRevshareLaunchpadV1
    // slither-disable-next-line reentrancy-no-eth
    function launch(LaunchParams calldata params)
        external
        override
        nonReentrant
        returns (uint256 launchId, address newToken, address auction)
    {
        _requireAdmissibleTreasury(params.treasury);
        if (params.requiredUsdgRaised < minimumRaiseUsdg) {
            revert RequiredRaiseBelowMinimum(params.requiredUsdgRaised, minimumRaiseUsdg);
        }

        (launchId, newToken, auction) = _create(params.core, usdg, params.requiredUsdgRaised);
        _revshareRecords[launchId].treasury = params.treasury;

        emit RevshareLaunchCreated(
            launchId,
            msg.sender,
            newToken,
            params.treasury,
            auction,
            params.core.startBlock,
            _launches[launchId].endBlock,
            params.core.floorPriceQ96,
            params.requiredUsdgRaised,
            RobinhoodPreset.REVSHARE_AUCTION_INVENTORY,
            RobinhoodPreset.REVSHARE_MIGRATION_RESERVE
        );
    }

    /// @inheritdoc IRobinhoodRevshareLaunchpadV1
    function release(uint256 launchId) external override nonReentrant returns (uint256 amount) {
        _requireLaunch(launchId);
        amount = releasable(launchId);
        if (amount == 0) revert NothingToRelease(launchId);

        RevshareRecord storage revshare = _revshareRecords[launchId];
        uint256 totalReleased = revshare.vestingReleased + amount;
        revshare.vestingReleased = totalReleased;
        emit VestingReleased(launchId, revshare.treasury, amount, totalReleased);

        _launches[launchId].newToken.safeTransfer(revshare.treasury, amount);
    }

    // -------------------------------------------------------------------------
    // Safe surface
    // -------------------------------------------------------------------------

    /// @inheritdoc IRobinhoodRevshareLaunchpadV1
    /// @dev Applies to launches created afterwards only; a recorded auction keeps its required raise.
    function setMinimumRaiseUsdg(uint256 newMinimum) external override onlySafe {
        if (newMinimum == 0) revert ZeroMinimumRaise();
        uint256 previousMinimum = minimumRaiseUsdg;
        minimumRaiseUsdg = newMinimum;
        emit MinimumRaiseUsdgUpdated(previousMinimum, newMinimum);
    }

    // -------------------------------------------------------------------------
    // reads
    // -------------------------------------------------------------------------

    /// @inheritdoc IRobinhoodRevshareLaunchpadV1
    function revshareRecords(uint256 launchId) external view override returns (RevshareRecord memory) {
        return _revshareRecords[launchId];
    }

    /// @inheritdoc IRobinhoodRevshareLaunchpadV1
    /// @dev Linear from graduation; the whole allocation once the vesting duration has elapsed.
    function vested(uint256 launchId) public view override returns (uint256) {
        RevshareRecord storage revshare = _revshareRecords[launchId];
        if (revshare.vestingStart == 0) return 0;
        // The schedule is wall-clock by design; block timestamps only drift it by seconds.
        // slither-disable-next-line timestamp
        uint256 elapsed = block.timestamp - revshare.vestingStart;
        if (elapsed >= RobinhoodPreset.REVSHARE_VESTING_DURATION) return revshare.vestingTotal;
        return revshare.vestingTotal * elapsed / RobinhoodPreset.REVSHARE_VESTING_DURATION;
    }

    /// @inheritdoc IRobinhoodRevshareLaunchpadV1
    function releasable(uint256 launchId) public view override returns (uint256) {
        return vested(launchId) - _revshareRecords[launchId].vestingReleased;
    }

    // -------------------------------------------------------------------------
    // kind-specific internals
    // -------------------------------------------------------------------------

    function _terms() internal pure override returns (Terms memory) {
        return Terms({
            totalSupply: RobinhoodPreset.REVSHARE_TOTAL_SUPPLY,
            auctionInventory: RobinhoodPreset.REVSHARE_AUCTION_INVENTORY,
            migrationReserve: RobinhoodPreset.REVSHARE_MIGRATION_RESERVE
        });
    }

    /// @dev The launch's own splitter, created and bound now so the pool is registered with it from
    ///      its first swap. Its every binding is read back before it is recorded.
    function _subjectDestination(uint256 launchId, Launch storage record) internal override returns (address) {
        address newToken = record.newToken;
        address treasury = _revshareRecords[launchId].treasury;

        address splitter = LibClone.clone(splitterImplementation);
        RobinhoodSubjectSplitterV1(splitter).initialize(usdg, newToken, inbox, treasury);
        _requireSplitterBinding(usdg, RobinhoodSubjectSplitterV1(splitter).usdg());
        _requireSplitterBinding(newToken, RobinhoodSubjectSplitterV1(splitter).subject());
        _requireSplitterBinding(inbox, RobinhoodSubjectSplitterV1(splitter).inbox());
        _requireSplitterBinding(treasury, RobinhoodSubjectSplitterV1(splitter).treasury());

        _revshareRecords[launchId].splitter = splitter;
        splitterOf[newToken] = splitter;
        return splitter;
    }

    /// @dev Only the full range, from the whole reserve and the USDG it pairs with at the initial price.
    function _lockedPositions(
        PoolKey memory,
        uint160 sqrtPriceX96,
        bool usdgIsCurrency0,
        uint128 usdgBudget,
        uint128 reserve
    ) internal pure override returns (Position[] memory positions) {
        positions = new Position[](1);
        positions[0] = _fullRangePosition(sqrtPriceX96, usdgIsCurrency0, usdgBudget, reserve);
    }

    /// @dev The USDG the full range could not pair goes to the treasury now; every unit of this
    ///      launch's NEW still here, the unsold inventory and the unpaired reserve alike, joins the
    ///      treasury allocation and vests from this moment.
    function _finishGraduation(
        uint256 launchId,
        Launch storage record,
        Position[] memory positions,
        uint256 raised,
        uint256 usdgRemainder
    ) internal override {
        if (positions.length != 1) revert UnexpectedPositionCount(positions.length);
        RevshareRecord storage revshare = _revshareRecords[launchId];
        address newToken = record.newToken;

        uint256 vesting = newToken.balanceOf(address(this)) - _heldForOtherLaunches(launchId);
        revshare.vestingStart = SafeCastLib.toUint64(block.timestamp);
        revshare.vestingTotal = vesting;

        bool usdgIsCurrency0 = usdg < newToken;
        (uint128 fullRangeUsdg, uint128 fullRangeNew) = _currencyAndNew(usdgIsCurrency0, positions[0]);
        emit RevshareLaunchGraduated(
            launchId,
            record.auction,
            record.poolId,
            revshare.splitter,
            record.finalSqrtPriceX96,
            record.lpTokenId,
            fullRangeUsdg,
            fullRangeNew,
            raised,
            usdgRemainder,
            vesting
        );

        if (usdgRemainder != 0) usdg.safeTransfer(revshare.treasury, usdgRemainder);
    }

    /// @dev Every NEW is minted by this launchpad for exactly one launch and never shared, so nothing
    ///      of another launch's NEW can be held here: the whole balance belongs to this launch.
    function _heldForOtherLaunches(uint256) private pure returns (uint256) {
        return 0;
    }

    /// @dev The closed launch-time treasury refusal of the frozen Base strategy, in this system's
    ///      terms: the shared-system destinations a launch's payouts must never land on. Nothing else
    ///      is judged; the consequences of any other admission are the launcher's.
    function _requireAdmissibleTreasury(address treasury) private view {
        if (treasury == address(0)) revert ZeroAddress();
        if (
            treasury == address(this) || treasury == hook || treasury == poolManager || treasury == positionManager
                || treasury == inbox || treasury == splitterImplementation
        ) revert RefusedTreasury(treasury);
    }

    function _requireSplitterBinding(address expected, address found) private pure {
        if (expected != found) revert SplitterBindingMismatch(expected, found);
    }
}
