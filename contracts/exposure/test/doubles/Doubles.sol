// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

import {IFinalizedPrintOracle} from "../../src/interfaces/IFinalizedPrintOracle.sol";

/// @notice A stock token with 8 decimals, like the Base stock tokens, plus the issuer's seizure and a
///         few broken behaviours to prove the series refuses them.
contract MockStock is ERC20 {
    bool public takeFee;
    bool public returnFalse;
    bool public balanceReadFails;

    function name() public pure override returns (string memory) {
        return "Mock Stock";
    }

    function symbol() public pure override returns (string memory) {
        return "MOCKc";
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice What an issuer's seizure looks like from the series: its balance drops.
    function seize(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setTakeFee(bool value) external {
        takeFee = value;
    }

    function setBalanceReadFails(bool value) external {
        balanceReadFails = value;
    }

    function balanceOf(address owner) public view override returns (uint256) {
        if (balanceReadFails) revert("balance unavailable");
        return super.balanceOf(owner);
    }

    function setReturnFalse(bool value) external {
        returnFalse = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (returnFalse) return false;
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (returnFalse) return false;
        super.transferFrom(from, to, amount);
        if (takeFee) _burn(to, amount / 100);
        return true;
    }
}

/// @notice An oracle whose prints the test writes directly, and which can misbehave on demand.
contract MockPrintOracle is IFinalizedPrintOracle {
    enum Mode {
        Normal,
        Revert,
        ShortReply,
        LongReply,
        DirtyPrice,
        BurnGas,
        ReturnBomb
    }

    Mode public mode;
    mapping(bytes32 key => Print) internal _prints;

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function set(bytes32 feedId, uint64 scheduledAt, bool isOpen, uint128 priceWad, uint64 finalizedAt) external {
        _prints[keccak256(abi.encode(feedId, scheduledAt, isOpen))] =
            Print({priceWad: priceWad, observedAt: scheduledAt, finalizedAt: finalizedAt});
    }

    function setRaw(bytes32 feedId, uint64 scheduledAt, bool isOpen, Print calldata print) external {
        _prints[keccak256(abi.encode(feedId, scheduledAt, isOpen))] = print;
    }

    function getPrint(bytes32 feedId, uint64 scheduledAt, bool isOpen) external view returns (Print memory p) {
        p = _prints[keccak256(abi.encode(feedId, scheduledAt, isOpen))];
        Mode m = mode;
        if (m == Mode.Normal) return p;
        if (m == Mode.Revert) revert("oracle down");
        if (m == Mode.ShortReply) {
            assembly {
                mstore(0, 1)
                return(0, 0x40)
            }
        }
        if (m == Mode.LongReply) {
            uint256 price = p.priceWad;
            uint256 observed = p.observedAt;
            uint256 finalized = p.finalizedAt;
            assembly {
                mstore(0, price)
                mstore(0x20, observed)
                mstore(0x40, finalized)
                mstore(0x60, 0)
                return(0, 0x80)
            }
        }
        if (m == Mode.DirtyPrice) {
            uint256 dirty = uint256(p.priceWad) | (1 << 200);
            uint256 observed = p.observedAt;
            uint256 finalized = p.finalizedAt;
            assembly {
                mstore(0, dirty)
                mstore(0x20, observed)
                mstore(0x40, finalized)
                return(0, 0x60)
            }
        }
        if (m == Mode.BurnGas) {
            uint256 x;
            while (gasleft() > 0) x++;
        }
        // ReturnBomb: a reply far larger than three words, which the reader must not copy.
        assembly {
            return(0, 8000)
        }
    }
}

/// @notice A Chainlink aggregator proxy with 8 decimals whose rounds the test writes. Round ids are
///         (phase << 64 | n) like the real proxy; a missing round reverts like an OCR2 aggregator.
contract MockAggregator {
    struct Round {
        int256 answer;
        uint256 updatedAt;
    }

    mapping(uint80 roundId => Round) public rounds;
    uint80 public latest;

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function push(uint80 roundId, int256 answer, uint256 updatedAt) external {
        rounds[roundId] = Round(answer, updatedAt);
        latest = roundId;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[latest];
        return (latest, r.answer, r.updatedAt, r.updatedAt, latest);
    }

    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[roundId];
        require(r.updatedAt != 0, "No data present");
        return (roundId, r.answer, r.updatedAt, r.updatedAt, roundId);
    }
}
