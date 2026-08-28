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
import {Vm} from "forge-std/Vm.sol";
import {ForkAutolaunch} from "./ForkAutolaunch.sol";

/// @notice `DEP-053`: the complete Autolaunch path, built from the exact final production artifacts
///         and driven end to end against the real frozen Base bindings, at the committed pinned
///         header.
/// @dev The other fork contracts each cut one slice out of this path — bindings, upstream behaviour,
///      terminal outcomes, complete-transaction gas — and they stay separate named proofs. This one
///      is the whole path in one run: deploy, reconcile code identity, launch, bid, fail, refund,
///      retire, graduate, migrate, exit, claim, stake, pay, swap, skim, refuse every same-block value
///      exit, claim and unstake a block later, and account for every unit at the end.
///
///      One complete lifecycle portfolio runs, and it runs at the pinned header. The reduced
///      fresh-head subset deliberately does not repeat it; `docs/audit/README.md` and
///      `docs/audit/fork-authority-and-state-inventory.md` carry that accepted limitation.
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

    /// @dev The C10 recognition event's topic. The boolean the old event carried is gone; the
    ///      splitter now states both shares outright, and every division below is read back out of
    ///      this log rather than only inferred from balances.
    bytes32 internal constant REVENUE_RECOGNIZED_TOPIC =
        keccak256("RevenueRecognized(address,address,bytes32,uint256,uint256,uint256,uint256,uint256)");

    /// @dev One recognition exactly as the splitter reported it.
    struct Recognition {
        uint256 gross;
        uint256 skim;
        uint256 net;
        uint256 stakerShare;
        uint256 treasuryShare;
    }

    struct HookSettlement {
        address feeToken;
        uint256 feeBase;
        uint256 lane;
        bool exactInput;
    }

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
        _exitAcrossTheBlockBoundary(graduating, splitter, staked);

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

        // The real clone was initialized against the real token's own supply. C10 reads
        // `totalSupply()` once during `initialize` and refuses to bind anything that does not report
        // exactly the hundred billion every net is later divided by, so a bound splitter plus this
        // reading is that precondition proved on the production path: the denominator below is the
        // deployed SUBJECT's own supply, not an assumption about it.
        assertEq(
            graduating.subject.totalSupply(),
            TOTAL_SUPPLY,
            "the bound SUBJECT does not report the exact supply the splitter divides every net by"
        );
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
    ///      an ordinary payer's own account, and each divided exactly the way the production splitter
    ///      divides it: the 2% skim to its own destination — USDC into the live REGENT staking
    ///      contract through its own `depositUSDC`, REGENT and SUBJECT to the frozen Regent Safe —
    ///      the floored coverage fraction of the post-skim net to the stakers, and the exact
    ///      remainder to the launch treasury inside the same transaction.
    function _payCanonicalReceiver(
        ForkLaunch memory graduating,
        RegentLBPStrategy.Distribution memory d,
        SubjectSplitterV1 splitter
    ) private {
        PaymentReceiverV1 receiver = PaymentReceiverV1(payable(d.receiver));

        deal(BaseBindings.USDC, payer, 1_000e6);
        _payAndDivide(
            splitter, receiver, BaseBindings.USDC, 1_000e6, bytes32("usdc-payment"), BaseBindings.LIVE_STAKING
        );

        deal(BaseBindings.REGENT, payer, 500e18);
        _payAndDivide(
            splitter,
            receiver,
            BaseBindings.REGENT,
            500e18,
            bytes32("regent-payment"),
            BaseBindings.GOVERNANCE_AND_REGENT_SAFE
        );

        // SUBJECT the bidder really claimed, forwarded to the payer and paid in.
        uint256 subjectAmount = _balanceOf(address(graduating.subject), bidder);
        assertGt(subjectAmount, 0, "the bidder holds no unstaked SUBJECT to pay with");
        vm.prank(bidder);
        UERC20(address(graduating.subject)).transfer(payer, subjectAmount);
        _payAndDivide(
            splitter,
            receiver,
            address(graduating.subject),
            subjectAmount,
            bytes32("subject-payment"),
            BaseBindings.GOVERNANCE_AND_REGENT_SAFE
        );

        // Nothing stayed at the receiver.
        assertEq(_balanceOf(BaseBindings.USDC, d.receiver), 0, "the receiver stranded USDC");
        assertEq(_balanceOf(BaseBindings.REGENT, d.receiver), 0, "the receiver stranded REGENT");
        assertEq(_balanceOf(address(graduating.subject), d.receiver), 0, "the receiver stranded SUBJECT");
        assertEq(_allowance(BaseBindings.USDC, d.receiver, d.splitter), 0, "a receiver allowance survived");
    }

    /// @dev One recognized payment, with every destination held to the exact amount the splitter
    ///      itself reported for it.
    ///
    ///      The staker share is `floor(net * totalStaked / TOTAL_SUPPLY)` and the launch treasury
    ///      takes the rest, so the whole net reaching the stakers is not an outcome this can pass by
    ///      accident. The expected share is deliberately written as plain arithmetic rather than as a
    ///      call into the same full-precision helper the production path uses: both factors here are
    ///      bounded by the hundred-billion-unit supply, so the product cannot overflow and the
    ///      expected value stays an independent derivation.
    function _payAndDivide(
        SubjectSplitterV1 splitter,
        PaymentReceiverV1 receiver,
        address token,
        uint256 gross,
        bytes32 ref,
        address skimDestination
    ) private {
        uint256 skim = (gross * SKIM_BPS) / BPS_DENOMINATOR;
        uint256 stakerShare = ((gross - skim) * splitter.totalStaked()) / TOTAL_SUPPLY;
        assertGt(stakerShare, 0, "this payment's coverage share floored away to nothing");
        assertGt(
            (gross - skim) - stakerShare, 0, "this payment left the launch treasury nothing, so coverage was total"
        );

        uint256 skimmedBefore = _balanceOf(token, skimDestination);
        uint256 liabilityBefore = splitter.unclaimedLiability(token);
        uint256 heldBefore = _balanceOf(token, address(splitter));
        uint256 treasuryBefore = _balanceOf(token, treasury);

        vm.recordLogs();
        _payAs(receiver, token, gross, ref);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Recognition memory r = _soleRecognition(logs, address(splitter), token);
        _assertRecognitionIsExact(r, gross, skim, stakerShare);

        assertEq(
            _balanceOf(token, skimDestination) - skimmedBefore,
            r.skim,
            "the two-percent skim did not reach its own destination"
        );
        assertEq(
            splitter.unclaimedLiability(token) - liabilityBefore,
            r.stakerShare,
            "staker liability did not rise by exactly the supply-coverage share"
        );
        assertEq(
            _balanceOf(token, address(splitter)) - heldBefore,
            r.stakerShare,
            "the splitter is not holding exactly the share it recognized"
        );
        assertEq(
            _balanceOf(token, treasury) - treasuryBefore,
            r.treasuryShare,
            "the launch treasury did not immediately receive the exact uncovered remainder"
        );
    }

    /// @dev The one `RevenueRecognized` an inflow produced, read back out of this run's own logs
    ///      rather than predicted. Reading it is the point: every balance assertion around it is made
    ///      against the splitter's own five amounts, and those amounts are then held to independent
    ///      arithmetic by `_assertRecognitionIsExact`.
    function _soleRecognition(Vm.Log[] memory logs, address splitter, address token)
        private
        returns (Recognition memory r)
    {
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != splitter) continue;
            if (logs[i].topics.length != 4 || logs[i].topics[0] != REVENUE_RECOGNIZED_TOPIC) continue;
            assertFalse(found, "one inflow produced more than one recognition");
            assertEq(address(uint160(uint256(logs[i].topics[1]))), token, "the recognition names another token");
            (r.gross, r.skim, r.net, r.stakerShare, r.treasuryShare) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            found = true;
        }
        assertTrue(found, "the splitter recognized nothing for this inflow");
    }

    /// @dev C10 deleted the `paidToStakers` boolean and states both amounts outright instead, so the
    ///      event is now the splitter's own account of how it divided an inflow. Every field is
    ///      checked: the gross and skim against what was paid, the net against `gross - skim`, the
    ///      staker share against the independently derived supply-coverage fraction, the treasury
    ///      share against the exact remainder, and the three parts against the whole.
    function _assertRecognitionIsExact(Recognition memory r, uint256 gross, uint256 skim, uint256 stakerShare) private {
        assertEq(r.gross, gross, "the recognition reported another gross amount");
        assertEq(r.skim, skim, "the recognition reported another skim amount");
        assertEq(r.net, gross - skim, "the recognition's net is not its gross less its skim");
        assertEq(r.stakerShare, stakerShare, "the recognition's staker share is not the supply-coverage fraction");
        assertEq(r.treasuryShare, r.net - r.stakerShare, "the recognition's treasury share is not the exact remainder");
        assertEq(r.skim + r.stakerShare + r.treasuryShare, r.gross, "the recognition did not conserve its gross");
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
    // stage 7 — two real v4 swaps, both fee assets and both hook lanes settled
    // -------------------------------------------------------------------------

    /// @dev Two exact-input swaps traverse the same official pool through an ordinary router. The
    ///      REGENT-in swap charges realized SUBJECT output; its SUBJECT output then funds the
    ///      reverse swap, which charges realized REGENT output. Each transaction sends one exact
    ///      1% lane straight to the Regent Safe and one through the launch splitter, whose ordinary
    ///      2% skim also reaches the Safe. The Safe delta is therefore `lane + skim(lane)`, and
    ///      asserting that sum for each asset proves both lanes settled rather than one twice.
    ///
    ///      The splitter lane meets no hook-specific path once it arrives: it is an ordinary
    ///      recognition, so it emits the same `RevenueRecognized` a direct payment does, its post-skim
    ///      net is divided by the same fixed supply coverage, and the launch treasury takes the exact
    ///      remainder in this same swap. The lane's division is read back out of that event and held
    ///      to independent arithmetic, exactly as the three payments are.
    function _swapBothHookLanes(
        ForkLaunch memory graduating,
        RegentLBPStrategy.Distribution memory d,
        SubjectSplitterV1 splitter
    ) private {
        PoolKey memory key = strategy.poolKeyOf(address(graduating.subject));
        bool regentIsCurrency0 = Currency.unwrap(key.currency0) == BaseBindings.REGENT;
        uint256 regentIn = uint256(-SWAP_AMOUNT_SPECIFIED);

        deal(BaseBindings.REGENT, swapper, regentIn);
        _swapOneFeeAsset(
            key, regentIsCurrency0, BaseBindings.REGENT, address(graduating.subject), regentIn, d, splitter
        );

        uint256 subjectIn = _balanceOf(address(graduating.subject), swapper);
        assertGt(subjectIn, 0, "the first official-pool swap returned no SUBJECT for the reverse swap");
        _swapOneFeeAsset(
            key, !regentIsCurrency0, address(graduating.subject), BaseBindings.REGENT, subjectIn, d, splitter
        );
    }

    function _swapOneFeeAsset(
        PoolKey memory key,
        bool zeroForOne,
        address inputToken,
        address feeToken,
        uint256 amountIn,
        RegentLBPStrategy.Distribution memory d,
        SubjectSplitterV1 splitter
    ) private {
        uint256 safeBefore = _balanceOf(feeToken, BaseBindings.GOVERNANCE_AND_REGENT_SAFE);
        uint256 liabilityBefore = splitter.unclaimedLiability(feeToken);
        uint256 splitterHeldBefore = _balanceOf(feeToken, d.splitter);
        uint256 treasuryBefore = _balanceOf(feeToken, treasury);
        uint256 outputBefore = _balanceOf(feeToken, swapper);

        vm.recordLogs();
        vm.startPrank(swapper);
        _approveExactly(inputToken, address(swapRouter), amountIn);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        HookSettlement memory settled = _soleHookSettlement(logs);
        assertEq(settled.feeToken, feeToken, "the hook charged other than the realized fee asset");
        assertTrue(settled.exactInput, "the hook reported another swap mode");
        assertEq(settled.lane, settled.feeBase / hook.LANE_DIVISOR(), "the lane did not floor realized output");
        uint256 lane = settled.lane;
        uint256 laneSkim = (lane * SKIM_BPS) / BPS_DENOMINATOR;
        assertGt(laneSkim, 0, "the swap is too small for both the lane and its own skim to floor above zero");
        uint256 laneStakerShare = ((lane - laneSkim) * splitter.totalStaked()) / TOTAL_SUPPLY;
        assertGt(laneStakerShare, 0, "the splitter lane's coverage share floored away to nothing");
        assertGt(
            (lane - laneSkim) - laneStakerShare,
            0,
            "the splitter lane left the launch treasury nothing, so coverage was total"
        );

        Recognition memory r = _soleRecognition(logs, d.splitter, feeToken);
        _assertRecognitionIsExact(r, lane, laneSkim, laneStakerShare);

        assertEq(
            _balanceOf(feeToken, BaseBindings.GOVERNANCE_AND_REGENT_SAFE) - safeBefore,
            lane + r.skim,
            "the two lanes did not settle as one Safe lane plus the splitter lane's own skim"
        );
        assertEq(
            splitter.unclaimedLiability(feeToken) - liabilityBefore,
            r.stakerShare,
            "the splitter lane's net did not become staker liability at the supply-coverage fraction"
        );
        assertEq(
            _balanceOf(feeToken, d.splitter) - splitterHeldBefore,
            r.stakerShare,
            "the splitter is not holding exactly the share it recognized"
        );
        assertEq(
            _balanceOf(feeToken, treasury) - treasuryBefore,
            r.treasuryShare,
            "the launch treasury did not receive the lane's exact uncovered remainder in the swap"
        );

        // The hook keeps nothing at all, which is the whole synchronous-settlement claim.
        assertEq(_balanceOf(feeToken, address(hook)), 0, "the hook retained an attributable fee asset");
        assertEq(_allowance(feeToken, address(hook), d.splitter), 0, "a hook allowance survived the swap");
        assertEq(_balanceOf(inputToken, swapper), 0, "the swapper did not spend its whole exact input");
        assertGt(_balanceOf(feeToken, swapper), outputBefore, "the swapper received no realized fee asset");
    }

    function _soleHookSettlement(Vm.Log[] memory logs) private returns (HookSettlement memory settled) {
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics.length != 4 || logs[i].topics[0] != RegentFeeHook.SwapFeeSettled.selector) continue;
            assertFalse(found, "one swap produced more than one hook settlement");
            settled.feeToken = address(uint160(uint256(logs[i].topics[3])));
            (settled.feeBase, settled.lane, settled.exactInput) = abi.decode(logs[i].data, (uint256, uint256, bool));
            found = true;
        }
        assertTrue(found, "the hook emitted no settlement");
    }

    // -------------------------------------------------------------------------
    // stage 8 — every value exit waits a block, then the staker takes its share and leaves
    // -------------------------------------------------------------------------

    function _exitAcrossTheBlockBoundary(ForkLaunch memory graduating, SubjectSplitterV1 splitter, uint256 staked)
        private
    {
        _proveEverySameBlockExitIsRefused(address(graduating.subject), splitter, staked);
        _claimAndExitOneBlockLater(address(graduating.subject), splitter, staked);
    }

    /// @dev The C10 exit rule on the real path rather than only against a hermetic double. Accrual is
    ///      immediate — the stake, all three payments and the swap happened in this block and the
    ///      `claimable` views already report the entitlement they produced — but *value* may not
    ///      leave in the account's own stake block. All three exits are refused here, each with the
    ///      exact `SameBlockStakeExit(account, stakeBlock)` this position earned, and the refusals
    ///      move no principal, no entitlement, no splitter inventory, and no protected accounting.
    ///
    ///      The expected stake block is `block.number` because nothing has rolled since the stake; a
    ///      later edit that inserted a roll would fail here rather than silently weaken the claim.
    function _proveEverySameBlockExitIsRefused(address subjectToken, SubjectSplitterV1 splitter, uint256 staked)
        private
    {
        address[3] memory tokens = [BaseBindings.USDC, BaseBindings.REGENT, subjectToken];
        uint256[3] memory bidderBefore;
        uint256[3] memory splitterBefore;
        uint256[3] memory protectedBefore;
        uint256[3] memory claimableBefore;
        for (uint256 i; i < tokens.length; ++i) {
            bidderBefore[i] = _balanceOf(tokens[i], bidder);
            splitterBefore[i] = _balanceOf(tokens[i], address(splitter));
            protectedBefore[i] = splitter.protectedBalance(tokens[i]);
            claimableBefore[i] = splitter.claimable(tokens[i], bidder);
            assertGt(claimableBefore[i], 0, "the only staker earned nothing in a recognized asset");
        }

        bytes memory refusal =
            abi.encodeWithSelector(SubjectSplitterV1.SameBlockStakeExit.selector, bidder, block.number);

        vm.startPrank(bidder);
        vm.expectRevert(refusal);
        splitter.unstake(staked);
        vm.expectRevert(refusal);
        splitter.claim(subjectToken);
        vm.expectRevert(refusal);
        splitter.claimAll();
        vm.stopPrank();

        assertEq(splitter.stakedOf(bidder), staked, "a refused exit changed the account's principal");
        assertEq(splitter.totalStaked(), staked, "a refused exit changed the staked total");
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(_balanceOf(tokens[i], bidder), bidderBefore[i], "a refused exit moved value to the account");
            assertEq(
                _balanceOf(tokens[i], address(splitter)),
                splitterBefore[i],
                "a refused exit moved the splitter's inventory"
            );
            assertEq(
                splitter.protectedBalance(tokens[i]), protectedBefore[i], "a refused exit changed protected inventory"
            );
            assertEq(splitter.claimable(tokens[i], bidder), claimableBefore[i], "a refused exit changed an entitlement");
        }
    }

    /// @dev Exactly one block later the identical calls succeed. `claim` settles one asset and
    ///      `claimAll` settles the other two, so both refused surfaces are proved open again rather
    ///      than only the one; then the complete withdrawal returns exactly the principal and
    ///      nothing else. Waiting one block is what a real staker does.
    function _claimAndExitOneBlockLater(address subjectToken, SubjectSplitterV1 splitter, uint256 staked) private {
        vm.roll(block.number + 1);

        uint256 usdcClaimable = splitter.claimable(BaseBindings.USDC, bidder);
        uint256 usdcBefore = _balanceOf(BaseBindings.USDC, bidder);
        vm.prank(bidder);
        splitter.claim(BaseBindings.USDC);
        assertEq(
            _balanceOf(BaseBindings.USDC, bidder) - usdcBefore, usdcClaimable, "the single-asset claim was inexact"
        );

        uint256 regentClaimable = splitter.claimable(BaseBindings.REGENT, bidder);
        uint256 subjectClaimable = splitter.claimable(subjectToken, bidder);
        uint256 regentBefore = _balanceOf(BaseBindings.REGENT, bidder);
        uint256 principalBefore = _balanceOf(subjectToken, bidder);
        vm.prank(bidder);
        splitter.claimAll();
        assertEq(
            _balanceOf(BaseBindings.REGENT, bidder) - regentBefore, regentClaimable, "the REGENT claim was inexact"
        );
        assertEq(_balanceOf(subjectToken, bidder) - principalBefore, subjectClaimable, "the SUBJECT claim was inexact");
        assertEq(splitter.claimable(BaseBindings.USDC, bidder), 0, "claimAll left a USDC entitlement standing");

        principalBefore = _balanceOf(subjectToken, bidder);
        vm.prank(bidder);
        splitter.unstake(staked);

        assertEq(
            _balanceOf(subjectToken, bidder) - principalBefore,
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
