// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract MockUsdc {
    enum Fault {
        NONE,
        BALANCE_READ,
        ALLOWANCE_READ,
        APPROVE_NONZERO_REVERT,
        APPROVE_ZERO_REVERT,
        APPROVE_FALSE,
        APPROVE_NO_EFFECT,
        TRANSFER_FROM_REVERT
    }

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    Fault public fault;

    function setFault(Fault fault_) external {
        fault = fault_;
    }

    function mint(address account, uint256 amount) external {
        _balances[account] += amount;
    }

    function balanceOf(address account) external view returns (uint256) {
        if (fault == Fault.BALANCE_READ) revert("BALANCE_READ");
        return _balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        if (fault == Fault.ALLOWANCE_READ) revert("ALLOWANCE_READ");
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (fault == Fault.APPROVE_NONZERO_REVERT && amount != 0) revert("APPROVE_NONZERO");
        if (fault == Fault.APPROVE_ZERO_REVERT && amount == 0) revert("APPROVE_ZERO");
        if (fault == Fault.APPROVE_FALSE) return false;
        if (fault == Fault.APPROVE_NO_EFFECT) return true;
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (fault == Fault.TRANSFER_FROM_REVERT) revert("TRANSFER_FROM");
        uint256 allowed = _allowances[from][msg.sender];
        require(allowed >= amount, "ALLOWANCE");
        require(_balances[from] >= amount, "BALANCE");
        _allowances[from][msg.sender] = allowed - amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }

    function rawBalanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function rawAllowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }
}
