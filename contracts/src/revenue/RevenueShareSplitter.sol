// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {SafeTransferLib} from "src/libraries/SafeTransferLib.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC20SupplyMinimal} from "src/revenue/interfaces/IERC20SupplyMinimal.sol";
import {ILaunchFeeVaultMinimal} from "src/revenue/interfaces/ILaunchFeeVaultMinimal.sol";
import {IRevenueShareSplitter} from "src/revenue/interfaces/IRevenueShareSplitter.sol";

contract RevenueShareSplitter is Owned, IRevenueShareSplitter {
    using SafeTransferLib for address;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant ACC_PRECISION = 1e27;
    uint256 public constant MAX_EMISSION_APR_BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    address public immutable override stakeToken;
    address public immutable override usdc;
    uint256 public immutable revenueShareSupplyDenominator;

    string public label;

    address public override treasuryRecipient;
    address public override protocolRecipient;
    uint16 public protocolSkimBps;
    uint16 public emissionAprBps;

    bool public paused;
    uint256 public override totalStaked;
    uint256 public accRewardPerTokenUsdc;
    uint256 public accRewardPerTokenStakeToken;
    uint256 public lastEmissionUpdate;
    uint256 public treasuryResidualUsdc;
    uint256 public protocolReserveUsdc;
    uint256 public undistributedDustUsdc;
    uint256 public unclaimedStakeTokenLiability;
    uint256 public totalEmittedStakeToken;
    uint256 public totalFundedStakeToken;
    uint256 public totalClaimedStakeToken;

    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public rewardDebtUsdc;
    mapping(address => uint256) public storedClaimableUsdc;
    mapping(address => uint256) public rewardDebtStakeToken;
    mapping(address => uint256) public storedClaimableStakeToken;

    uint256 private _reentrancyGuard = 1;

    event PausedSet(bool paused);
    event TreasuryRecipientSet(address indexed treasuryRecipient);
    event ProtocolRecipientSet(address indexed protocolRecipient);
    event ProtocolSkimBpsSet(uint16 skimBps);
    event EmissionAprBpsSet(uint16 previousBps, uint16 newBps);
    event LabelSet(string label);
    event StakeUpdated(address indexed account, uint256 newStakeBalance, uint256 totalStaked);
    event USDCRevenueDeposited(
        uint256 amountReceived,
        uint256 protocolAmount,
        uint256 stakerEntitlement,
        uint256 treasuryPortion,
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
    event USDCProtocolReserveWithdrawn(uint256 amount, address indexed recipient);
    event USDCDustReassigned(uint256 amount, address indexed recipient);

    constructor(
        address stakeToken_,
        address usdc_,
        address treasuryRecipient_,
        address protocolRecipient_,
        uint16 protocolSkimBps_,
        uint256 revenueShareSupplyDenominator_,
        string memory label_,
        address owner_
    ) Owned(owner_) {
        require(stakeToken_ != address(0), "STAKE_TOKEN_ZERO");
        require(usdc_ != address(0), "USDC_ZERO");
        require(treasuryRecipient_ != address(0), "TREASURY_ZERO");
        require(protocolRecipient_ != address(0), "PROTOCOL_ZERO");
        require(protocolSkimBps_ <= BPS_DENOMINATOR, "SKIM_BPS_INVALID");
        require(revenueShareSupplyDenominator_ != 0, "SUPPLY_DENOMINATOR_ZERO");

        stakeToken = stakeToken_;
        usdc = usdc_;
        revenueShareSupplyDenominator = revenueShareSupplyDenominator_;
        treasuryRecipient = treasuryRecipient_;
        protocolRecipient = protocolRecipient_;
        protocolSkimBps = protocolSkimBps_;
        label = label_;
        lastEmissionUpdate = block.timestamp;
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

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setTreasuryRecipient(address treasuryRecipient_) external onlyOwner {
        require(treasuryRecipient_ != address(0), "TREASURY_ZERO");
        treasuryRecipient = treasuryRecipient_;
        emit TreasuryRecipientSet(treasuryRecipient_);
    }

    function setProtocolRecipient(address protocolRecipient_) external onlyOwner {
        require(protocolRecipient_ != address(0), "PROTOCOL_ZERO");
        protocolRecipient = protocolRecipient_;
        emit ProtocolRecipientSet(protocolRecipient_);
    }

    function setProtocolSkimBps(uint16 protocolSkimBps_) external onlyOwner {
        require(protocolSkimBps_ <= BPS_DENOMINATOR, "SKIM_BPS_INVALID");
        protocolSkimBps = protocolSkimBps_;
        emit ProtocolSkimBpsSet(protocolSkimBps_);
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

    function stake(uint256 amount, address receiver) external whenNotPaused nonReentrant {
        require(amount != 0, "AMOUNT_ZERO");
        require(receiver != address(0), "RECEIVER_ZERO");

        _sync(receiver);

        stakedBalance[receiver] += amount;
        totalStaked += amount;

        stakeToken.safeTransferFrom(msg.sender, address(this), amount);

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
        stakeToken.safeTransfer(recipient, amount);
    }

    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef)
        external
        override
        whenNotPaused
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

        _recordRevenue(received, sourceTag, sourceRef);
    }

    function pullTreasuryShareFromLaunchVault(
        address vault,
        bytes32 poolId,
        uint256 amount,
        bytes32 sourceRef
    ) external whenNotPaused nonReentrant returns (uint256 received) {
        require(vault != address(0), "VAULT_ZERO");
        require(amount != 0, "AMOUNT_ZERO");
        _settleStakeTokenEmissions();

        uint256 beforeBalance = IERC20SupplyMinimal(usdc).balanceOf(address(this));
        // slither-disable-next-line reentrancy-benign
        ILaunchFeeVaultMinimal(vault).withdrawTreasury(poolId, usdc, amount, address(this));
        uint256 afterBalance = IERC20SupplyMinimal(usdc).balanceOf(address(this));
        received = afterBalance - beforeBalance;

        _recordRevenue(received, bytes32("launch_treasury"), sourceRef);
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
        stakeToken.safeTransfer(recipient, amount);
    }

    function claimAndRestakeStakeToken()
        external
        whenNotPaused
        nonReentrant
        returns (uint256 amount)
    {
        _sync(msg.sender);
        amount = storedClaimableStakeToken[msg.sender];
        if (amount < 1) {
            return 0;
        }
        require(availableStakeTokenRewardInventory() >= amount, "REWARD_INVENTORY_LOW");

        storedClaimableStakeToken[msg.sender] = 0;
        unclaimedStakeTokenLiability -= amount;
        totalClaimedStakeToken += amount;
        stakedBalance[msg.sender] += amount;
        totalStaked += amount;

        emit RewardTokenCompounded(msg.sender, amount, stakedBalance[msg.sender], totalStaked);
        emit StakeUpdated(msg.sender, stakedBalance[msg.sender], totalStaked);
    }

    function withdrawTreasuryResidualUSDC(uint256 amount, address recipient)
        external
        whenNotPaused
        nonReentrant
    {
        require(msg.sender == treasuryRecipient || msg.sender == owner, "ONLY_TREASURY");
        require(recipient != address(0), "RECIPIENT_ZERO");
        require(treasuryResidualUsdc >= amount, "TREASURY_BALANCE_LOW");

        treasuryResidualUsdc -= amount;
        emit USDCTreasuryResidualWithdrawn(amount, recipient);
        usdc.safeTransfer(recipient, amount);
    }

    function withdrawProtocolReserveUSDC(uint256 amount, address recipient)
        external
        whenNotPaused
        nonReentrant
    {
        _withdrawProtocolReserveUsdc(amount, recipient);
    }

    function withdrawProtocolReserve(address rewardToken, uint256 amount, address recipient)
        external
        whenNotPaused
        nonReentrant
    {
        require(rewardToken == usdc, "REWARD_TOKEN_INVALID");
        _withdrawProtocolReserveUsdc(amount, recipient);
    }

    function _withdrawProtocolReserveUsdc(uint256 amount, address recipient) internal {
        require(msg.sender == protocolRecipient || msg.sender == owner, "ONLY_PROTOCOL");
        require(recipient != address(0), "RECIPIENT_ZERO");
        require(protocolReserveUsdc >= amount, "PROTOCOL_BALANCE_LOW");

        protocolReserveUsdc -= amount;
        emit USDCProtocolReserveWithdrawn(amount, recipient);
        usdc.safeTransfer(recipient, amount);
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
        nonReentrant
        returns (uint256 received)
    {
        require(amount != 0, "AMOUNT_ZERO");
        _settleStakeTokenEmissions();

        uint256 beforeBalance = IERC20SupplyMinimal(stakeToken).balanceOf(address(this));
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = IERC20SupplyMinimal(stakeToken).balanceOf(address(this));
        received = afterBalance - beforeBalance;
        require(received > 0, "NOTHING_RECEIVED");

        totalFundedStakeToken += received;
        emit RewardTokenFunded(msg.sender, received);
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

    function _recordRevenue(uint256 received, bytes32 sourceTag, bytes32 sourceRef) internal {
        require(received > 0, "NOTHING_RECEIVED");

        uint256 protocolAmount = 0;
        if (protocolSkimBps > 0) {
            protocolAmount = FullMath.mulDiv(received, protocolSkimBps, BPS_DENOMINATOR);
        }
        uint256 net = received - protocolAmount;

        uint256 deltaAcc = 0;
        if (net > 0) {
            deltaAcc = FullMath.mulDiv(net, ACC_PRECISION, revenueShareSupplyDenominator);
        }
        if (deltaAcc > 0) {
            accRewardPerTokenUsdc += deltaAcc;
        }

        uint256 stakerEntitlement = 0;
        if (net > 0 && totalStaked > 0) {
            stakerEntitlement = FullMath.mulDiv(net, totalStaked, revenueShareSupplyDenominator);
        }
        uint256 treasuryPortion = net - stakerEntitlement;
        uint256 creditedByAccumulator = 0;
        if (deltaAcc > 0 && totalStaked > 0) {
            creditedByAccumulator = FullMath.mulDiv(deltaAcc, totalStaked, ACC_PRECISION);
        }

        treasuryResidualUsdc += treasuryPortion;
        protocolReserveUsdc += protocolAmount;
        if (stakerEntitlement > creditedByAccumulator) {
            undistributedDustUsdc += stakerEntitlement - creditedByAccumulator;
        }

        emit USDCRevenueDeposited(
            received, protocolAmount, stakerEntitlement, treasuryPortion, sourceTag, sourceRef
        );
    }

    function _previewAccRewardPerTokenStakeToken() internal view returns (uint256 currentAcc) {
        currentAcc = accRewardPerTokenStakeToken;
        if (emissionAprBps == 0 || totalStaked == 0) {
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
        uint256 timestamp = block.timestamp;
        if (timestamp <= lastEmissionUpdate) {
            return;
        }

        if (emissionAprBps == 0 || totalStaked == 0) {
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
}
