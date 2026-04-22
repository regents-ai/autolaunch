// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {SafeTransferLib} from "src/libraries/SafeTransferLib.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC20SupplyMinimal} from "src/revenue/interfaces/IERC20SupplyMinimal.sol";

contract RegentRevenueStaking is Owned {
    using SafeTransferLib for address;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant ACC_PRECISION = 1e27;
    uint256 public constant MAX_EMISSION_APR_BPS = 2000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    address public immutable stakeToken;
    address public immutable usdc;
    uint256 public immutable revenueShareSupplyDenominator;

    address public treasuryRecipient;
    bool public paused;
    uint256 public totalStaked;
    uint256 public accRewardPerTokenUsdc;
    uint256 public accRewardPerTokenRegent;
    uint16 public emissionAprBps;
    uint256 public lastEmissionUpdate;
    uint256 public treasuryResidualUsdc;
    uint256 public totalRecognizedRewardsUsdc;
    uint256 public unclaimedRegentLiability;
    uint256 public totalEmittedRegent;
    uint256 public totalFundedRegent;
    uint256 public totalClaimedRegent;

    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public rewardDebtUsdc;
    mapping(address => uint256) public storedClaimableUsdc;
    mapping(address => uint256) public rewardDebtRegent;
    mapping(address => uint256) public storedClaimableRegent;

    uint256 private _reentrancyGuard = 1;

    event PausedSet(bool paused);
    event TreasuryRecipientSet(address indexed treasuryRecipient);
    event EmissionAprBpsSet(uint16 previousBps, uint16 newBps);
    event StakeUpdated(address indexed account, uint256 newStakeBalance, uint256 totalStaked);
    event USDCRevenueDeposited(
        uint256 amountReceived,
        uint256 stakerRewardsCredited,
        uint256 treasuryResidualIncrease,
        bytes32 indexed sourceTag,
        bytes32 indexed sourceRef
    );
    event USDCRewardClaimed(address indexed account, uint256 amount, address recipient);
    event RewardTokenFunded(address indexed caller, uint256 amountReceived);
    event RewardTokenClaimed(address indexed account, uint256 amount, address recipient);
    event RewardTokenCompounded(
        address indexed account, uint256 amount, uint256 newStakeBalance, uint256 totalStaked
    );
    event TreasuryResidualWithdrawn(uint256 amount, address indexed recipient);

    constructor(
        address stakeToken_,
        address usdc_,
        address treasuryRecipient_,
        uint256 revenueShareSupplyDenominator_,
        address owner_
    ) Owned(owner_) {
        require(stakeToken_ != address(0), "STAKE_TOKEN_ZERO");
        require(usdc_ != address(0), "USDC_ZERO");
        require(treasuryRecipient_ != address(0), "TREASURY_ZERO");
        require(revenueShareSupplyDenominator_ != 0, "SUPPLY_DENOMINATOR_ZERO");

        stakeToken = stakeToken_;
        usdc = usdc_;
        treasuryRecipient = treasuryRecipient_;
        revenueShareSupplyDenominator = revenueShareSupplyDenominator_;
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

    function setEmissionAprBps(uint16 newBps) external onlyOwner {
        require(newBps <= MAX_EMISSION_APR_BPS, "EMISSION_APR_BPS_INVALID");
        _settleRegentEmissions();
        uint16 previousBps = emissionAprBps;
        emissionAprBps = newBps;
        emit EmissionAprBpsSet(previousBps, newBps);
    }

    function stake(uint256 amount, address receiver) external whenNotPaused nonReentrant {
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

    function sync(address account) external nonReentrant {
        require(account != address(0), "ACCOUNT_ZERO");
        _sync(account);
    }

    function previewClaimableUSDC(address account) public view returns (uint256) {
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

    function previewClaimableRegent(address account) public view returns (uint256) {
        uint256 claimable = storedClaimableRegent[account];
        uint256 currentAcc = _previewAccRewardPerTokenRegent();
        uint256 priorAcc = rewardDebtRegent[account];
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

    function claimRegent(address recipient)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 amount)
    {
        require(recipient != address(0), "RECIPIENT_ZERO");

        _sync(msg.sender);
        amount = storedClaimableRegent[msg.sender];
        if (amount < 1) {
            return 0;
        }
        require(availableRegentRewardInventory() >= amount, "REWARD_INVENTORY_LOW");

        storedClaimableRegent[msg.sender] = 0;
        unclaimedRegentLiability -= amount;
        totalClaimedRegent += amount;

        emit RewardTokenClaimed(msg.sender, amount, recipient);
        _pushExactStakeToken(recipient, amount);
    }

    function claimAndRestakeRegent() external whenNotPaused nonReentrant returns (uint256 amount) {
        _sync(msg.sender);
        amount = storedClaimableRegent[msg.sender];
        if (amount < 1) {
            return 0;
        }
        require(availableRegentRewardInventory() >= amount, "REWARD_INVENTORY_LOW");
        require(totalStaked + amount <= revenueShareSupplyDenominator, "STAKE_CAP_EXCEEDED");

        storedClaimableRegent[msg.sender] = 0;
        unclaimedRegentLiability -= amount;
        totalClaimedRegent += amount;
        stakedBalance[msg.sender] += amount;
        totalStaked += amount;

        emit RewardTokenCompounded(msg.sender, amount, stakedBalance[msg.sender], totalStaked);
        emit StakeUpdated(msg.sender, stakedBalance[msg.sender], totalStaked);
    }

    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 received)
    {
        require(amount != 0, "AMOUNT_ZERO");
        _settleRegentEmissions();

        uint256 beforeBalance = IERC20SupplyMinimal(usdc).balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = IERC20SupplyMinimal(usdc).balanceOf(address(this));
        received = afterBalance - beforeBalance;

        _recordRevenue(received, sourceTag, sourceRef);
    }

    function fundRegentRewards(uint256 amount)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 received)
    {
        require(amount != 0, "AMOUNT_ZERO");
        _settleRegentEmissions();

        received = _pullExactStakeToken(msg.sender, amount);

        totalFundedRegent += received;
        emit RewardTokenFunded(msg.sender, received);
    }

    function withdrawTreasuryResidual(uint256 amount, address recipient)
        external
        whenNotPaused
        nonReentrant
    {
        require(msg.sender == treasuryRecipient || msg.sender == owner, "ONLY_TREASURY");
        require(recipient != address(0), "RECIPIENT_ZERO");
        require(treasuryResidualUsdc >= amount, "TREASURY_BALANCE_LOW");

        treasuryResidualUsdc -= amount;
        emit TreasuryResidualWithdrawn(amount, recipient);
        usdc.safeTransfer(recipient, amount);
    }

    function availableRegentRewardInventory() public view returns (uint256 available) {
        uint256 balance = IERC20SupplyMinimal(stakeToken).balanceOf(address(this));
        if (balance <= totalStaked) {
            return 0;
        }
        unchecked {
            available = balance - totalStaked;
        }
    }

    function regentRewardShortfall() external view returns (uint256) {
        uint256 liability = unclaimedRegentLiability;
        uint256 available = availableRegentRewardInventory();
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
        _settleRegentEmissions();

        uint256 currentAccRegent = accRewardPerTokenRegent;
        uint256 priorAccRegent = rewardDebtRegent[account];
        if (currentAccRegent > priorAccRegent) {
            uint256 stakeBalRegent = stakedBalance[account];
            if (stakeBalRegent > 0) {
                uint256 accruedRegent = FullMath.mulDiv(
                    stakeBalRegent, currentAccRegent - priorAccRegent, ACC_PRECISION
                );
                storedClaimableRegent[account] += accruedRegent;
                unclaimedRegentLiability += accruedRegent;
            }
            rewardDebtRegent[account] = currentAccRegent;
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

        totalRecognizedRewardsUsdc += received;

        uint256 stakerPool = received;

        uint256 creditedToStakers = 0;
        if (stakerPool > 0) {
            uint256 deltaAcc =
                FullMath.mulDiv(stakerPool, ACC_PRECISION, revenueShareSupplyDenominator);
            if (deltaAcc > 0) {
                accRewardPerTokenUsdc += deltaAcc;

                if (totalStaked > 0) {
                    creditedToStakers = FullMath.mulDiv(deltaAcc, totalStaked, ACC_PRECISION);
                }
            }
        }

        uint256 treasuryIncrease = received - creditedToStakers;
        treasuryResidualUsdc += treasuryIncrease;

        emit USDCRevenueDeposited(
            received, creditedToStakers, treasuryIncrease, sourceTag, sourceRef
        );
    }

    function _previewAccRewardPerTokenRegent() internal view returns (uint256 currentAcc) {
        currentAcc = accRewardPerTokenRegent;
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

    function _settleRegentEmissions() internal {
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

        accRewardPerTokenRegent += deltaAcc;
        totalEmittedRegent += FullMath.mulDiv(totalStaked, deltaAcc, ACC_PRECISION);
        lastEmissionUpdate = timestamp;
    }

    function _pullExactStakeToken(address from, uint256 amount) internal returns (uint256 received) {
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
}
