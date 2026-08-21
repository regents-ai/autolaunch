// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../src/bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV1} from "../src/escrow/ConditionalVestingEscrowV1.sol";
import {RegentsAutolaunchFactoryV1} from "../src/factory/RegentsAutolaunchFactoryV1.sol";
import {RegentFeeHook} from "../src/hook/RegentFeeHook.sol";
import {PaymentReceiverV1} from "../src/revenue/PaymentReceiverV1.sol";
import {SubjectSplitterV1} from "../src/revenue/SubjectSplitterV1.sol";
import {RegentLBPStrategy} from "../src/strategy/RegentLBPStrategy.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {UERC20} from "uerc20-factory/tokens/UERC20.sol";
import {UERC20Factory} from "uerc20-factory/factories/UERC20Factory.sol";
import {ForkAutolaunch} from "./ForkAutolaunch.sol";

/// @notice `DEP-053`: the complete Autolaunch path, built from the exact final production artifacts
///         and driven end to end against the real frozen Base bindings, at both committed headers.
/// @dev The other fork contracts each cut one slice out of this path — bindings, upstream behaviour,
///      terminal outcomes, complete-transaction gas — and they stay separate named proofs. This one
///      is the whole path in one run: deploy, reconcile code identity, launch, bid, fail, refund,
///      retire, graduate, migrate, exit, claim, stake, pay, swap, skim, claim, unstake, and account
///      for every unit at the end.
///
///      Nothing here manufactures authority, code, custody, or an unreachable state. Every staged
///      thing is one of exactly two kinds, and both are itemized in
///      `docs/audit/fork-authority-and-state-inventory.md`:
///
///        - `deal(token, account, amount)` gives an ordinary wallet a balance of REGENT or USDC,
///          because a fork cannot mint either. Everything that balance is then used for — the
///          approval, the launch, the Permit2 allowance, the five-argument bid, the payment, the
///          swap — is a real production call made by that wallet's own account.
///        - `vm.prank(account)` acts as an ordinary EOA that holds no privilege: the launcher, the
///          bidder, the payer, or the swapper. Pranking one is the same as that person sending the
///          transaction. No role is granted, no code is written, and no custody is moved by fiat.
///
///      One test-only *contract* is deployed: `PoolSwapTest`, the pinned v4-core swap router. The
///      hook has no router allowlist by design, so an arbitrary router is a production-reachable
///      caller rather than a substitute for one, and it holds no authority over anything here.
contract ProductionLifecycleForkTest is ForkAutolaunch {
    using StateLibrary for IPoolManager;

    string internal constant SIZES_PATH = "reports/frozen/deployable-sizes.json";

    uint256 internal constant TOTAL_SUPPLY = 100_000_000_000e18;
    uint256 internal constant SKIM_BPS = 200;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev A raise no single admitted bid can meet, so this launch ends economically failed.
    uint128 internal constant UNREACHABLE_RAISE = 50_000_000e18;

    /// @dev A raise one bid clears comfortably, so this launch graduates.
    uint128 internal constant REACHABLE_RAISE = 1_000e18;

    uint128 internal constant BID_AMOUNT = 4_000e18;

    /// @dev One whole REGENT in, which is large enough that both 1% lanes floor above zero and the
    ///      splitter's own 2% skim of its lane does too.
    int256 internal constant SWAP_AMOUNT_SPECIFIED = -1e18;

    address internal payer = makeAddr("fork-payer");
    address internal swapper = makeAddr("fork-swapper");

    PoolSwapTest internal swapRouter;

    function setUp() public {
        _loadObservations();
    }

    function test_DEP_053_ForkPinnedCompleteProductionLifecycleExecutesEndToEnd() public {
        _runCompleteLifecycle(Header.Pinned);
    }

    function test_DEP_053_ForkLatestCompleteProductionLifecycleExecutesEndToEnd() public {
        _runCompleteLifecycle(Header.Later);
    }

    // -------------------------------------------------------------------------

    function _runCompleteLifecycle(Header header) private {
        _selectFork(header);
        _deployOnFork();
        swapRouter = new PoolSwapTest(IPoolManager(BaseBindings.POOL_MANAGER));

        // Called through `this` on purpose. Every other stage below is `private` and inlines into
        // this driver under the frozen via-IR build; with the code-identity stage inlined too the
        // combined body is one stack slot too deep to compile. An external self-call is a real call
        // boundary the inliner cannot cross, and the stage is `view`, so nothing about the run
        // changes: no prank, no state write, no value.
        this.assertDeployedCodeIsTheFrozenBuild();

        (ForkLaunch memory failing, ForkLaunch memory graduating) = _launchBoth();
        (uint256 failedBidId, uint256 graduatedBidId) = _bidBoth(failing, graduating);

        _assertFailurePathConserves(failing, failedBidId);
        RegentLBPStrategy.Distribution memory d = _assertGraduationPath(graduating);

        uint256 claimed = _exitAndClaim(graduating, graduatedBidId);
        assertGt(claimed, 0, "the graduated bidder claimed no SUBJECT");

        SubjectSplitterV1 splitter = SubjectSplitterV1(d.splitter);
        uint256 staked = claimed / 2;
        _stakeSubject(graduating, splitter, staked);

        _payCanonicalReceiver(graduating, d, splitter);
        _swapBothHookLanes(graduating, d, splitter);
        _claimAllAndUnstake(graduating, splitter, staked);

        _assertNoUnexplainedProductionBalances(graduating, d);

        _emitVerdict("DEP-053", header, "complete-production-lifecycle-executed-and-conserved");
    }

    // -------------------------------------------------------------------------
    // stage 1 — the deployed graph really is the frozen build
    // -------------------------------------------------------------------------

    /// @dev Creation identity for every artifact this suite deploys, and runtime identity for every
    ///      one that can carry a stable deployed hash.
    ///
    ///      A contract with no immutable references has an artifact runtime that *is* its deployed
    ///      runtime, so its `EXTCODEHASH` equals the frozen keccak; the frozen record's own
    ///      `runtime_keccak256_is_deployed_codehash` flag is asserted true for exactly those. A
    ///      contract that does carry immutables cannot present that hash, and pretending otherwise
    ///      would be false, so those are fixed by exact runtime length plus creation-code identity,
    ///      which is what actually determines the code that ran.
    function assertDeployedCodeIsTheFrozenBuild() external view {
        string memory sizes = vm.readFile(SIZES_PATH);

        // Index order is the freezer's own frozen production allowlist. Each read asserts the name
        // at that index first, so a reordered record fails here rather than silently reconciling
        // one contract's bytes against another's row.
        _assertCreationIdentity(sizes, 0, "RegentsAutolaunchFactoryV1", type(RegentsAutolaunchFactoryV1).creationCode);
        _assertCreationIdentity(sizes, 1, "RegentLBPStrategy", type(RegentLBPStrategy).creationCode);
        _assertCreationIdentity(sizes, 2, "RegentFeeHook", type(RegentFeeHook).creationCode);
        _assertCreationIdentity(sizes, 3, "ConditionalVestingEscrowV1", type(ConditionalVestingEscrowV1).creationCode);
        _assertCreationIdentity(sizes, 4, "SubjectSplitterV1", type(SubjectSplitterV1).creationCode);
        _assertCreationIdentity(sizes, 5, "PaymentReceiverV1", type(PaymentReceiverV1).creationCode);

        _assertRuntimeLength(sizes, 0, address(factory));
        _assertRuntimeLength(sizes, 1, address(strategy));
        _assertRuntimeLength(sizes, 2, address(hook));
        _assertDeployedRuntimeCodeHash(sizes, 3, address(escrowImplementation));
        _assertDeployedRuntimeCodeHash(sizes, 4, address(splitterImplementation));
        _assertDeployedRuntimeCodeHash(sizes, 5, address(receiverImplementation));

        // The pinned UERC20 factory the ceremony also deploys, from its own frozen row.
        assertEq(
            vm.parseJsonString(sizes, ".dependency_contracts[0].contract"),
            "UERC20Factory",
            "the frozen dependency record no longer begins with the UERC20 factory"
        );
        assertEq(
            keccak256(type(UERC20Factory).creationCode),
            vm.parseJsonBytes32(sizes, ".dependency_contracts[0].creation_keccak256"),
            "the deployed UERC20 factory creation code is not the frozen build's"
        );
        assertEq(
            address(uerc20Factory).codehash,
            vm.parseJsonBytes32(sizes, ".dependency_contracts[0].runtime_keccak256"),
            "the deployed UERC20 factory runtime is not the frozen build's"
        );

        // The four identities the production constructor actually admits by, read from the deployed
        // accounts rather than restated from the record.
        assertEq(
            address(uerc20Factory).codehash,
            factory.UERC20_FACTORY_RUNTIME_CODE_HASH(),
            "the deployed UERC20 factory is not the admitted runtime"
        );
        assertEq(
            address(escrowImplementation).codehash,
            factory.ESCROW_IMPLEMENTATION_RUNTIME_CODE_HASH(),
            "the deployed escrow implementation is not the admitted runtime"
        );
        assertEq(
            address(splitterImplementation).codehash,
            factory.SPLITTER_IMPLEMENTATION_RUNTIME_CODE_HASH(),
            "the deployed splitter implementation is not the admitted runtime"
        );
        assertEq(
            address(receiverImplementation).codehash,
            factory.RECEIVER_IMPLEMENTATION_RUNTIME_CODE_HASH(),
            "the deployed receiver implementation is not the admitted runtime"
        );

        // The shared graph the factory built and bound from inside its own constructor.
        assertEq(strategy.factory(), address(factory), "the strategy is bound to another factory");
        assertEq(strategy.hook(), address(hook), "the strategy bound another hook");
        assertEq(hook.strategy(), address(strategy), "the hook points at another strategy");
        assertEq(address(hook.poolManager()), BaseBindings.POOL_MANAGER, "the hook carries a foreign PoolManager");
        assertEq(
            strategy.splitterImplementation(),
            address(splitterImplementation),
            "the strategy clones another splitter implementation"
        );
    }

    function _frozenRow(uint256 index, string memory field) private view returns (string memory) {
        return string.concat(".contracts[", vm.toString(index), "].", field);
    }

    function _assertCreationIdentity(string memory sizes, uint256 index, string memory name, bytes memory creationCode)
        private
        view
    {
        assertEq(
            vm.parseJsonString(sizes, _frozenRow(index, "contract")),
            name,
            string.concat("the frozen size record no longer carries ", name, " at its recorded index")
        );
        assertEq(
            keccak256(creationCode),
            vm.parseJsonBytes32(sizes, _frozenRow(index, "creation_keccak256")),
            string.concat(name, ": deployed creation code is not the frozen build's")
        );
    }

    function _assertRuntimeLength(string memory sizes, uint256 index, address deployed) private view {
        assertEq(
            deployed.code.length,
            vm.parseJsonUint(sizes, _frozenRow(index, "runtime_bytes")),
            "a deployed runtime length is not the frozen build's"
        );
    }

    function _assertDeployedRuntimeCodeHash(string memory sizes, uint256 index, address deployed) private view {
        _assertRuntimeLength(sizes, index, deployed);
        assertTrue(
            vm.parseJsonBool(sizes, _frozenRow(index, "runtime_keccak256_is_deployed_codehash")),
            "the frozen record does not claim this artifact keccak is a deployed codehash"
        );
        assertEq(
            deployed.codehash,
            vm.parseJsonBytes32(sizes, _frozenRow(index, "runtime_keccak256")),
            "a deployed runtime code hash is not the frozen build's"
        );
    }

    // -------------------------------------------------------------------------
    // stage 2 — two real launches through a connected wallet
    // -------------------------------------------------------------------------

    /// @dev The exact fee discipline, proved at the destination: the launcher's allowance to the
    ///      factory is fully consumed, and the Regent Safe's own balance rises by exactly the two
    ///      fees. Nothing is inferred from a return value.
    function _launchBoth() private returns (ForkLaunch memory failing, ForkLaunch memory graduating) {
        uint256 fee = factory.launchFee();
        assertEq(fee, INITIAL_LAUNCH_FEE, "the factory was born with another launch fee");

        uint256 safeBefore = _balanceOf(BaseBindings.REGENT, BaseBindings.GOVERNANCE_AND_REGENT_SAFE);
        (failing,,) = _launchAsWallet(_worstCaseParams(UNREACHABLE_RAISE));
        (graduating,,) = _launchAsWallet(_worstCaseParams(REACHABLE_RAISE));

        assertEq(
            _balanceOf(BaseBindings.REGENT, BaseBindings.GOVERNANCE_AND_REGENT_SAFE) - safeBefore,
            fee * 2,
            "the Regent Safe did not receive exactly two launch fees"
        );
        assertEq(
            _allowance(BaseBindings.REGENT, launcher, address(factory)),
            0,
            "a launcher left standing spend authority behind"
        );
        assertEq(_balanceOf(BaseBindings.REGENT, launcher), 0, "the launcher kept part of an exact fee");

        // Launcher provenance is a record and nothing else: no SUBJECT, no role, no authority.
        assertEq(factory.launches(graduating.launchId).launcher, launcher, "the launch record lost its launcher");
        assertEq(_balanceOf(address(graduating.subject), launcher), 0, "a launcher received SUBJECT for launching");

        _assertSupplyPlaced(failing);
        _assertSupplyPlaced(graduating);
    }

    function _assertSupplyPlaced(ForkLaunch memory launched) private view {
        assertEq(
            _balanceOf(address(launched.subject), address(launched.escrow)),
            85_000_000_000e18,
            "escrow does not hold the pending 85%"
        );
        assertEq(
            _balanceOf(address(launched.subject), address(launched.auction)),
            10_000_000_000e18,
            "the auction does not hold the 10% it sells"
        );
        assertEq(_balanceOf(address(launched.subject), address(factory)), 0, "the factory stranded SUBJECT");
    }

    /// @dev One five-argument bid on each launch, from the bidder's own account, through the real
    ///      canonical Permit2. `_bid` performs the complete production sequence and nothing shorter.
    function _bidBoth(ForkLaunch memory failing, ForkLaunch memory graduating)
        private
        returns (uint256 failedBidId, uint256 graduatedBidId)
    {
        vm.roll(failing.auction.startBlock());
        failedBidId = _bid(failing, BID_AMOUNT, 10);
        graduatedBidId = _bid(graduating, BID_AMOUNT, 10);

        assertEq(_allowance(BaseBindings.REGENT, bidder, PERMIT2), 0, "a bidder's ERC20 approval to Permit2 survived");
        assertEq(_balanceOf(BaseBindings.REGENT, bidder), 0, "a bid did not pull the exact amount through Permit2");

        vm.roll(uint256(graduating.auction.endBlock()) + strategy.MIGRATION_DELAY_BLOCKS());
    }

    // -------------------------------------------------------------------------
    // stage 3 — the failure path conserves everything
    // -------------------------------------------------------------------------

    function _assertFailurePathConserves(ForkLaunch memory failing, uint256 failedBidId) private {
        strategy.migrate(address(failing.auction));

        RegentLBPStrategy.Distribution memory d = strategy.distribution(address(failing.auction));
        assertEq(uint8(d.lifecycle), uint8(RegentLBPStrategy.Lifecycle.Failed), "the unreachable raise graduated");
        assertEq(d.splitter, address(0), "a failed launch created a splitter");
        assertEq(d.receiver, address(0), "a failed launch created a canonical receiver");
        assertEq(d.lpTokenId, 0, "a failed launch minted a position");
        assertEq(
            _balanceOf(address(failing.subject), BaseBindings.DEAD_ADDRESS),
            TOTAL_SUPPLY,
            "a failed launch did not retire exactly one hundred billion SUBJECT"
        );
        assertEq(
            failing.subject.totalSupply(), TOTAL_SUPPLY, "the failed launch's supply is not conserved at 100 billion"
        );
        assertEq(_balanceOf(address(failing.subject), address(strategy)), 0, "the strategy kept a failed reserve");
        assertEq(_balanceOf(address(failing.subject), address(failing.escrow)), 0, "escrow kept failed SUBJECT");

        // Bidder REGENT was never touched by retirement, and the bid refunds in full.
        uint256 before = _balanceOf(BaseBindings.REGENT, bidder);
        vm.prank(bidder);
        failing.auction.exitBid(failedBidId);
        assertEq(_balanceOf(BaseBindings.REGENT, bidder) - before, BID_AMOUNT, "a failed bidder was not fully refunded");
    }

    // -------------------------------------------------------------------------
    // stage 4 — the graduation path, at the auction's own final price
    // -------------------------------------------------------------------------

    function _assertGraduationPath(ForkLaunch memory graduating)
        private
        returns (RegentLBPStrategy.Distribution memory d)
    {
        uint256 treasuryBefore = _balanceOf(BaseBindings.REGENT, treasury);
        uint256 escrowBefore = _balanceOf(address(graduating.subject), address(graduating.escrow));
        uint256 auctionSubjectBefore = _balanceOf(address(graduating.subject), address(graduating.auction));

        strategy.migrate(address(graduating.auction));
        d = strategy.distribution(address(graduating.auction));

        assertEq(uint8(d.lifecycle), uint8(RegentLBPStrategy.Lifecycle.Graduated), "the launch did not graduate");
        assertGt(d.splitter.code.length, 0, "graduation deployed no splitter");
        assertGt(d.receiver.code.length, 0, "graduation deployed no canonical receiver");
        assertEq(SubjectSplitterV1(d.splitter).subject(), address(graduating.subject), "splitter SUBJECT binding");
        assertEq(PaymentReceiverV1(payable(d.receiver)).referralBps(), 0, "the canonical receiver charges a referral");
        assertEq(PaymentReceiverV1(payable(d.receiver)).beneficiary(), treasury, "canonical beneficiary");

        // The pool opened at the price the auction actually settled on, and only the strategy could
        // have opened it.
        uint256 raised = graduating.auction.lbpInitializationParams().currencyRaised;
        (uint160 sqrtPriceX96,,,) = IPoolManager(BaseBindings.POOL_MANAGER).getSlot0(d.poolId);
        assertEq(sqrtPriceX96, d.finalSqrtPriceX96, "the pool did not open at the recorded final price");
        assertEq(
            PoolId.unwrap(strategy.poolKeyOf(address(graduating.subject)).toId()),
            PoolId.unwrap(d.poolId),
            "the recorded PoolId is not this launch's official pool"
        );
        assertEq(hook.splitterOf(d.poolId), d.splitter, "the pool is not registered to this launch's splitter");

        // Exactly one full-range position, owned forever by the dead address.
        assertEq(
            IERC721(BaseBindings.POSITION_MANAGER).ownerOf(d.lpTokenId),
            BaseBindings.DEAD_ADDRESS,
            "the managed LP NFT is not owned by the dead address"
        );
        assertGt(
            IPositionManager(BaseBindings.POSITION_MANAGER).getPositionLiquidity(d.lpTokenId),
            0,
            "the managed position carries no liquidity"
        );
        assertGt(d.lpRegentUsed, 0, "the position consumed no REGENT");
        assertGt(d.lpSubjectUsed, 0, "the position consumed no SUBJECT");

        // Both residues land exactly where the specification routes them.
        assertEq(
            _balanceOf(BaseBindings.REGENT, treasury) - treasuryBefore,
            raised - d.lpRegentUsed,
            "the treasury did not receive exactly the unused raise"
        );
        uint256 sweptUnsold =
            auctionSubjectBefore - _balanceOf(address(graduating.subject), address(graduating.auction));
        assertEq(
            _balanceOf(address(graduating.subject), address(graduating.escrow)) - escrowBefore,
            (strategy.RESERVE_ALLOCATION() - d.lpSubjectUsed) + sweptUnsold,
            "escrow did not receive exactly the reserve residue plus the swept unsold supply"
        );

        // Vesting is open over that final inventory, from this block's timestamp.
        assertEq(
            uint8(graduating.escrow.lifecycle()),
            uint8(ConditionalVestingEscrowV1.Lifecycle.Graduated),
            "the escrow is not graduated"
        );
        assertEq(
            uint256(graduating.escrow.vestingStart()),
            block.timestamp,
            "vesting did not start at the graduation timestamp"
        );
        assertTrue(graduating.escrow.graduatedSweepDone(), "the graduated unsold sweep did not run");
    }

    // -------------------------------------------------------------------------
    // stage 5 — a real staker
    // -------------------------------------------------------------------------

    function _stakeSubject(ForkLaunch memory graduating, SubjectSplitterV1 splitter, uint256 amount) private {
        assertGt(amount, 0, "the bidder claimed too little to stake any of it");

        vm.startPrank(bidder);
        UERC20(address(graduating.subject)).approve(address(splitter), amount);
        splitter.stake(amount);
        vm.stopPrank();

        assertEq(splitter.totalStaked(), amount, "the splitter did not record the stake");
        assertEq(splitter.stakedOf(bidder), amount, "the staker's principal is not recorded");
    }

    // -------------------------------------------------------------------------
    // stage 6 — canonical receiver payments in all three recognized assets
    // -------------------------------------------------------------------------

    /// @dev One payment per recognized asset through the canonical zero-referral receiver, each from
    ///      an ordinary payer's own account. Every skim destination is asserted: USDC into the live
    ///      REGENT staking contract through its own `depositUSDC`, REGENT and SUBJECT to the frozen
    ///      Regent Safe.
    function _payCanonicalReceiver(
        ForkLaunch memory graduating,
        RegentLBPStrategy.Distribution memory d,
        SubjectSplitterV1 splitter
    ) private {
        PaymentReceiverV1 receiver = PaymentReceiverV1(payable(d.receiver));

        uint256 usdcAmount = 1_000e6;
        deal(BaseBindings.USDC, payer, usdcAmount);
        uint256 stakingBefore = _balanceOf(BaseBindings.USDC, BaseBindings.LIVE_STAKING);
        _payAs(receiver, BaseBindings.USDC, usdcAmount, bytes32("usdc-payment"));
        assertEq(
            _balanceOf(BaseBindings.USDC, BaseBindings.LIVE_STAKING) - stakingBefore,
            (usdcAmount * SKIM_BPS) / BPS_DENOMINATOR,
            "the USDC skim did not reach the live staking contract"
        );

        uint256 regentAmount = 500e18;
        deal(BaseBindings.REGENT, payer, regentAmount);
        uint256 safeBefore = _balanceOf(BaseBindings.REGENT, BaseBindings.GOVERNANCE_AND_REGENT_SAFE);
        _payAs(receiver, BaseBindings.REGENT, regentAmount, bytes32("regent-payment"));
        assertEq(
            _balanceOf(BaseBindings.REGENT, BaseBindings.GOVERNANCE_AND_REGENT_SAFE) - safeBefore,
            (regentAmount * SKIM_BPS) / BPS_DENOMINATOR,
            "the REGENT skim did not reach the Regent Safe"
        );

        // SUBJECT the bidder really claimed, forwarded to the payer and paid in.
        uint256 subjectAmount = _balanceOf(address(graduating.subject), bidder);
        assertGt(subjectAmount, 0, "the bidder holds no unstaked SUBJECT to pay with");
        vm.prank(bidder);
        UERC20(address(graduating.subject)).transfer(payer, subjectAmount);
        uint256 safeSubjectBefore = _balanceOf(address(graduating.subject), BaseBindings.GOVERNANCE_AND_REGENT_SAFE);
        _payAs(receiver, address(graduating.subject), subjectAmount, bytes32("subject-payment"));
        assertEq(
            _balanceOf(address(graduating.subject), BaseBindings.GOVERNANCE_AND_REGENT_SAFE) - safeSubjectBefore,
            (subjectAmount * SKIM_BPS) / BPS_DENOMINATOR,
            "the SUBJECT skim did not reach the Regent Safe"
        );

        // Every net share became staker liability, and nothing stayed at the receiver.
        assertGt(splitter.unclaimedLiability(BaseBindings.USDC), 0, "no USDC became staker liability");
        assertGt(splitter.unclaimedLiability(BaseBindings.REGENT), 0, "no REGENT became staker liability");
        assertGt(splitter.unclaimedLiability(address(graduating.subject)), 0, "no SUBJECT became staker liability");
        assertEq(_balanceOf(BaseBindings.USDC, d.receiver), 0, "the receiver stranded USDC");
        assertEq(_balanceOf(BaseBindings.REGENT, d.receiver), 0, "the receiver stranded REGENT");
        assertEq(_balanceOf(address(graduating.subject), d.receiver), 0, "the receiver stranded SUBJECT");
        assertEq(_allowance(BaseBindings.USDC, d.receiver, d.splitter), 0, "a receiver allowance survived");
    }

    function _payAs(PaymentReceiverV1 receiver, address token, uint256 amount, bytes32 ref) private {
        vm.startPrank(payer);
        _approveExactly(token, address(receiver), amount);
        receiver.pay(token, amount, ref);
        vm.stopPrank();
        assertEq(_balanceOf(token, payer), 0, "the payer kept part of an exact payment");
        assertEq(_allowance(token, payer, address(receiver)), 0, "a payer left standing spend authority behind");
    }

    // -------------------------------------------------------------------------
    // stage 7 — one real v4 swap, both hook lanes settled inside it
    // -------------------------------------------------------------------------

    /// @dev A REGENT-in exact-input swap on the official pool through an ordinary router. Both 1%
    ///      lanes settle inside this one transaction — one straight to the Regent Safe, one into the
    ///      launch splitter, where the ordinary 2% REGENT skim applies to it and also reaches the
    ///      Safe. The Safe's delta is therefore `lane + skim(lane)`, not `lane`, and asserting the
    ///      sum is what proves both lanes settled rather than one of them twice.
    function _swapBothHookLanes(
        ForkLaunch memory graduating,
        RegentLBPStrategy.Distribution memory d,
        SubjectSplitterV1 splitter
    ) private {
        PoolKey memory key = strategy.poolKeyOf(address(graduating.subject));
        bool regentIsCurrency0 = Currency.unwrap(key.currency0) == BaseBindings.REGENT;
        uint256 amountIn = uint256(-SWAP_AMOUNT_SPECIFIED);
        uint256 lane = amountIn / hook.LANE_DIVISOR();
        uint256 laneSkim = (lane * SKIM_BPS) / BPS_DENOMINATOR;
        assertGt(laneSkim, 0, "the swap is too small for both the lane and its own skim to floor above zero");

        deal(BaseBindings.REGENT, swapper, amountIn);
        uint256 safeBefore = _balanceOf(BaseBindings.REGENT, BaseBindings.GOVERNANCE_AND_REGENT_SAFE);
        uint256 liabilityBefore = splitter.unclaimedLiability(BaseBindings.REGENT);
        uint256 splitterHeldBefore = _balanceOf(BaseBindings.REGENT, d.splitter);

        vm.startPrank(swapper);
        _approveExactly(BaseBindings.REGENT, address(swapRouter), amountIn);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: regentIsCurrency0,
                amountSpecified: SWAP_AMOUNT_SPECIFIED,
                sqrtPriceLimitX96: regentIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        assertEq(
            _balanceOf(BaseBindings.REGENT, BaseBindings.GOVERNANCE_AND_REGENT_SAFE) - safeBefore,
            lane + laneSkim,
            "the two lanes did not settle as one Safe lane plus the splitter lane's own skim"
        );
        assertEq(
            splitter.unclaimedLiability(BaseBindings.REGENT) - liabilityBefore,
            lane - laneSkim,
            "the splitter lane did not become staker liability net of its own skim"
        );
        assertEq(
            _balanceOf(BaseBindings.REGENT, d.splitter) - splitterHeldBefore,
            lane - laneSkim,
            "the splitter is not holding exactly the net it recognized"
        );

        // The hook keeps nothing at all, which is the whole synchronous-settlement claim.
        assertEq(_balanceOf(BaseBindings.REGENT, address(hook)), 0, "the hook retained attributable REGENT");
        assertEq(_allowance(BaseBindings.REGENT, address(hook), d.splitter), 0, "a hook allowance survived the swap");
        assertEq(_balanceOf(BaseBindings.REGENT, swapper), 0, "the swapper did not spend its whole exact input");
        assertGt(_balanceOf(address(graduating.subject), swapper), 0, "the swapper received no SUBJECT");
    }

    // -------------------------------------------------------------------------
    // stage 8 — the staker takes its share and leaves
    // -------------------------------------------------------------------------

    function _claimAllAndUnstake(ForkLaunch memory graduating, SubjectSplitterV1 splitter, uint256 staked) private {
        uint256 usdcBefore = _balanceOf(BaseBindings.USDC, bidder);
        uint256 regentBefore = _balanceOf(BaseBindings.REGENT, bidder);
        uint256 subjectBefore = _balanceOf(address(graduating.subject), bidder);

        uint256 usdcClaimable = splitter.claimable(BaseBindings.USDC, bidder);
        uint256 regentClaimable = splitter.claimable(BaseBindings.REGENT, bidder);
        uint256 subjectClaimable = splitter.claimable(address(graduating.subject), bidder);
        assertGt(usdcClaimable, 0, "the only staker earned no USDC");
        assertGt(regentClaimable, 0, "the only staker earned no REGENT");
        assertGt(subjectClaimable, 0, "the only staker earned no SUBJECT");

        vm.prank(bidder);
        splitter.claimAll();

        assertEq(_balanceOf(BaseBindings.USDC, bidder) - usdcBefore, usdcClaimable, "the USDC claim was inexact");
        assertEq(_balanceOf(BaseBindings.REGENT, bidder) - regentBefore, regentClaimable, "the REGENT claim was inexact");
        assertEq(
            _balanceOf(address(graduating.subject), bidder) - subjectBefore,
            subjectClaimable,
            "the SUBJECT claim was inexact"
        );

        uint256 principalBefore = _balanceOf(address(graduating.subject), bidder);
        vm.prank(bidder);
        splitter.unstake(staked);

        assertEq(
            _balanceOf(address(graduating.subject), bidder) - principalBefore,
            staked,
            "unstaking returned other than the exact principal"
        );
        assertEq(splitter.totalStaked(), 0, "the splitter still records stake after a full unstake");
        assertEq(splitter.stakedOf(bidder), 0, "the account still records principal after a full unstake");
    }

    // -------------------------------------------------------------------------
    // stage 9 — nothing unexplained is left in any Regent contract
    // -------------------------------------------------------------------------

    /// @dev Scoped deliberately to the contracts this system owns and this run deployed. The shared
    ///      PoolManager and PositionManager are not: they are Base-wide singletons whose absolute
    ///      balances belong to everyone, and `DEP-046` is where their disposition is proved by
    ///      delta instead.
    function _assertNoUnexplainedProductionBalances(
        ForkLaunch memory graduating,
        RegentLBPStrategy.Distribution memory d
    ) private view {
        address[3] memory tokens = [BaseBindings.REGENT, BaseBindings.USDC, address(graduating.subject)];
        address[3] memory mustBeEmpty = [address(factory), address(strategy), address(hook)];
        SubjectSplitterV1 splitter = SubjectSplitterV1(d.splitter);

        for (uint256 t; t < tokens.length; ++t) {
            for (uint256 a; a < mustBeEmpty.length; ++a) {
                assertEq(_balanceOf(tokens[t], mustBeEmpty[a]), 0, "a Regent contract holds an unexplained balance");
            }
            assertEq(
                _balanceOf(tokens[t], d.splitter),
                splitter.protectedBalance(tokens[t]),
                "the splitter holds more or less than the inventory it still owes"
            );
            assertEq(_balanceOf(tokens[t], d.receiver), 0, "the canonical receiver stranded value");
        }

        // A graduated launch retires nothing, and its supply is still exactly one hundred billion.
        assertEq(graduating.subject.totalSupply(), TOTAL_SUPPLY, "the graduated launch's supply changed");
        assertEq(
            _balanceOf(address(graduating.subject), BaseBindings.DEAD_ADDRESS),
            0,
            "a graduated launch retired SUBJECT to the dead address"
        );
    }
}
