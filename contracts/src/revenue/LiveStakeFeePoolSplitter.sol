// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Owned} from "src/auth/Owned.sol";
import {SafeTransferLib} from "src/libraries/SafeTransferLib.sol";
import {IERC20SupplyMinimal} from "src/revenue/interfaces/IERC20SupplyMinimal.sol";
import {
    IRevenueIngressAccountMinimal
} from "src/revenue/interfaces/IRevenueIngressAccountMinimal.sol";
import {
    IRevenueIngressFactoryMinimal
} from "src/revenue/interfaces/IRevenueIngressFactoryMinimal.sol";
import {IRevenueShareSplitter} from "src/revenue/interfaces/IRevenueShareSplitter.sol";
import {IRegentStakingRevenueRouter} from "src/revenue/interfaces/IRegentStakingRevenueRouter.sol";
import {ISubjectLifecycleSync} from "src/revenue/interfaces/ISubjectLifecycleSync.sol";
import {ISubjectRegistry} from "src/revenue/interfaces/ISubjectRegistry.sol";
import {InputBounds} from "src/revenue/libraries/InputBounds.sol";

contract LiveStakeFeePoolSplitter is Owned, IRevenueShareSplitter, ISubjectLifecycleSync {
    using SafeTransferLib for address;

    enum RevenueSourceKind {
        DirectDeposit,
        AuthorizedIngress
    }

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant ACC_PRECISION = 1e27;

    address public immutable override stakeToken;
    address public immutable override usdc;
    address public immutable ingressFactory;
    address public immutable subjectRegistry;
    bytes32 public immutable override subjectId;
    IRegentStakingRevenueRouter public immutable stakingRevenueRouter;

    address public override treasuryRecipient;
    uint16 public immutable stakerPoolBps;
    string public label;
    bool public paused;
    bool public subjectLifecycleRetired;

    uint256 public override totalStaked;
    uint256 public accRewardPerTokenUsdc;
    uint256 public totalUsdcReceived;
    uint256 public directDepositUsdc;
    uint256 public verifiedIngressUsdc;
    uint256 public protocolFeeUsdc;
    uint256 public netAgentLaneUsdc;
    uint256 public stakerPoolInflowUsdc;
    uint256 public treasuryReservedUsdc;
    uint256 public noStakerPoolRoutedToTreasuryUsdc;
    uint256 public undistributedDustUsdc;
    uint256 public totalUsdcCreditedToStakers;
    uint256 public totalClaimedUsdc;

    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public rewardDebtUsdc;
    mapping(address => uint256) public storedClaimableUsdc;

    uint256 private _reentrancyGuard = 1;

    event PausedSet(bool paused);
    event LabelSet(string label);
    event StakeUpdated(address indexed account, uint256 newStakeBalance, uint256 totalStaked);
    event USDCRevenueDeposited(
        uint256 amountReceived,
        uint256 protocolAmount,
        uint16 eligibleShareBps,
        uint256 stakerEligibleAmount,
        uint256 treasuryReservedAmount,
        uint256 stakerEntitlement,
        uint256 treasuryResidualAmount,
        RevenueSourceKind indexed sourceKind,
        address indexed depositor,
        bytes32 sourceTag,
        bytes32 indexed sourceRef
    );
    event USDCRewardClaimed(address indexed account, uint256 amount, address recipient);
    event USDCTreasuryWithdrawn(uint256 amount, address indexed recipient);
    event AccountSynced(address indexed account);
    event SubjectLifecycleSynced(bool active, bool retiring, bool retired);

    constructor(
        address stakeToken_,
        address usdc_,
        address ingressFactory_,
        address subjectRegistry_,
        bytes32 subjectId_,
        address treasuryRecipient_,
        address stakingRevenueRouter_,
        uint16 stakerPoolBps_,
        string memory label_,
        address owner_
    ) Owned(owner_) {
        require(stakeToken_ != address(0), "STAKE_TOKEN_ZERO");
        require(usdc_ != address(0), "USDC_ZERO");
        require(stakeToken_ != usdc_, "STAKE_TOKEN_IS_USDC");
        require(ingressFactory_ != address(0), "INGRESS_FACTORY_ZERO");
        require(subjectRegistry_ != address(0), "SUBJECT_REGISTRY_ZERO");
        require(subjectId_ != bytes32(0), "SUBJECT_ZERO");
        require(treasuryRecipient_ != address(0), "TREASURY_ZERO");
        require(treasuryRecipient_ != address(this), "TREASURY_IS_SELF");
        require(stakingRevenueRouter_ != address(0), "STAKING_ROUTER_ZERO");
        require(stakerPoolBps_ <= BPS_DENOMINATOR, "STAKER_POOL_TOO_HIGH");
        require(owner_ != address(0), "OWNER_ZERO");
        require(
            IRegentStakingRevenueRouter(stakingRevenueRouter_).usdc() == usdc_,
            "STAKING_ROUTER_USDC_MISMATCH"
        );
        InputBounds.requireStringMax(label_, InputBounds.MAX_LABEL_BYTES, "LABEL_TOO_LONG");

        stakeToken = stakeToken_;
        usdc = usdc_;
        ingressFactory = ingressFactory_;
        subjectRegistry = subjectRegistry_;
        subjectId = subjectId_;
        treasuryRecipient = treasuryRecipient_;
        stakingRevenueRouter = IRegentStakingRevenueRouter(stakingRevenueRouter_);
        stakerPoolBps = stakerPoolBps_;
        label = label_;
    }

    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }

    modifier nonReentrant() {
        require(_reentrancyGuard == 1, "REENTRANT");
        _reentrancyGuard = 2;
        _;
        _reentrancyGuard = 1;
    }

    modifier onlyActiveSubject() {
        require(_subjectIsActive(), "SUBJECT_INACTIVE");
        _;
    }

    modifier onlySubjectRegistry() {
        require(msg.sender == subjectRegistry, "ONLY_SUBJECT_REGISTRY");
        _;
    }

    function protocolRecipient() external view override returns (address) {
        return address(stakingRevenueRouter);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setLabel(string calldata label_) external onlyOwner {
        InputBounds.requireStringMax(label_, InputBounds.MAX_LABEL_BYTES, "LABEL_TOO_LONG");
        label = label_;
        emit LabelSet(label_);
    }

    function stake(uint256 amount, address receiver)
        external
        whenNotPaused
        onlyActiveSubject
        nonReentrant
    {
        require(amount != 0, "AMOUNT_ZERO");
        require(receiver != address(0), "RECEIVER_ZERO");
        require(receiver != address(this), "RECEIVER_IS_SELF");

        _sync(receiver);
        _pullExactStakeToken(msg.sender, amount);

        stakedBalance[receiver] += amount;
        totalStaked += amount;

        emit StakeUpdated(receiver, stakedBalance[receiver], totalStaked);
    }

    function unstake(uint256 amount, address recipient) external nonReentrant {
        require(amount != 0, "AMOUNT_ZERO");
        require(recipient != address(0), "RECIPIENT_ZERO");
        require(recipient != address(this), "RECIPIENT_IS_SELF");

        _sync(msg.sender);

        uint256 currentStake = stakedBalance[msg.sender];
        require(currentStake >= amount, "STAKE_BALANCE_LOW");

        unchecked {
            stakedBalance[msg.sender] = currentStake - amount;
            totalStaked -= amount;
        }

        emit StakeUpdated(msg.sender, stakedBalance[msg.sender], totalStaked);
        _pushExactStakeToken(recipient, amount);
    }

    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef)
        external
        override
        whenNotPaused
        onlyActiveSubject
        nonReentrant
        returns (uint256 received)
    {
        require(amount != 0, "AMOUNT_ZERO");
        uint256 beforeBalance = IERC20SupplyMinimal(usdc).balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = IERC20SupplyMinimal(usdc).balanceOf(address(this));
        received = afterBalance - beforeBalance;

        _recordRevenue(received, RevenueSourceKind.DirectDeposit, msg.sender, sourceTag, sourceRef);
    }

    function recordIngressSweep(uint256 amount, bytes32 sourceRef)
        external
        override
        whenNotPaused
        onlyActiveSubject
        nonReentrant
        returns (uint256 recognized)
    {
        require(amount != 0, "AMOUNT_ZERO");
        require(_isKnownIngress(msg.sender), "ONLY_INGRESS_ACCOUNT");

        recognized = amount;
        _recordRevenue(
            amount,
            RevenueSourceKind.AuthorizedIngress,
            msg.sender,
            bytes32("ingress_sweep"),
            sourceRef
        );
    }

    function sync(address account) external whenNotPaused nonReentrant {
        require(account != address(0), "ACCOUNT_ZERO");
        _sync(account);
        emit AccountSynced(account);
    }

    function previewClaimableUSDC(address account) public view override returns (uint256) {
        uint256 claimable = storedClaimableUsdc[account];
        uint256 currentAcc = accRewardPerTokenUsdc;
        uint256 priorAcc = rewardDebtUsdc[account];
        if (currentAcc <= priorAcc) {
            return claimable;
        }

        uint256 stakeBal = stakedBalance[account];
        if (stakeBal == 0) {
            return claimable;
        }

        return claimable + FullMath.mulDiv(stakeBal, currentAcc - priorAcc, ACC_PRECISION);
    }

    function claimUSDC(address recipient) external nonReentrant returns (uint256 amount) {
        require(recipient != address(0), "RECIPIENT_ZERO");
        require(recipient != address(this), "RECIPIENT_IS_SELF");

        _sync(msg.sender);
        amount = storedClaimableUsdc[msg.sender];
        if (amount < 1) {
            return 0;
        }

        storedClaimableUsdc[msg.sender] = 0;
        totalClaimedUsdc += amount;
        emit USDCRewardClaimed(msg.sender, amount, recipient);
        usdc.safeTransfer(recipient, amount);
    }

    function sweepTreasuryUSDC(uint256 amount) external whenNotPaused nonReentrant {
        require(msg.sender == owner || msg.sender == treasuryRecipient, "ONLY_TREASURY");
        require(amount != 0, "AMOUNT_ZERO");
        require(treasuryReservedUsdc >= amount, "TREASURY_BALANCE_LOW");

        treasuryReservedUsdc -= amount;
        emit USDCTreasuryWithdrawn(amount, treasuryRecipient);
        usdc.safeTransfer(treasuryRecipient, amount);
    }

    function reservedUsdc() public view returns (uint256) {
        uint256 stakerLiability = totalUsdcCreditedToStakers - totalClaimedUsdc;
        return treasuryReservedUsdc + undistributedDustUsdc + stakerLiability;
    }

    function surplusUsdc() public view returns (uint256) {
        uint256 balance = IERC20SupplyMinimal(usdc).balanceOf(address(this));
        uint256 reserved = reservedUsdc();
        if (balance <= reserved) {
            return 0;
        }
        unchecked {
            return balance - reserved;
        }
    }

    function syncSubjectLifecycle(bool active_, bool retiring_) external onlySubjectRegistry {
        if (retiring_) {
            subjectLifecycleRetired = true;
        }
        emit SubjectLifecycleSynced(active_, retiring_, subjectLifecycleRetired);
    }

    function _recordRevenue(
        uint256 received,
        RevenueSourceKind sourceKind,
        address depositor,
        bytes32 sourceTag,
        bytes32 sourceRef
    ) internal {
        require(received > 0, "NOTHING_RECEIVED");

        uint16 skimBps = stakingRevenueRouter.protocolSkimBps();
        uint256 protocolAmount = FullMath.mulDiv(received, skimBps, BPS_DENOMINATOR);
        uint256 net = received - protocolAmount;
        uint256 stakerPool = FullMath.mulDiv(net, stakerPoolBps, BPS_DENOMINATOR);
        uint256 treasuryAmount = net - stakerPool;
        uint256 stakerEntitlement;
        uint256 creditedByAccumulator;
        uint256 routedToTreasuryNoStakers;

        if (stakerPool > 0) {
            if (totalStaked == 0) {
                treasuryAmount += stakerPool;
                routedToTreasuryNoStakers = stakerPool;
            } else {
                uint256 deltaAcc = FullMath.mulDiv(stakerPool, ACC_PRECISION, totalStaked);
                require(deltaAcc != 0, "STAKER_POOL_TOO_SMALL");
                accRewardPerTokenUsdc += deltaAcc;
                stakerEntitlement = stakerPool;
                creditedByAccumulator = FullMath.mulDiv(deltaAcc, totalStaked, ACC_PRECISION);
                if (stakerPool > creditedByAccumulator) {
                    undistributedDustUsdc += stakerPool - creditedByAccumulator;
                }
            }
        }

        totalUsdcReceived += received;
        if (sourceKind == RevenueSourceKind.DirectDeposit) {
            directDepositUsdc += received;
        } else if (sourceKind == RevenueSourceKind.AuthorizedIngress) {
            verifiedIngressUsdc += received;
        }
        protocolFeeUsdc += protocolAmount;
        netAgentLaneUsdc += net;
        stakerPoolInflowUsdc += stakerPool;
        treasuryReservedUsdc += treasuryAmount;
        noStakerPoolRoutedToTreasuryUsdc += routedToTreasuryNoStakers;
        totalUsdcCreditedToStakers += creditedByAccumulator;

        if (protocolAmount > 0) {
            usdc.safeTransfer(address(stakingRevenueRouter), protocolAmount);
            stakingRevenueRouter.processProtocolFee(
                subjectId, treasuryRecipient, protocolAmount, sourceRef
            );
        }

        emit USDCRevenueDeposited(
            received,
            protocolAmount,
            stakerPoolBps,
            stakerPool,
            treasuryAmount,
            stakerEntitlement,
            routedToTreasuryNoStakers,
            sourceKind,
            depositor,
            sourceTag,
            sourceRef
        );
    }

    function _sync(address account) internal {
        uint256 currentAcc = accRewardPerTokenUsdc;
        uint256 priorAcc = rewardDebtUsdc[account];
        if (currentAcc <= priorAcc) {
            return;
        }

        uint256 stakeBal = stakedBalance[account];
        if (stakeBal > 0) {
            storedClaimableUsdc[
                account
            ] += FullMath.mulDiv(stakeBal, currentAcc - priorAcc, ACC_PRECISION);
        }
        rewardDebtUsdc[account] = currentAcc;
    }

    function _subjectIsActive() internal view returns (bool) {
        return
            !subjectLifecycleRetired
                && ISubjectRegistry(subjectRegistry).getSubject(subjectId).active;
    }

    function _isKnownIngress(address ingress) internal view returns (bool) {
        if (ingress.code.length == 0) {
            return false;
        }
        if (!IRevenueIngressFactoryMinimal(ingressFactory).isIngressAccount(ingress)) {
            return false;
        }

        try IRevenueIngressAccountMinimal(ingress).splitter() returns (address splitterAddress) {
            if (splitterAddress != address(this)) {
                return false;
            }
        } catch {
            return false;
        }

        try IRevenueIngressAccountMinimal(ingress).subjectId() returns (bytes32 ingressSubjectId) {
            if (ingressSubjectId != subjectId) {
                return false;
            }
        } catch {
            return false;
        }

        try IRevenueIngressAccountMinimal(ingress).usdc() returns (address ingressUsdc) {
            return ingressUsdc == usdc;
        } catch {
            return false;
        }
    }

    function _pullExactStakeToken(address from, uint256 amount)
        internal
        returns (uint256 received)
    {
        uint256 beforeBalance = IERC20SupplyMinimal(stakeToken).balanceOf(address(this));
        stakeToken.safeTransferFrom(from, address(this), amount);
        uint256 afterBalance = IERC20SupplyMinimal(stakeToken).balanceOf(address(this));
        received = afterBalance - beforeBalance;
        require(received == amount, "STAKE_TOKEN_IN_EXACT");
    }

    function _pushExactStakeToken(address recipient, uint256 amount) internal {
        uint256 beforeBalance = IERC20SupplyMinimal(stakeToken).balanceOf(recipient);
        stakeToken.safeTransfer(recipient, amount);
        uint256 afterBalance = IERC20SupplyMinimal(stakeToken).balanceOf(recipient);
        require(afterBalance - beforeBalance == amount, "STAKE_TOKEN_OUT_EXACT");
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == usdc || token == stakeToken;
    }
}
