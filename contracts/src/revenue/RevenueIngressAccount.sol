// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {SafeTransferLib} from "src/libraries/SafeTransferLib.sol";
import {IERC20SupplyMinimal} from "src/revenue/interfaces/IERC20SupplyMinimal.sol";
import {IRevenueShareSplitter} from "src/revenue/interfaces/IRevenueShareSplitter.sol";
import {InputBounds} from "src/revenue/libraries/InputBounds.sol";

contract RevenueIngressAccount is Owned {
    using SafeTransferLib for address;

    address public immutable usdc;
    address public immutable splitter;
    address public immutable factory;
    bytes32 public immutable subjectId;
    uint256 public constant MAX_ACCOUNTING_TAG_PAGE_SIZE = 100;
    uint256 private _reentrancyGuard = 1;

    string public label;

    struct AccountingTag {
        uint256 blockNumber;
        address depositor;
        uint256 amount;
        bytes32 sourceTag;
    }

    AccountingTag[] private _accountingTags;

    event LabelSet(string label);
    event AccountingTagRecorded(
        uint256 indexed index,
        address indexed depositor,
        uint256 blockNumber,
        uint256 amount,
        bytes32 sourceTag
    );
    event USDCSwept(
        address indexed caller,
        uint256 balanceForwarded,
        uint256 amountRecognized,
        bytes32 indexed sourceRef
    );

    modifier nonReentrant() {
        require(_reentrancyGuard == 1, "REENTRANT");
        _reentrancyGuard = 2;
        _;
        _reentrancyGuard = 1;
    }

    constructor(
        address usdc_,
        address splitter_,
        bytes32 subjectId_,
        string memory label_,
        address owner_
    ) Owned(owner_) {
        require(usdc_ != address(0), "USDC_ZERO");
        require(splitter_ != address(0), "SPLITTER_ZERO");
        require(subjectId_ != bytes32(0), "SUBJECT_ZERO");
        require(IRevenueShareSplitter(splitter_).usdc() == usdc_, "SPLITTER_USDC_MISMATCH");
        InputBounds.requireStringMax(label_, InputBounds.MAX_LABEL_BYTES, "LABEL_TOO_LONG");

        usdc = usdc_;
        splitter = splitter_;
        factory = msg.sender;
        subjectId = subjectId_;
        label = label_;
    }

    function setLabel(string calldata label_) external onlyOwner {
        InputBounds.requireStringMax(label_, InputBounds.MAX_LABEL_BYTES, "LABEL_TOO_LONG");
        label = label_;
        emit LabelSet(label_);
    }

    function depositUSDC(uint256 amount, bytes32 sourceTag)
        external
        nonReentrant
        returns (uint256 received)
    {
        require(amount != 0, "AMOUNT_ZERO");

        uint256 beforeBalance = IERC20SupplyMinimal(usdc).balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = IERC20SupplyMinimal(usdc).balanceOf(address(this));
        received = afterBalance - beforeBalance;
        require(received != 0, "NOTHING_RECEIVED");

        uint256 index = _accountingTags.length;
        _accountingTags.push(
            AccountingTag({
                blockNumber: block.number,
                depositor: msg.sender,
                amount: received,
                sourceTag: sourceTag
            })
        );

        emit AccountingTagRecorded(index, msg.sender, block.number, received, sourceTag);
    }

    function accountingTagCount() external view returns (uint256) {
        return _accountingTags.length;
    }

    function accountingTagAt(uint256 index)
        external
        view
        returns (uint256 blockNumber, address depositor, uint256 amount, bytes32 sourceTag)
    {
        require(index < _accountingTags.length, "TAG_INDEX_OOB");
        AccountingTag memory tag = _accountingTags[index];
        return (tag.blockNumber, tag.depositor, tag.amount, tag.sourceTag);
    }

    function accountingTagsSinceBlock(uint256 fromBlock, uint256 cursor, uint256 limit)
        external
        view
        returns (AccountingTag[] memory tags, uint256 nextCursor, bool hasMore)
    {
        require(limit != 0, "LIMIT_ZERO");
        require(limit <= MAX_ACCOUNTING_TAG_PAGE_SIZE, "LIMIT_TOO_HIGH");
        uint256 length = _accountingTags.length;
        require(cursor <= length, "CURSOR_OOB");

        uint256 count = 0;
        uint256 i = cursor;
        for (; i < length && count < limit; ++i) {
            if (_accountingTags[i].blockNumber >= fromBlock) {
                ++count;
            }
        }

        nextCursor = i;
        hasMore = nextCursor < length;
        tags = new AccountingTag[](count);

        uint256 outputIndex = 0;
        for (uint256 readIndex = cursor; readIndex < nextCursor; ++readIndex) {
            AccountingTag memory tag = _accountingTags[readIndex];
            if (tag.blockNumber >= fromBlock) {
                tags[outputIndex] = tag;
                ++outputIndex;
            }
        }
    }

    function sweepUSDC()
        external
        nonReentrant
        returns (uint256 balance, uint256 recognized, bytes32 sourceRef)
    {
        balance = IERC20SupplyMinimal(usdc).balanceOf(address(this));
        require(balance != 0, "NOTHING_TO_SWEEP");
        sourceRef =
            keccak256(abi.encode(block.chainid, subjectId, address(this), block.number, balance));

        usdc.safeTransfer(splitter, balance);
        recognized = IRevenueShareSplitter(splitter).recordIngressSweep(balance, sourceRef);

        emit USDCSwept(msg.sender, balance, recognized, sourceRef);
    }

    receive() external payable {
        revert("ETH_NOT_ACCEPTED");
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == usdc;
    }
}
