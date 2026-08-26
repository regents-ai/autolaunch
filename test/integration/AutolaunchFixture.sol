// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV1} from "../../src/escrow/ConditionalVestingEscrowV1.sol";
import {RegentsAutolaunchFactoryV1} from "../../src/factory/RegentsAutolaunchFactoryV1.sol";
import {RegentFeeHook} from "../../src/hook/RegentFeeHook.sol";
import {PaymentReceiverV1} from "../../src/revenue/PaymentReceiverV1.sol";
import {SubjectSplitterV1} from "../../src/revenue/SubjectSplitterV1.sol";
import {RegentLBPStrategy} from "../../src/strategy/RegentLBPStrategy.sol";
import {ContinuousClearingAuction} from "continuous-clearing-auction/ContinuousClearingAuction.sol";
import {ContinuousClearingAuctionFactory} from "continuous-clearing-auction/ContinuousClearingAuctionFactory.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {UERC20Factory} from "uerc20-factory/factories/UERC20Factory.sol";
import {UERC20} from "uerc20-factory/tokens/UERC20.sol";
import {LaunchCloneSlots} from "../mocks/LaunchCloneSlots.sol";
import {MockLiveStaking} from "../mocks/MockLiveStaking.sol";
import {Permit2Double} from "../strategy/doubles/Permit2Double.sol";
import {StagedERC20} from "../strategy/doubles/StagedERC20.sol";

/// @notice The C4 harness: the whole Autolaunch graph reached only through its real production
///         callers, with nothing about the factory, the strategy, the hook, the C1 clones, the
///         auction or the SUBJECT token stubbed.
/// @dev C3's fixture cannot be reused because it constructs a `LaunchFactoryDouble` and etches the
///      hook at a hand-picked address. C4's entire subject is the real factory, so this fixture
///      instead does exactly what C5's deployment packet will do:
///
///      1. Every frozen Base binding is *constructed at its own address* — the creation code is
///         etched there and called, so each constructor runs with `address(this)` equal to the frozen
///         address. Nothing is stubbed or re-implemented.
///      2. The pinned `UERC20Factory` (`09ae130f…`) is deployed from its own source under this
///         repository's frozen build, so the runtime hash the production constructor demands is the
///         hash of the code actually running here.
///      3. The hook salt is mined the one admitted way: predict the factory address, derive the
///         strategy as that factory's first `CREATE`, hash the hook's creation code against the
///         frozen PoolManager and that predicted strategy, and search with the pinned `HookMiner`
///         using the predicted factory as the CREATE2 deployer. The factory then deploys both
///         contracts itself and binds them from inside its own constructor.
///      4. Every SUBJECT is a real `UERC20` created by that pinned factory through
///         `RegentsAutolaunchFactoryV1.launch`, and every auction is a real
///         `ContinuousClearingAuction` created by the real CCA factory and driven by real bids.
///
///      Three binding-level doubles remain, each named and each serving hermetic behaviour only:
///      `Permit2Double` (real Permit2 pins `=0.8.17` and cannot be built under the frozen `0.8.26`
///      compiler), `StagedERC20` staged at the frozen REGENT and USDC addresses, and
///      `MockLiveStaking`. None of them satisfies a deployed-runtime claim; `SPEC.md` section 10
///      leaves those to the separately authorized fork gate.
abstract contract AutolaunchFixture is Test {
    using StateLibrary for IPoolManager;

    uint256 internal constant TOTAL_SUPPLY = 100_000_000_000e18;
    uint256 internal constant PENDING_ALLOCATION = 85_000_000_000e18;
    uint256 internal constant AUCTION_ALLOCATION = 10_000_000_000e18;
    uint256 internal constant RESERVE_ALLOCATION = 5_000_000_000e18;
    uint256 internal constant INITIAL_LAUNCH_FEE = 1_000_000e18;

    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev Exactly the five permission bits `RegentFeeHook` declares.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    /// @notice One launch as its production caller sees it.
    struct Launched {
        uint256 launchId;
        UERC20 subject;
        ConditionalVestingEscrowV1 escrow;
        IContinuousClearingAuction auction;
    }

    RegentsAutolaunchFactoryV1 internal factory;
    RegentLBPStrategy internal strategy;
    RegentFeeHook internal hook;
    bytes32 internal hookSalt;

    UERC20Factory internal uerc20Factory;
    ConditionalVestingEscrowV1 internal escrowImplementation;
    SubjectSplitterV1 internal splitterImplementation;
    PaymentReceiverV1 internal receiverImplementation;

    StagedERC20 internal regent;
    StagedERC20 internal usdc;
    PoolManager internal poolManager;
    IPositionManager internal positionManager;
    ContinuousClearingAuctionFactory internal ccaFactory;
    MockLiveStaking internal liveStaking;

    address internal governance = BaseBindings.GOVERNANCE_AND_REGENT_SAFE;
    address internal treasury = makeAddr("treasury");
    address internal launcher = makeAddr("launcher");
    address internal outsider = makeAddr("outsider");
    address internal bidder = makeAddr("bidder");

    // -------------------------------------------------------------------------
    // deployment
    // -------------------------------------------------------------------------

    function _deployAutolaunch() internal {
        vm.roll(1_000_000);

        regent = _etchToken(BaseBindings.REGENT);
        usdc = _etchToken(BaseBindings.USDC);
        _constructAt(PERMIT2, type(Permit2Double).creationCode);
        _constructAt(
            BaseBindings.LIVE_STAKING,
            abi.encodePacked(type(MockLiveStaking).creationCode, abi.encode(BaseBindings.USDC))
        );
        _constructAt(
            BaseBindings.POOL_MANAGER, abi.encodePacked(type(PoolManager).creationCode, abi.encode(address(this)))
        );
        _constructAt(
            BaseBindings.CCA_FACTORY,
            abi.encodePacked(type(ContinuousClearingAuctionFactory).creationCode, abi.encode(address(0)))
        );
        _constructAt(
            BaseBindings.POSITION_MANAGER,
            abi.encodePacked(
                type(PositionManager).creationCode,
                abi.encode(
                    IPoolManager(BaseBindings.POOL_MANAGER),
                    IAllowanceTransfer(PERMIT2),
                    uint256(300_000),
                    IPositionDescriptor(address(0)),
                    IWETH9(payable(address(0)))
                )
            )
        );

        poolManager = PoolManager(BaseBindings.POOL_MANAGER);
        positionManager = IPositionManager(BaseBindings.POSITION_MANAGER);
        ccaFactory = ContinuousClearingAuctionFactory(BaseBindings.CCA_FACTORY);
        liveStaking = MockLiveStaking(BaseBindings.LIVE_STAKING);

        uerc20Factory = new UERC20Factory();
        escrowImplementation = new ConditionalVestingEscrowV1();
        splitterImplementation = new SubjectSplitterV1();
        receiverImplementation = new PaymentReceiverV1();

        hookSalt = _mineHookSalt(vm.computeCreateAddress(address(this), vm.getNonce(address(this))));

        factory = new RegentsAutolaunchFactoryV1(
            address(uerc20Factory),
            address(escrowImplementation),
            address(splitterImplementation),
            address(receiverImplementation),
            hookSalt
        );
        strategy = factory.strategy();
        hook = factory.hook();
    }

    /// @notice The one admitted hook-salt derivation, exactly as C5's deployment packet will run it.
    /// @dev The strategy is the factory's first `CREATE`, and a contract's nonce starts at one, so
    ///      the predicted strategy is `CREATE(predictedFactory, 1)`. The hook is then a CREATE2 from
    ///      the factory over `RegentFeeHook.creationCode ++ abi.encode(PoolManager, strategy)`.
    function _mineHookSalt(address predictedFactory) internal view returns (bytes32 salt) {
        address predictedStrategy = vm.computeCreateAddress(predictedFactory, 1);
        (, salt) = HookMiner.find(
            predictedFactory,
            HOOK_FLAGS,
            type(RegentFeeHook).creationCode,
            abi.encode(BaseBindings.POOL_MANAGER, predictedStrategy)
        );
    }

    /// @dev Run a real constructor at an exact address, so its storage writes and immutables land
    ///      where production expects them. Reverts loudly rather than leaving a half-built binding.
    function _constructAt(address where, bytes memory initcode) internal {
        vm.etch(where, initcode);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory runtime) = where.call("");
        require(ok && runtime.length != 0, "AutolaunchFixture: construction at address failed");
        vm.etch(where, runtime);
    }

    function _etchToken(address where) internal returns (StagedERC20 token) {
        StagedERC20 template = new StagedERC20();
        vm.etch(where, address(template).code);
        token = StagedERC20(where);
    }

    // -------------------------------------------------------------------------
    // launches
    // -------------------------------------------------------------------------

    /// @notice The default launch parameters: a valid launch of every field's smallest useful shape.
    function _params() internal view returns (RegentsAutolaunchFactoryV1.LaunchParams memory params) {
        params = RegentsAutolaunchFactoryV1.LaunchParams({
            name: "Subject One",
            symbol: "SUBJ",
            description: "A launch",
            website: "https://regents.sh",
            image: "ipfs://image",
            treasury: treasury,
            requiredRegentRaised: 1_000e18,
            expectedLaunchFee: INITIAL_LAUNCH_FEE
        });
    }

    /// @notice Approve exactly the fee and launch as `who`, the way a connected wallet does.
    function _launchAs(address who, RegentsAutolaunchFactoryV1.LaunchParams memory params)
        internal
        returns (Launched memory launched)
    {
        _fundFee(who, params.expectedLaunchFee);

        vm.prank(who);
        (uint256 launchId, address subject, address auction, address escrow) = factory.launch(params);

        launched = Launched({
            launchId: launchId,
            subject: UERC20(subject),
            escrow: ConditionalVestingEscrowV1(escrow),
            auction: IContinuousClearingAuction(auction)
        });
    }

    /// @notice The default launch, whose SUBJECT sorts below REGENT so REGENT is the pool's currency1.
    function _defaultLaunch() internal returns (Launched memory launched) {
        launched = _launchSorted(true, _params());
    }

    /// @notice Launch with a name chosen so the created SUBJECT sorts on the requested side of REGENT.
    /// @dev The pinned UERC20 factory derives its CREATE2 salt from name, symbol, decimals, creator
    ///      and graffiti, so the launcher cannot choose an address — but a test can still reach both
    ///      PoolKey orderings by searching the one field it is free to vary.
    function _launchSorted(bool subjectBelowRegent, RegentsAutolaunchFactoryV1.LaunchParams memory params)
        internal
        returns (Launched memory launched)
    {
        params.name = _nameSorting(subjectBelowRegent, params.symbol, factory.nextLaunchId());
        launched = _launchAs(launcher, params);
        assertEq(
            address(launched.subject) < BaseBindings.REGENT, subjectBelowRegent, "SUBJECT did not sort as requested"
        );
    }

    function _nameSorting(bool below, string memory symbol, uint256 launchId) internal view returns (string memory) {
        for (uint256 i; i < 1024; ++i) {
            string memory candidate = string.concat("Subject ", vm.toString(i));
            address predicted =
                uerc20Factory.getUERC20Address(candidate, symbol, 18, address(factory), bytes32(launchId));
            if ((predicted < BaseBindings.REGENT) == below) return candidate;
        }
        revert("AutolaunchFixture: no name sorts on the requested side of REGENT");
    }

    function _fundFee(address who, uint256 fee) internal {
        if (fee == 0) return;
        regent.mint(who, fee);
        vm.prank(who);
        regent.approve(address(factory), fee);
    }

    // -------------------------------------------------------------------------
    // auction driving
    // -------------------------------------------------------------------------

    function _bidPrice(uint256 ticksAboveFloor) internal view returns (uint256) {
        return strategy.FLOOR_PRICE_Q96() + ticksAboveFloor * strategy.BID_TICK_Q96();
    }

    function _bid(Launched memory launched, address account, uint128 amount, uint256 priceQ96)
        internal
        returns (uint256 bidId)
    {
        regent.mint(account, amount);
        vm.startPrank(account);
        regent.approve(PERMIT2, type(uint256).max);
        Permit2Double(PERMIT2).approve(address(regent), address(launched.auction), uint160(amount), type(uint48).max);
        bidId = launched.auction.submitBid(priceQ96, amount, account, strategy.FLOOR_PRICE_Q96(), "");
        vm.stopPrank();
    }

    function _rollToStart(Launched memory launched) internal {
        vm.roll(launched.auction.startBlock());
    }

    function _rollToMigration(Launched memory launched) internal {
        vm.roll(uint256(launched.auction.endBlock()) + strategy.MIGRATION_DELAY_BLOCKS());
    }

    /// @dev One economically successful launch: a single bid comfortably above the required raise.
    function _bidToGraduation(Launched memory launched, uint128 amount) internal {
        _bidToGraduationAt(launched, amount, 10);
    }

    function _bidToGraduationAt(Launched memory launched, uint128 amount, uint256 ticksAboveFloor) internal {
        _rollToStart(launched);
        _bid(launched, bidder, amount, _bidPrice(ticksAboveFloor));
        _rollToMigration(launched);
    }

    function _poolId(Launched memory launched) internal view returns (PoolId) {
        return strategy.poolKeyOf(address(launched.subject)).toId();
    }

    function _distribution(Launched memory launched) internal view returns (RegentLBPStrategy.Distribution memory) {
        return strategy.distribution(address(launched.auction));
    }

    // -------------------------------------------------------------------------
    // deterministic clone slots
    // -------------------------------------------------------------------------

    /// @notice The address a launch's splitter clone will occupy, derived independently of production.
    function _splitterSlot(uint256 launchId, address subject) internal view returns (address) {
        return LaunchCloneSlots.splitter(address(strategy), address(splitterImplementation), launchId, subject);
    }

    /// @notice The address a launch's canonical receiver clone will occupy, derived the same way.
    function _receiverSlot(uint256 launchId, address subject) internal view returns (address) {
        return LaunchCloneSlots.canonicalReceiver(address(strategy), address(receiverImplementation), launchId, subject);
    }

    /// @notice The two slots a launch will use, computed before that launch exists.
    /// @dev Both inputs are knowable in advance: the factory assigns launch ids in order from its own
    ///      counter, and the pinned UERC20 factory derives every SUBJECT with CREATE2 from exactly
    ///      the arguments `RegentsAutolaunchFactoryV1.launch` will pass. So a launch's whole
    ///      identity — and therefore both of its clone slots — is fixed before its transaction runs.
    function _plannedSlots(uint256 launchId, RegentsAutolaunchFactoryV1.LaunchParams memory params)
        internal
        view
        returns (address splitterSlot, address receiverSlot)
    {
        address subject =
            uerc20Factory.getUERC20Address(params.name, params.symbol, 18, address(factory), bytes32(launchId));
        splitterSlot = _splitterSlot(launchId, subject);
        receiverSlot = _receiverSlot(launchId, subject);
    }

    /// @notice The same two slots for a launch that `_launchSorted` will create, which picks the
    ///         SUBJECT name deterministically from the launch id and the requested sort side.
    function _plannedSortedSlots(uint256 launchId, bool subjectBelowRegent)
        internal
        view
        returns (address splitterSlot, address receiverSlot)
    {
        RegentsAutolaunchFactoryV1.LaunchParams memory params = _params();
        params.name = _nameSorting(subjectBelowRegent, params.symbol, launchId);
        return _plannedSlots(launchId, params);
    }

    // -------------------------------------------------------------------------
    // observation
    // -------------------------------------------------------------------------

    /// @notice Every fact a rolled-back launch or migration must leave exactly where it was.
    struct Ledger {
        uint256 nextLaunchId;
        uint64 factoryNonce;
        uint64 strategyNonce;
        uint256 launcherRegent;
        uint256 regentSafeRegent;
        uint256 launcherAllowance;
        uint8 lifecycle;
        address recordedSplitter;
        address recordedReceiver;
        uint256 recordedLpTokenId;
        uint160 recordedFinalSqrtPrice;
        uint256 strategyRegent;
        uint256 strategySubject;
        uint256 treasuryRegent;
        uint256 escrowSubject;
        uint256 auctionRegent;
        uint256 auctionSubject;
        uint256 auctionSweepCurrencyBlock;
        uint256 auctionSweepUnsoldTokensBlock;
        uint256 deadSubject;
        uint256 nextTokenId;
        uint160 poolSqrtPrice;
        address registeredSplitter;
        uint8 escrowLifecycle;
        bool escrowSweepDone;
        uint64 escrowVestingStart;
    }

    function _ledger(Launched memory launched) internal view returns (Ledger memory snapshot) {
        RegentLBPStrategy.Distribution memory d = strategy.distribution(address(launched.auction));
        snapshot.nextLaunchId = factory.nextLaunchId();
        snapshot.factoryNonce = vm.getNonce(address(factory));
        snapshot.strategyNonce = vm.getNonce(address(strategy));
        snapshot.launcherRegent = regent.balanceOf(launcher);
        snapshot.regentSafeRegent = regent.balanceOf(BaseBindings.GOVERNANCE_AND_REGENT_SAFE);
        snapshot.launcherAllowance = regent.allowance(launcher, address(factory));
        snapshot.lifecycle = uint8(d.lifecycle);
        snapshot.recordedSplitter = d.splitter;
        snapshot.recordedReceiver = d.receiver;
        snapshot.recordedLpTokenId = d.lpTokenId;
        snapshot.recordedFinalSqrtPrice = d.finalSqrtPriceX96;
        snapshot.strategyRegent = regent.balanceOf(address(strategy));
        snapshot.strategySubject = launched.subject.balanceOf(address(strategy));
        snapshot.treasuryRegent = regent.balanceOf(treasury);
        snapshot.escrowSubject = launched.subject.balanceOf(address(launched.escrow));
        snapshot.auctionRegent = regent.balanceOf(address(launched.auction));
        snapshot.auctionSubject = launched.subject.balanceOf(address(launched.auction));
        ContinuousClearingAuction auction = ContinuousClearingAuction(address(launched.auction));
        snapshot.auctionSweepCurrencyBlock = auction.sweepCurrencyBlock();
        snapshot.auctionSweepUnsoldTokensBlock = auction.sweepUnsoldTokensBlock();
        snapshot.deadSubject = launched.subject.balanceOf(BaseBindings.DEAD_ADDRESS);
        snapshot.nextTokenId = positionManager.nextTokenId();
        (snapshot.poolSqrtPrice,,,) = IPoolManager(BaseBindings.POOL_MANAGER).getSlot0(_poolId(launched));
        snapshot.registeredSplitter = hook.splitterOf(_poolId(launched));
        snapshot.escrowLifecycle = uint8(launched.escrow.lifecycle());
        snapshot.escrowSweepDone = launched.escrow.graduatedSweepDone();
        snapshot.escrowVestingStart = launched.escrow.vestingStart();
    }

    /// @dev Whether a deployed runtime carries a selector as a literal, which is how a Solidity
    ///      dispatcher stores every live entry point. Used to prove hard-deleted or never-existing
    ///      surfaces by diff rather than by calling functions that must not exist.
    function _carriesSelector(bytes memory runtime, bytes4 selector) internal pure returns (bool) {
        for (uint256 i; i + 4 <= runtime.length; ++i) {
            if (
                runtime[i] == selector[0] && runtime[i + 1] == selector[1] && runtime[i + 2] == selector[2]
                    && runtime[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }

    function _assertLedgerUnchanged(Ledger memory before, Ledger memory found, string memory stage) internal pure {
        assertEq(found.nextLaunchId, before.nextLaunchId, string.concat(stage, ": nextLaunchId moved"));
        assertEq(found.factoryNonce, before.factoryNonce, string.concat(stage, ": a factory clone survived"));
        assertEq(found.strategyNonce, before.strategyNonce, string.concat(stage, ": a strategy clone survived"));
        assertEq(found.launcherRegent, before.launcherRegent, string.concat(stage, ": launcher REGENT moved"));
        assertEq(found.regentSafeRegent, before.regentSafeRegent, string.concat(stage, ": Regent Safe REGENT moved"));
        assertEq(found.launcherAllowance, before.launcherAllowance, string.concat(stage, ": fee allowance moved"));
        assertEq(found.lifecycle, before.lifecycle, string.concat(stage, ": lifecycle moved"));
        assertEq(found.recordedSplitter, before.recordedSplitter, string.concat(stage, ": a splitter was recorded"));
        assertEq(found.recordedReceiver, before.recordedReceiver, string.concat(stage, ": a receiver was recorded"));
        assertEq(found.recordedLpTokenId, before.recordedLpTokenId, string.concat(stage, ": an LP token was recorded"));
        assertEq(
            found.recordedFinalSqrtPrice,
            before.recordedFinalSqrtPrice,
            string.concat(stage, ": a final price was recorded")
        );
        assertEq(found.strategyRegent, before.strategyRegent, string.concat(stage, ": strategy REGENT moved"));
        assertEq(found.strategySubject, before.strategySubject, string.concat(stage, ": strategy SUBJECT moved"));
        assertEq(found.treasuryRegent, before.treasuryRegent, string.concat(stage, ": treasury REGENT moved"));
        assertEq(found.escrowSubject, before.escrowSubject, string.concat(stage, ": escrow SUBJECT moved"));
        assertEq(found.auctionRegent, before.auctionRegent, string.concat(stage, ": auction REGENT moved"));
        assertEq(found.auctionSubject, before.auctionSubject, string.concat(stage, ": auction SUBJECT moved"));
        assertEq(
            found.auctionSweepCurrencyBlock,
            before.auctionSweepCurrencyBlock,
            string.concat(stage, ": the auction's currency sweep ran")
        );
        assertEq(
            found.auctionSweepUnsoldTokensBlock,
            before.auctionSweepUnsoldTokensBlock,
            string.concat(stage, ": the auction's token sweep ran")
        );
        assertEq(found.deadSubject, before.deadSubject, string.concat(stage, ": dead-address SUBJECT moved"));
        assertEq(found.nextTokenId, before.nextTokenId, string.concat(stage, ": an LP NFT was minted"));
        assertEq(found.poolSqrtPrice, before.poolSqrtPrice, string.concat(stage, ": the pool was initialized"));
        assertEq(found.registeredSplitter, before.registeredSplitter, string.concat(stage, ": the pool was registered"));
        assertEq(found.escrowLifecycle, before.escrowLifecycle, string.concat(stage, ": escrow lifecycle moved"));
        assertEq(found.escrowSweepDone, before.escrowSweepDone, string.concat(stage, ": escrow sweep ran"));
        assertEq(found.escrowVestingStart, before.escrowVestingStart, string.concat(stage, ": vesting started"));
    }
}
