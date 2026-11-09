// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @notice Version 2's issuance schedule (`contracts/stocks-v2/src/StocksPreset.sol`), kept only as the
///         reference version 3 is proved against, and the arithmetic of a packed CCA schedule.
library V2Schedule {
    bytes internal constant AUCTION_STEPS = hex"00006c0000001545" hex"00008800000010a2" hex"0000960000000f3e"
        hex"00009e0000000e66" hex"0000a60000000dce" hex"0000aa0000000d5a" hex"0000b00000000cfc" hex"0000b40000000cad"
        hex"0000b80000000c6a" hex"0000bc0000000c2f" hex"0000be0000000bfc" hex"0000c20000000bce" hex"2d97f80000000001";

    uint64 internal constant AUCTION_DURATION_BLOCKS = 43_200;

    /// @dev One packed `uint24 mps | uint40 blockDelta` step.
    function step(bytes memory steps, uint256 offset) internal pure returns (uint24 mps, uint40 blockDelta) {
        assembly ("memory-safe") {
            let word := mload(add(add(steps, 0x20), offset))
            mps := shr(232, word)
            blockDelta := and(shr(192, word), 0xffffffffff)
        }
    }

    /// @dev The mps a schedule has released `blocks` blocks after its start, linear within each step,
    ///      as the pinned CCA's checkpoints count it.
    function released(bytes memory steps, uint256 blocks) internal pure returns (uint256 total) {
        uint256 at;
        for (uint256 i; i < steps.length && at < blocks; i += 8) {
            (uint24 mps, uint40 blockDelta) = step(steps, i);
            uint256 taken = blocks - at < blockDelta ? blocks - at : blockDelta;
            total += uint256(mps) * taken;
            at += blockDelta;
        }
    }

    /// @dev The widest difference between version 2 after `t` blocks and `tenfold` after `10 t` blocks,
    ///      over every `t` of version 2's auction, walked one version 2 block at a time.
    function widestGap(bytes memory tenfold) internal pure returns (uint256 widest) {
        Cursor memory old = Cursor(AUCTION_STEPS, 0, 0, 0);
        Cursor memory current = Cursor(tenfold, 0, 0, 0);
        for (uint256 t; t < AUCTION_DURATION_BLOCKS; ++t) {
            _advance(old);
            for (uint256 k; k < 10; ++k) {
                _advance(current);
            }
            uint256 gap = old.total > current.total ? old.total - current.total : current.total - old.total;
            if (gap > widest) widest = gap;
        }
    }

    struct Cursor {
        bytes steps;
        uint256 offset;
        uint256 used;
        uint256 total;
    }

    /// @dev One block of the schedule; past its end a schedule releases nothing more.
    function _advance(Cursor memory cursor) private pure {
        if (cursor.offset == cursor.steps.length) return;
        (uint24 mps, uint40 blockDelta) = step(cursor.steps, cursor.offset);
        cursor.total += mps;
        if (++cursor.used == blockDelta) {
            cursor.offset += 8;
            cursor.used = 0;
        }
    }
}
