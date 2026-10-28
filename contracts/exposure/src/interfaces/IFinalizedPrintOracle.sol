// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IFinalizedPrintOracle
/// @notice Opening and closing prints for a stock, each the USD value of one whole raw stock token
///         (the equity price times the token's multiplier at that moment), as an 18-decimal number.
///         A print is final once `finalizedAt` is set and never changes after.
interface IFinalizedPrintOracle {
    struct Print {
        /// USD per whole raw token, 18 decimals. Zero when there is no final print.
        uint128 priceWad;
        /// The scheduled open or close this print is for.
        uint64 observedAt;
        /// When the print was recorded on chain, set by the oracle from the block time.
        uint64 finalizedAt;
    }

    /// @notice The final print for `feedId` at the scheduled open (`isOpen`) or close
    ///         `scheduledAt`, or all zeros when there is none yet. Exactly three ABI words.
    function getPrint(bytes32 feedId, uint64 scheduledAt, bool isOpen) external view returns (Print memory);
}
