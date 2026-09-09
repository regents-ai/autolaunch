// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title FixtureStockCatalog
/// @notice The thirteen Base-native stock token addresses (chain 8453) the local fork lab installs
///         `FixtureStockToken` at, with display symbols and a fixed lab USDC price per whole share.
/// @dev LAB ONLY. The real tokens carry `0xef` runtime code that Anvil cannot execute, so the lab
///      replaces their code. Nothing tested against these fixtures is B20-verified: issuer transfer
///      policy, Permit2 compatibility and the real acquisition route remain open admission blockers.
///      Identity is the exact address; symbols and prices are display and fixture data only.
library FixtureStockCatalog {
    struct Entry {
        address stock;
        string symbol;
        /// @dev USDC base units (6 decimals) per one whole share (1e8 base units). Fixture pricing.
        uint256 usdcPerShare;
    }

    uint256 internal constant COUNT = 13;
    uint8 internal constant DECIMALS = 8;

    function entries() internal pure returns (Entry[COUNT] memory list) {
        list[0] = Entry({stock: 0xb200000000000000000000C2e324d24d7eEcd1fb, symbol: "AAPLc", usdcPerShare: 230_000000});
        list[1] = Entry({stock: 0xb200000000000000000000d9192b6B456483C2E8, symbol: "AMZNc", usdcPerShare: 220_000000});
        list[2] = Entry({stock: 0xb200000000000000000000c85a31389D71F3ecfb, symbol: "COINc", usdcPerShare: 300_000000});
        list[3] = Entry({stock: 0xB20000000000000000000019f6E7C675b73C2e4D, symbol: "CRCLc", usdcPerShare: 150_000000});
        list[4] = Entry({stock: 0xb2000000000000000000002D0BA3164cc74f58B7, symbol: "GOOGLc", usdcPerShare: 180_000000});
        list[5] = Entry({stock: 0xB2000000000000000000004AFF16039bA04bdFBc, symbol: "INTCc", usdcPerShare: 30_000000});
        list[6] = Entry({stock: 0xb2000000000000000000008bC8786B856E61707C, symbol: "METAc", usdcPerShare: 700_000000});
        list[7] = Entry({stock: 0xB200000000000000000000Ab99cFa739E253872B, symbol: "MSFTc", usdcPerShare: 500_000000});
        list[8] = Entry({stock: 0xb2000000000000000000004884b426556b92883d, symbol: "MSTRc", usdcPerShare: 350_000000});
        list[9] = Entry({stock: 0xb20000000000000000000078ee7ce2fE4908108C, symbol: "NVDAc", usdcPerShare: 170_000000});
        list[10] = Entry({stock: 0xb200000000000000000000397293Cb8cda9a10c5, symbol: "SNDKc", usdcPerShare: 60_000000});
        list[11] = Entry({stock: 0xb2000000000000000000007b9fcbd005511aCBd5, symbol: "SPCXc", usdcPerShare: 100_000000});
        list[12] = Entry({stock: 0xb2000000000000000000001e800a7f5189430cD0, symbol: "TSLAc", usdcPerShare: 400_000000});
    }

    /// @notice The catalog symbol for an address, or the generic `FIXc` for a non-catalog fixture.
    function symbolOf(address stock) internal pure returns (string memory) {
        Entry[COUNT] memory list = entries();
        for (uint256 i; i < COUNT; ++i) {
            if (list[i].stock == stock) return list[i].symbol;
        }
        return "FIXc";
    }
}
