// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice A B20 Asset stand-in with the behaviour covered calls depends on, as measured on Base: 8
///         decimals, a scheduled multiplier change read through `effectiveAt`, a blocklist that
///         reverts a transfer to or from a listed address, and a transfer pause that stops
///         `transfer` and `transferFrom` but not `approve`.
contract B20Double is ERC20 {
    error PolicyForbids(address account);
    error ContractPaused();

    uint256 public effectiveAt;
    bool public transfersPaused;
    mapping(address => bool) public blocked;

    function name() public pure override returns (string memory) {
        return "Amazon";
    }

    function symbol() public pure override returns (string memory) {
        return "AMZNc";
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function schedule(uint256 at) external {
        effectiveAt = at;
    }

    function setPaused(bool paused) external {
        transfersPaused = paused;
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _check(msg.sender, to);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _check(from, to);
        return super.transferFrom(from, to, amount);
    }

    function _check(address from, address to) internal view {
        if (transfersPaused) revert ContractPaused();
        if (blocked[from]) revert PolicyForbids(from);
        if (blocked[to]) revert PolicyForbids(to);
    }
}

/// @notice USDC with Circle FiatToken's restrictions: a blacklist checked on the caller, sender,
///         receiver and spender, and a pause that stops transfer, transferFrom and approve.
contract UsdcDouble is ERC20 {
    error Blacklisted(address account);
    error Paused();

    bool public paused;
    mapping(address => bool) public blacklisted;

    function name() public pure override returns (string memory) {
        return "USD Coin";
    }

    function symbol() public pure override returns (string memory) {
        return "USDC";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function setBlacklisted(address account, bool isBlacklisted) external {
        blacklisted[account] = isBlacklisted;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _check(msg.sender);
        _check(to);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _check(msg.sender);
        _check(from);
        _check(to);
        return super.transferFrom(from, to, amount);
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _check(msg.sender);
        _check(spender);
        return super.approve(spender, amount);
    }

    function _check(address account) internal view {
        if (paused) revert Paused();
        if (blacklisted[account]) revert Blacklisted(account);
    }
}

/// @notice Live REGENT staking's `depositUSDC`: pulls the amount from the caller and records it, or
///         refuses every deposit while switched off (a paused or replaced staking contract).
contract StakingDouble {
    UsdcDouble public immutable usdc;
    bool public refuses;
    uint256 public deposited;
    bytes32 public lastTag;
    bytes32 public lastRef;

    constructor(UsdcDouble usdc_) {
        usdc = usdc_;
    }

    function setRefuses(bool refuses_) external {
        refuses = refuses_;
    }

    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) external returns (uint256) {
        require(!refuses, "staking paused");
        usdc.transferFrom(msg.sender, address(this), amount);
        deposited += amount;
        lastTag = sourceTag;
        lastRef = sourceRef;
        return amount;
    }
}
