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

    address public immutable stakeToken;
    address public immutable usdc;
    uint16 public immutable stakerShareBps;

    address public treasuryRecipient;
    bool public paused;
    uint256 public totalStaked;
    uint256 public accRewardPerTokenUsdc;
    uint256 public treasuryResidualUsdc;
    uint256 public totalRecognizedRewardsUsdc;

    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public rewardDebtUsdc;
    mapping(address => uint256) public storedClaimableUsdc;

    uint256 private _reentrancyGuard = 1;

    event PausedSet(bool paused);
    event TreasuryRecipientSet(address indexed treasuryRecipient);
    event StakeUpdated(address indexed account, uint256 newStakeBalance, uint256 totalStaked);
    event USDCRevenueDeposited(
        uint256 amountReceived,
        uint256 stakerRewardsCredited,
        uint256 treasuryResidualIncrease,
        bytes32 indexed sourceTag,
        bytes32 indexed sourceRef
    );
    event USDCRewardClaimed(address indexed account, uint256 amount, address recipient);
    event TreasuryResidualWithdrawn(uint256 amount, address indexed recipient);

    constructor(
        address stakeToken_,
        address usdc_,
        address treasuryRecipient_,
        uint16 stakerShareBps_,
        address owner_
    ) Owned(owner_) {
        require(stakeToken_ != address(0), "STAKE_TOKEN_ZERO");
        require(usdc_ != address(0), "USDC_ZERO");
        require(treasuryRecipient_ != address(0), "TREASURY_ZERO");
        require(stakerShareBps_ <= BPS_DENOMINATOR, "STAKER_SHARE_BPS_INVALID");

        stakeToken = stakeToken_;
        usdc = usdc_;
        treasuryRecipient = treasuryRecipient_;
        stakerShareBps = stakerShareBps_;
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

    function stake(uint256 amount, address receiver) external whenNotPaused nonReentrant {
        require(amount != 0, "AMOUNT_ZERO");
        require(receiver != address(0), "RECEIVER_ZERO");

        _sync(receiver);

        stakedBalance[receiver] += amount;
        totalStaked += amount;

        stakeToken.safeTransferFrom(msg.sender, address(this), amount);

        emit StakeUpdated(receiver, stakedBalance[receiver], totalStaked);
    }

    function unstake(uint256 amount, address recipient) external whenNotPaused nonReentrant {
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

    function sync(address account) external whenNotPaused nonReentrant {
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

    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 received)
    {
        require(amount != 0, "AMOUNT_ZERO");

        uint256 beforeBalance = IERC20SupplyMinimal(usdc).balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = IERC20SupplyMinimal(usdc).balanceOf(address(this));
        received = afterBalance - beforeBalance;

        _recordRevenue(received, sourceTag, sourceRef);
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

    function _recordRevenue(uint256 received, bytes32 sourceTag, bytes32 sourceRef) internal {
        require(received > 0, "NOTHING_RECEIVED");

        uint256 supply = IERC20SupplyMinimal(stakeToken).totalSupply();
        require(supply > 0, "SUPPLY_ZERO");

        totalRecognizedRewardsUsdc += received;

        uint256 stakerPool = 0;
        if (stakerShareBps > 0) {
            stakerPool = FullMath.mulDiv(received, stakerShareBps, BPS_DENOMINATOR);
        }

        uint256 creditedToStakers = 0;
        if (stakerPool > 0) {
            uint256 deltaAcc = FullMath.mulDiv(stakerPool, ACC_PRECISION, supply);
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
}
