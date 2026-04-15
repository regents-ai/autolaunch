// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract TransferFeeERC20Mock {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    uint16 public feeBps;
    address public feeCollector;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public feeOnSender;
    mapping(address => bool) public feeOnRecipient;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address feeCollector_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
        feeCollector = feeCollector_;
    }

    function setFeeBps(uint16 feeBps_) external {
        require(feeBps_ <= 10_000, "FEE_BPS_INVALID");
        feeBps = feeBps_;
    }

    function setFeeTriggers(address account, bool chargeSender, bool chargeRecipient) external {
        feeOnSender[account] = chargeSender;
        feeOnRecipient[account] = chargeRecipient;
    }

    function mint(address to, uint256 amount) external {
        require(to != address(0), "TO_ZERO");
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ALLOWANCE_LOW");

        if (allowed != type(uint256).max) {
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }

        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "TO_ZERO");
        uint256 fromBalance = balanceOf[from];
        require(fromBalance >= amount, "BALANCE_LOW");

        unchecked {
            balanceOf[from] = fromBalance - amount;
        }

        uint256 fee = 0;
        if (feeBps > 0 && (feeOnSender[from] || feeOnRecipient[to])) {
            fee = (amount * feeBps) / 10_000;
        }

        uint256 received = amount - fee;
        balanceOf[to] += received;
        emit Transfer(from, to, received);

        if (fee > 0) {
            if (feeCollector == address(0)) {
                totalSupply -= fee;
                emit Transfer(from, address(0), fee);
            } else {
                balanceOf[feeCollector] += fee;
                emit Transfer(from, feeCollector, fee);
            }
        }
    }
}
