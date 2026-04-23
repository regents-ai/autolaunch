// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {SafeTransferLib} from "src/libraries/SafeTransferLib.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC20SupplyMinimal} from "src/revenue/interfaces/IERC20SupplyMinimal.sol";
import {ILaunchFeeVaultMinimal} from "src/revenue/interfaces/ILaunchFeeVaultMinimal.sol";
import {
    IRevenueIngressAccountMinimal
} from "src/revenue/interfaces/IRevenueIngressAccountMinimal.sol";
import {
    IRevenueIngressFactoryMinimal
} from "src/revenue/interfaces/IRevenueIngressFactoryMinimal.sol";
import {IRevenueShareSplitter} from "src/revenue/interfaces/IRevenueShareSplitter.sol";
import {ISubjectRegistry} from "src/revenue/interfaces/ISubjectRegistry.sol";
import {ISubjectLifecycleSync} from "src/revenue/interfaces/ISubjectLifecycleSync.sol";

contract RevenueShareSplitter is Owned, IRevenueShareSplitter, ISubjectLifecycleSync {
    using SafeTransferLib for address;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant ACC_PRECISION = 1e27;
    uint256 public constant MAX_EMISSION_APR_BPS = 10_000;
    uint16 public constant protocolSkimBps = 100;
    uint16 public constant MIN_ELIGIBLE_REVENUE_SHARE_BPS = 1000;
    uint16 public constant MAX_ELIGIBLE_REVENUE_SHARE_STEP_BPS = 2000;
    uint16 public constant DEFAULT_ELIGIBLE_REVENUE_SHARE_BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint64 internal constant DEFAULT_TREASURY_ROTATION_DELAY = 3 days;
    uint64 internal constant ELIGIBLE_REVENUE_SHARE_DELAY = 30 days;

    address public immutable override stakeToken;
    address public immutable override usdc;
    address public immutable ingressFactory;
    address public immutable subjectRegistry;
    bytes32 public immutable override subjectId;
    uint256 public immutable revenueShareSupplyDenominator;

    string public label;

    address public override treasuryRecipient;
    address public pendingTreasuryRecipient;
    uint64 public pendingTreasuryRecipientEta;
    uint64 public immutable treasuryRotationDelay;
    address public override protocolRecipient;
    uint16 public emissionAprBps;
    uint16 public eligibleRevenueShareBps;
    uint16 public pendingEligibleRevenueShareBps;
    uint64 public pendingEligibleRevenueShareEta;
    uint64 public eligibleRevenueShareCooldownEnd;

    bool public paused;
    bool public subjectLifecycleRetired;
    uint256 public override totalStaked;
    uint256 public accRewardPerTokenUsdc;
    uint256 public accRewardPerTokenStakeToken;
    uint256 public lastEmissionUpdate;
    uint256 public treasuryResidualUsdc;
    uint256 public treasuryReservedUsdc;
    uint256 public protocolReserveUsdc;
    uint256 public undistributedDustUsdc;
    uint256 public unclaimedStakeTokenLiability;
    uint256 public totalEmittedStakeToken;
    uint256 public totalFundedStakeToken;
    uint256 public totalClaimedStakeToken;
    uint256 public grossInflowUsdc;
    uint256 public regentSkimUsdc;
    uint256 public stakerEligibleInflowUsdc;
    uint256 public treasuryReservedInflowUsdc;

    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public rewardDebtUsdc;
    mapping(address => uint256) public storedClaimableUsdc;
    mapping(address => uint256) public rewardDebtStakeToken;
    mapping(address => uint256) public storedClaimableStakeToken;

    uint256 private _reentrancyGuard = 1;

    event PausedSet(bool paused);
    event TreasuryRecipientRotationProposed(
        address indexed currentRecipient, address indexed pendingRecipient, uint64 eta
    );
    event TreasuryRecipientRotationCancelled(
        address indexed currentRecipient, address indexed cancelledRecipient
    );
    event TreasuryRecipientRotationExecuted(
        address indexed oldRecipient, address indexed newRecipient
    );
    event ProtocolRecipientSet(address indexed protocolRecipient);
    event EmissionAprBpsSet(uint16 previousBps, uint16 newBps);
    event LabelSet(string label);
    event EligibleRevenueShareProposed(
        uint16 indexed currentBps, uint16 indexed pendingBps, uint64 eta
    );
    event EligibleRevenueShareCancelled(uint16 indexed cancelledBps, uint64 cooldownEnd);
    event EligibleRevenueShareActivated(
        uint16 indexed previousBps,
        uint16 indexed newBps,
        uint64 activatedAt,
        uint64 cooldownEnd
    );
    event StakeUpdated(address indexed account, uint256 newStakeBalance, uint256 totalStaked);
    event USDCRevenueDeposited(
        uint256 amountReceived,
        uint256 protocolAmount,
        uint16 eligibleShareBps,
        uint256 stakerEligibleAmount,
        uint256 treasuryReservedAmount,
        uint256 stakerEntitlement,
        uint256 treasuryResidualAmount,
        bytes32 indexed sourceTag,
        bytes32 indexed sourceRef
    );
    event USDCRewardClaimed(address indexed account, uint256 amount, address recipient);
    event RewardTokenFunded(address indexed caller, uint256 amountReceived);
    event RewardTokenClaimed(address indexed account, uint256 amount, address recipient);
    event RewardTokenCompounded(
        address indexed account, uint256 amount, uint256 newStakeBalance, uint256 totalStaked
    );
    event USDCTreasuryResidualWithdrawn(uint256 amount, address indexed recipient);
    event USDCTreasuryReservedWithdrawn(uint256 amount, address indexed recipient);
    event USDCProtocolReserveWithdrawn(uint256 amount, address indexed recipient);
    event USDCDustReassigned(uint256 amount, address indexed recipient);

    constructor(
        address stakeToken_,
        address usdc_,
        address ingressFactory_,
        address subjectRegistry_,
        bytes32 subjectId_,
        address treasuryRecipient_,
        address protocolRecipient_,
        uint256 revenueShareSupplyDenominator_,
        string memory label_,
        address owner_
    ) Owned(owner_) {
        require(stakeToken_ != address(0), "STAKE_TOKEN_ZERO");
        require(usdc_ != address(0), "USDC_ZERO");
        require(ingressFactory_ != address(0), "INGRESS_FACTORY_ZERO");
        require(subjectRegistry_ != address(0), "SUBJECT_REGISTRY_ZERO");
        require(subjectId_ != bytes32(0), "SUBJECT_ZERO");
        require(treasuryRecipient_ != address(0), "TREASURY_ZERO");
        require(protocolRecipient_ != address(0), "PROTOCOL_ZERO");
        require(revenueShareSupplyDenominator_ != 0, "SUPPLY_DENOMINATOR_ZERO");

        stakeToken = stakeToken_;
        usdc = usdc_;
        ingressFactory = ingressFactory_;
        subjectRegistry = subjectRegistry_;
        subjectId = subjectId_;
        revenueShareSupplyDenominator = revenueShareSupplyDenominator_;
        treasuryRecipient = treasuryRecipient_;
        treasuryRotationDelay = DEFAULT_TREASURY_ROTATION_DELAY;
        protocolRecipient = protocolRecipient_;
        label = label_;
        lastEmissionUpdate = block.timestamp;
        eligibleRevenueShareBps = DEFAULT_ELIGIBLE_REVENUE_SHARE_BPS;
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

    modifier onlyTreasurySweepCaller() {
        require(msg.sender == owner || msg.sender == treasuryRecipient, "ONLY_TREASURY");
        _;
    }

    modifier onlyProtocolSweepCaller() {
        require(msg.sender == owner || msg.sender == protocolRecipient, "ONLY_PROTOCOL");
        _;
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function proposeTreasuryRecipientRotation(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "TREASURY_ZERO");
        require(newRecipient != treasuryRecipient, "TREASURY_UNCHANGED");

        uint64 eta = uint64(block.timestamp) + treasuryRotationDelay;
        pendingTreasuryRecipient = newRecipient;
        pendingTreasuryRecipientEta = eta;

        emit TreasuryRecipientRotationProposed(treasuryRecipient, newRecipient, eta);
    }

    function cancelTreasuryRecipientRotation() external onlyOwner {
        address cancelledRecipient = pendingTreasuryRecipient;
        require(cancelledRecipient != address(0), "PENDING_TREASURY_ZERO");

        pendingTreasuryRecipient = address(0);
        pendingTreasuryRecipientEta = 0;

        emit TreasuryRecipientRotationCancelled(treasuryRecipient, cancelledRecipient);
    }

    function executeTreasuryRecipientRotation() external {
        address newRecipient = pendingTreasuryRecipient;
        require(newRecipient != address(0), "PENDING_TREASURY_ZERO");
        require(block.timestamp >= pendingTreasuryRecipientEta, "ROTATION_NOT_READY");

        address oldRecipient = treasuryRecipient;
        treasuryRecipient = newRecipient;
        pendingTreasuryRecipient = address(0);
        pendingTreasuryRecipientEta = 0;

        emit TreasuryRecipientRotationExecuted(oldRecipient, newRecipient);
    }

    function proposeEligibleRevenueShare(uint16 newBps) external onlyOwner {
        require(pendingEligibleRevenueShareEta == 0, "PENDING_SHARE_EXISTS");
        require(block.timestamp >= eligibleRevenueShareCooldownEnd, "SHARE_COOLDOWN_ACTIVE");
        require(newBps >= MIN_ELIGIBLE_REVENUE_SHARE_BPS, "ELIGIBLE_SHARE_TOO_LOW");
        require(newBps <= BPS_DENOMINATOR, "ELIGIBLE_SHARE_TOO_HIGH");
        require(
            _absDiff(eligibleRevenueShareBps, newBps) <= MAX_ELIGIBLE_REVENUE_SHARE_STEP_BPS,
            "ELIGIBLE_SHARE_STEP_TOO_LARGE"
        );

        uint64 eta = uint64(block.timestamp) + ELIGIBLE_REVENUE_SHARE_DELAY;
        pendingEligibleRevenueShareBps = newBps;
        pendingEligibleRevenueShareEta = eta;

        emit EligibleRevenueShareProposed(eligibleRevenueShareBps, newBps, eta);
    }

    function cancelEligibleRevenueShare() external onlyOwner {
        uint16 cancelledBps = pendingEligibleRevenueShareBps;
        require(cancelledBps != 0, "PENDING_SHARE_ZERO");

        pendingEligibleRevenueShareBps = 0;
        pendingEligibleRevenueShareEta = 0;
        eligibleRevenueShareCooldownEnd = uint64(block.timestamp) + ELIGIBLE_REVENUE_SHARE_DELAY;

        emit EligibleRevenueShareCancelled(cancelledBps, eligibleRevenueShareCooldownEnd);
    }

    function activateEligibleRevenueShare() external whenNotPaused onlyActiveSubject nonReentrant {
        uint16 newBps = pendingEligibleRevenueShareBps;
        uint64 eta = pendingEligibleRevenueShareEta;
        require(newBps != 0, "PENDING_SHARE_ZERO");
        require(block.timestamp >= eta, "SHARE_NOT_READY");

        _settleStakeTokenEmissions();

        uint16 previousBps = eligibleRevenueShareBps;
        eligibleRevenueShareBps = newBps;
        pendingEligibleRevenueShareBps = 0;
        pendingEligibleRevenueShareEta = 0;
        eligibleRevenueShareCooldownEnd = uint64(block.timestamp) + ELIGIBLE_REVENUE_SHARE_DELAY;

        emit EligibleRevenueShareActivated(
            previousBps,
            newBps,
            _toUint64(block.timestamp),
            eligibleRevenueShareCooldownEnd
        );
    }

    function setProtocolRecipient(address protocolRecipient_) external onlyOwner {
        require(protocolRecipient_ != address(0), "PROTOCOL_ZERO");
        protocolRecipient = protocolRecipient_;
        emit ProtocolRecipientSet(protocolRecipient_);
    }

    function setEmissionAprBps(uint16 newBps) external onlyOwner {
        require(newBps <= MAX_EMISSION_APR_BPS, "EMISSION_APR_BPS_INVALID");
        _settleStakeTokenEmissions();
        uint16 previousBps = emissionAprBps;
        emissionAprBps = newBps;
        emit EmissionAprBpsSet(previousBps, newBps);
    }

    function setLabel(string calldata label_) external onlyOwner {
        label = label_;
        emit LabelSet(label_);
    }

    // slither-disable-next-line reentrancy-no-eth
    function stake(uint256 amount, address receiver)
        external
        whenNotPaused
        onlyActiveSubject
        nonReentrant
    {
        require(amount != 0, "AMOUNT_ZERO");
        require(receiver != address(0), "RECEIVER_ZERO");

        _sync(receiver);
        require(totalStaked + amount <= revenueShareSupplyDenominator, "STAKE_CAP_EXCEEDED");
        _pullExactStakeToken(msg.sender, amount);

        stakedBalance[receiver] += amount;
        totalStaked += amount;

        emit StakeUpdated(receiver, stakedBalance[receiver], totalStaked);
    }

    function unstake(uint256 amount, address recipient) external nonReentrant {
        require(amount != 0, "AMOUNT_ZERO");
        require(recipient != address(0), "RECIPIENT_ZERO");

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
        _settleStakeTokenEmissions();

        uint256 beforeBalance = IERC20SupplyMinimal(usdc).balanceOf(address(this));
        // slither-disable-next-line reentrancy-benign
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = IERC20SupplyMinimal(usdc).balanceOf(address(this));
        received = afterBalance - beforeBalance;

        _recordRevenue(received, eligibleRevenueShareBps, sourceTag, sourceRef);
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

        _settleStakeTokenEmissions();

        recognized = amount;
        _recordRevenue(amount, eligibleRevenueShareBps, bytes32("ingress_sweep"), sourceRef);
    }

    function pullTreasuryShareFromLaunchVault(
        address vault,
        bytes32 poolId,
        uint256 amount,
        bytes32 sourceRef
    ) external whenNotPaused onlyActiveSubject nonReentrant returns (uint256 received) {
        require(vault != address(0), "VAULT_ZERO");
        require(amount != 0, "AMOUNT_ZERO");
        _settleStakeTokenEmissions();

        uint256 beforeBalance = IERC20SupplyMinimal(usdc).balanceOf(address(this));
        // slither-disable-next-line reentrancy-benign
        ILaunchFeeVaultMinimal(vault).withdrawTreasury(poolId, usdc, amount, address(this));
        uint256 afterBalance = IERC20SupplyMinimal(usdc).balanceOf(address(this));
        received = afterBalance - beforeBalance;

        _recordRevenue(received, eligibleRevenueShareBps, bytes32("launch_treasury"), sourceRef);
    }

    function sync(address account) external whenNotPaused nonReentrant {
        require(account != address(0), "ACCOUNT_ZERO");
        _sync(account);
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

    function previewClaimableStakeToken(address account) public view returns (uint256) {
        uint256 claimable = storedClaimableStakeToken[account];
        uint256 currentAcc = _previewAccRewardPerTokenStakeToken();
        uint256 priorAcc = rewardDebtStakeToken[account];
        if (currentAcc <= priorAcc) {
            return claimable;
        }

        uint256 stakeBal = stakedBalance[account];
        if (stakeBal == 0) {
            return claimable;
        }

        return claimable + FullMath.mulDiv(stakeBal, currentAcc - priorAcc, ACC_PRECISION);
    }

    function claimUSDC(address recipient)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 amount)
    {
        require(recipient != address(0), "RECIPIENT_ZERO");

        _sync(msg.sender);
        amount = storedClaimableUsdc[msg.sender];
        if (amount < 1) {
            return 0;
        }

        storedClaimableUsdc[msg.sender] = 0;
        emit USDCRewardClaimed(msg.sender, amount, recipient);
        usdc.safeTransfer(recipient, amount);
    }

    function claimStakeToken(address recipient)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 amount)
    {
        require(recipient != address(0), "RECIPIENT_ZERO");

        _sync(msg.sender);
        amount = storedClaimableStakeToken[msg.sender];
        if (amount < 1) {
            return 0;
        }
        require(availableStakeTokenRewardInventory() >= amount, "REWARD_INVENTORY_LOW");

        storedClaimableStakeToken[msg.sender] = 0;
        unclaimedStakeTokenLiability -= amount;
        totalClaimedStakeToken += amount;

        emit RewardTokenClaimed(msg.sender, amount, recipient);
        _pushExactStakeToken(recipient, amount);
    }

    function claimAndRestakeStakeToken()
        external
        whenNotPaused
        onlyActiveSubject
        nonReentrant
        returns (uint256 amount)
    {
        _sync(msg.sender);
        amount = storedClaimableStakeToken[msg.sender];
        if (amount < 1) {
            return 0;
        }
        require(availableStakeTokenRewardInventory() >= amount, "REWARD_INVENTORY_LOW");
        require(totalStaked + amount <= revenueShareSupplyDenominator, "STAKE_CAP_EXCEEDED");

        storedClaimableStakeToken[msg.sender] = 0;
        unclaimedStakeTokenLiability -= amount;
        totalClaimedStakeToken += amount;
        stakedBalance[msg.sender] += amount;
        totalStaked += amount;

        emit RewardTokenCompounded(msg.sender, amount, stakedBalance[msg.sender], totalStaked);
        emit StakeUpdated(msg.sender, stakedBalance[msg.sender], totalStaked);
    }

    function sweepTreasuryResidualUSDC(uint256 amount)
        external
        whenNotPaused
        onlyTreasurySweepCaller
        nonReentrant
    {
        require(treasuryResidualUsdc >= amount, "TREASURY_BALANCE_LOW");

        treasuryResidualUsdc -= amount;
        emit USDCTreasuryResidualWithdrawn(amount, treasuryRecipient);
        usdc.safeTransfer(treasuryRecipient, amount);
    }

    function sweepTreasuryReservedUSDC(uint256 amount)
        external
        whenNotPaused
        onlyTreasurySweepCaller
        nonReentrant
    {
        require(treasuryReservedUsdc >= amount, "TREASURY_RESERVED_BALANCE_LOW");

        treasuryReservedUsdc -= amount;
        emit USDCTreasuryReservedWithdrawn(amount, treasuryRecipient);
        usdc.safeTransfer(treasuryRecipient, amount);
    }

    function sweepProtocolReserveUSDC(uint256 amount)
        external
        whenNotPaused
        onlyProtocolSweepCaller
        nonReentrant
    {
        require(protocolReserveUsdc >= amount, "PROTOCOL_BALANCE_LOW");

        protocolReserveUsdc -= amount;
        emit USDCProtocolReserveWithdrawn(amount, protocolRecipient);
        usdc.safeTransfer(protocolRecipient, amount);
    }

    function reassignUndistributedDustToTreasury(uint256 amount) external onlyOwner nonReentrant {
        require(undistributedDustUsdc >= amount, "DUST_BALANCE_LOW");
        undistributedDustUsdc -= amount;
        treasuryResidualUsdc += amount;
        emit USDCDustReassigned(amount, treasuryRecipient);
    }

    function fundStakeTokenRewards(uint256 amount)
        external
        whenNotPaused
        onlyActiveSubject
        nonReentrant
        returns (uint256 received)
    {
        require(amount != 0, "AMOUNT_ZERO");
        _settleStakeTokenEmissions();

        // slither-disable-next-line reentrancy-benign
        received = _pullExactStakeToken(msg.sender, amount);

        totalFundedStakeToken += received;
        emit RewardTokenFunded(msg.sender, received);
    }

    function syncSubjectLifecycle(bool active_, bool retiring_) external onlySubjectRegistry {
        if (retiring_) {
            _settleStakeTokenEmissions();
            subjectLifecycleRetired = true;
            lastEmissionUpdate = block.timestamp;
            return;
        }

        if (!active_) {
            _settleStakeTokenEmissions();
        }
        lastEmissionUpdate = block.timestamp;
    }

    function availableStakeTokenRewardInventory() public view returns (uint256 available) {
        uint256 balance = IERC20SupplyMinimal(stakeToken).balanceOf(address(this));
        if (balance <= totalStaked) {
            return 0;
        }
        unchecked {
            available = balance - totalStaked;
        }
    }

    function stakeTokenRewardShortfall() external view returns (uint256) {
        uint256 liability = unclaimedStakeTokenLiability;
        uint256 available = availableStakeTokenRewardInventory();
        if (liability <= available) {
            return 0;
        }
        unchecked {
            return liability - available;
        }
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == usdc || token == stakeToken;
    }

    function _sync(address account) internal {
        _settleStakeTokenEmissions();

        uint256 currentStakeTokenAcc = accRewardPerTokenStakeToken;
        uint256 priorStakeTokenAcc = rewardDebtStakeToken[account];
        if (currentStakeTokenAcc > priorStakeTokenAcc) {
            uint256 stakeBalStakeToken = stakedBalance[account];
            if (stakeBalStakeToken > 0) {
                uint256 accruedStakeToken = FullMath.mulDiv(
                    stakeBalStakeToken, currentStakeTokenAcc - priorStakeTokenAcc, ACC_PRECISION
                );
                storedClaimableStakeToken[account] += accruedStakeToken;
                unclaimedStakeTokenLiability += accruedStakeToken;
            }
            rewardDebtStakeToken[account] = currentStakeTokenAcc;
        }

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

    function _recordRevenue(
        uint256 received,
        uint16 shareBps,
        bytes32 sourceTag,
        bytes32 sourceRef
    ) internal {
        require(received > 0, "NOTHING_RECEIVED");

        uint256 protocolAmount = 0;
        if (protocolSkimBps > 0) {
            protocolAmount = FullMath.mulDiv(received, protocolSkimBps, BPS_DENOMINATOR);
        }
        uint256 net = received - protocolAmount;
        uint256 treasuryReservedAmount =
            FullMath.mulDiv(net, BPS_DENOMINATOR - shareBps, BPS_DENOMINATOR);
        uint256 stakerEligibleAmount = net - treasuryReservedAmount;

        uint256 deltaAcc = 0;
        if (stakerEligibleAmount > 0) {
            deltaAcc =
                FullMath.mulDiv(stakerEligibleAmount, ACC_PRECISION, revenueShareSupplyDenominator);
        }
        if (deltaAcc > 0) {
            accRewardPerTokenUsdc += deltaAcc;
        }

        uint256 stakerEntitlement = 0;
        if (stakerEligibleAmount > 0 && totalStaked > 0) {
            stakerEntitlement =
                FullMath.mulDiv(stakerEligibleAmount, totalStaked, revenueShareSupplyDenominator);
        }
        uint256 treasuryResidualAmount = stakerEligibleAmount - stakerEntitlement;
        uint256 creditedByAccumulator = 0;
        if (deltaAcc > 0 && totalStaked > 0) {
            creditedByAccumulator = FullMath.mulDiv(deltaAcc, totalStaked, ACC_PRECISION);
        }

        grossInflowUsdc += received;
        regentSkimUsdc += protocolAmount;
        stakerEligibleInflowUsdc += stakerEligibleAmount;
        treasuryReservedInflowUsdc += treasuryReservedAmount;
        treasuryResidualUsdc += treasuryResidualAmount;
        treasuryReservedUsdc += treasuryReservedAmount;
        protocolReserveUsdc += protocolAmount;
        if (stakerEntitlement > creditedByAccumulator) {
            undistributedDustUsdc += stakerEntitlement - creditedByAccumulator;
        }

        emit USDCRevenueDeposited(
            received,
            protocolAmount,
            shareBps,
            stakerEligibleAmount,
            treasuryReservedAmount,
            stakerEntitlement,
            treasuryResidualAmount,
            sourceTag,
            sourceRef
        );
    }

    function _previewAccRewardPerTokenStakeToken() internal view returns (uint256 currentAcc) {
        currentAcc = accRewardPerTokenStakeToken;
        if (!_subjectIsActive() || emissionAprBps == 0 || totalStaked == 0) {
            return currentAcc;
        }

        uint256 elapsed = block.timestamp - lastEmissionUpdate;
        if (elapsed == 0) {
            return currentAcc;
        }

        uint256 deltaAcc = FullMath.mulDiv(
            uint256(emissionAprBps) * elapsed, ACC_PRECISION, BPS_DENOMINATOR * SECONDS_PER_YEAR
        );
        return currentAcc + deltaAcc;
    }

    function _settleStakeTokenEmissions() internal {
        if (subjectLifecycleRetired) {
            return;
        }

        uint256 timestamp = block.timestamp;
        if (timestamp <= lastEmissionUpdate) {
            return;
        }

        if (!_subjectIsActive() || emissionAprBps == 0 || totalStaked == 0) {
            lastEmissionUpdate = timestamp;
            return;
        }

        uint256 elapsed = timestamp - lastEmissionUpdate;
        uint256 deltaAcc = FullMath.mulDiv(
            uint256(emissionAprBps) * elapsed, ACC_PRECISION, BPS_DENOMINATOR * SECONDS_PER_YEAR
        );
        if (deltaAcc == 0) {
            lastEmissionUpdate = timestamp;
            return;
        }

        accRewardPerTokenStakeToken += deltaAcc;
        totalEmittedStakeToken += FullMath.mulDiv(totalStaked, deltaAcc, ACC_PRECISION);
        lastEmissionUpdate = timestamp;
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

    function _absDiff(uint16 left, uint16 right) internal pure returns (uint16) {
        return left >= right ? left - right : right - left;
    }

    function _toUint64(uint256 value) internal pure returns (uint64) {
        require(value <= type(uint64).max, "UINT64_OVERFLOW");
        return uint64(value);
    }

    // slither-disable-next-line reentrancy-balance
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

    // slither-disable-next-line reentrancy-balance
    function _pushExactStakeToken(address recipient, uint256 amount) internal {
        uint256 beforeBalance = IERC20SupplyMinimal(stakeToken).balanceOf(recipient);
        stakeToken.safeTransfer(recipient, amount);
        uint256 afterBalance = IERC20SupplyMinimal(stakeToken).balanceOf(recipient);
        require(afterBalance - beforeBalance == amount, "STAKE_TOKEN_OUT_EXACT");
    }
}
