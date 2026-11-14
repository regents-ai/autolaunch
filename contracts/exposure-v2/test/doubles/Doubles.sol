// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice A stock token with 8 decimals, like the Base stock tokens, plus the issuer's seizure, a
///         transfer pause, a blocklist and a few broken behaviours to prove the series refuses them.
contract MockStock is ERC20 {
    bool public takeFee;
    bool public returnFalse;
    bool public balanceReadFails;
    bool public paused;
    mapping(address => bool) public blocked;
    /// When set, every transfer calls this account back first (a token with hooks).
    address public hook;

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

    function setReturnFalse(bool value) external {
        returnFalse = value;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function setHook(address value) external {
        hook = value;
    }

    function balanceOf(address owner) public view override returns (uint256) {
        if (balanceReadFails) revert("balance unavailable");
        return super.balanceOf(owner);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (returnFalse) return false;
        _beforeTransfer(msg.sender, to);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (returnFalse) return false;
        _beforeTransfer(from, to);
        super.transferFrom(from, to, amount);
        if (takeFee) _burn(to, amount / 100);
        return true;
    }

    function _beforeTransfer(address from, address to) internal {
        require(!paused, "paused");
        require(!blocked[from] && !blocked[to], "blocked");
        if (hook != address(0)) IHook(hook).onTransfer();
    }
}

interface IHook {
    function onTransfer() external;
}

/// @notice A Chainlink aggregator proxy with 8 decimals. Round ids are (phase << 64 | n) like the real
///         proxy; a missing round reads as zeros and a phase with no aggregator reverts, as on Base.
///         `transmit` stamps a round with the block time, as an OCR2 aggregator does. Every phase's
///         aggregator is this contract, so `decimals` answers for the pinned phase too.
contract MockFeed {
    enum Mode {
        Normal,
        Revert,
        ShortReply,
        LongReply,
        BurnGas,
        ReturnBomb
    }

    struct Round {
        int256 answer;
        uint256 updatedAt;
    }

    mapping(uint16 phase => mapping(uint64 round => Round)) internal _rounds;
    mapping(uint16 phase => uint64) public latest;
    mapping(uint16 phase => address) public phaseAggregators;
    uint16 public phaseId = 2;
    Mode public mode;

    constructor() {
        phaseAggregators[2] = address(this);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    /// The proxy moving to a new aggregator.
    function addPhase(uint16 phase) external {
        phaseAggregators[phase] = address(this);
        phaseId = phase;
    }

    /// A new round of `phase` with `answer`, updated now.
    function transmit(uint16 phase, int256 answer) external returns (uint64 round) {
        round = ++latest[phase];
        _rounds[phase][round] = Round(answer, block.timestamp);
    }

    /// Any round at all, for histories a real aggregator cannot produce.
    function setRound(uint16 phase, uint64 round, int256 answer, uint256 updatedAt) external {
        _rounds[phase][round] = Round(answer, updatedAt);
        if (round > latest[phase]) latest[phase] = round;
    }

    function updatedAtOf(uint16 phase, uint64 round) external view returns (uint256) {
        return _rounds[phase][round].updatedAt;
    }

    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 phase = uint16(roundId >> 64);
        if (phaseAggregators[phase] == address(0)) revert("no aggregator for this phase");
        // forge-lint: disable-next-line(unsafe-typecast)
        Round memory r = _rounds[phase][uint64(roundId)];
        Mode m = mode;
        if (m == Mode.Revert) revert("feed down");
        if (m == Mode.ShortReply) {
            assembly {
                mstore(0, 1)
                return(0, 0x40)
            }
        }
        if (m == Mode.LongReply) {
            int256 answer = r.answer;
            uint256 updated = r.updatedAt;
            assembly {
                mstore(0, roundId)
                mstore(0x20, answer)
                mstore(0x40, updated)
                mstore(0x60, updated)
                mstore(0x80, roundId)
                mstore(0xa0, 0)
                return(0, 0xc0)
            }
        }
        if (m == Mode.BurnGas) {
            uint256 x;
            while (gasleft() > 0) x++;
        }
        if (m == Mode.ReturnBomb) {
            assembly {
                return(0, 8000)
            }
        }
        return (roundId, r.answer, r.updatedAt, r.updatedAt, roundId);
    }
}

/// @notice A feed of `count` rounds whose times come from a formula instead of storage, so a history
///         of any length costs nothing to set up. Rounds come in groups of `group` sharing one update
///         time (equal timestamps); group g is updated at `start + g * step + jitter(g)` with jitter
///         below `step`, so times never go backwards. Every answer is 100 dollars plus the round.
contract FormulaFeed {
    uint256 public immutable start;
    uint256 public immutable step;
    uint256 public immutable group;
    uint256 public immutable count;
    uint256 public immutable seed;

    constructor(uint256 start_, uint256 step_, uint256 group_, uint256 count_, uint256 seed_) {
        (start, step, group, count, seed) = (start_, step_, group_, count_, seed_);
    }

    function phaseAggregators(uint16) external view returns (address) {
        return address(this);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    /// The update time of round `round` (rounds start at 1), or zero past the last round.
    function updatedAtOf(uint256 round) public view returns (uint256) {
        if (round == 0 || round > count) return 0;
        return groupTime((round - 1) / group);
    }

    function groupTime(uint256 g) public view returns (uint256) {
        return start + g * step + uint256(keccak256(abi.encode(seed, g))) % step;
    }

    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 round = uint64(roundId);
        uint256 updatedAt = updatedAtOf(round);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 answer = updatedAt == 0 ? int256(0) : int256(100e8 + round);
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}
