// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title FixtureStockCatalog
/// @notice The thirteen Base-native stock token addresses (chain 8453) the local fork lab installs
///         `FixtureStockToken` at, with display symbols, each stock's live Chainlink price feed and a
///         fixed lab USDC price per whole share.
/// @dev LAB ONLY. The real tokens carry `0xef` runtime code that Anvil cannot execute, so the lab
///      replaces their code. Nothing tested against these fixtures is B20-verified: issuer transfer
///      policy, Permit2 compatibility and the real acquisition route remain open admission blockers.
///      Identity is the exact address; symbols and prices are display and fixture data only.
library FixtureStockCatalog {
    struct Entry {
        address stock;
        string symbol;
        /// @dev The live Chainlink feed that prices the real stock in dollars, which a fork carries.
        address feed;
        /// @dev USDC base units (6 decimals) per one whole share (1e8 base units). Fixture pricing.
        uint256 usdcPerShare;
    }

    uint256 internal constant COUNT = 13;
    uint8 internal constant DECIMALS = 8;

    function entries() internal pure returns (Entry[COUNT] memory list) {
        list[0] = Entry({
            stock: 0xb200000000000000000000C2e324d24d7eEcd1fb,
            symbol: "AAPLc",
            feed: 0x787f13dEa48Db0897CbCDD985de77809D837F988,
            usdcPerShare: 230_000000
        });
        list[1] = Entry({
            stock: 0xb200000000000000000000d9192b6B456483C2E8,
            symbol: "AMZNc",
            feed: 0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295,
            usdcPerShare: 220_000000
        });
        list[2] = Entry({
            stock: 0xb200000000000000000000c85a31389D71F3ecfb,
            symbol: "COINc",
            feed: 0x408e44f504A7371a345F03a73dDC96A4b48e8aa7,
            usdcPerShare: 300_000000
        });
        list[3] = Entry({
            stock: 0xB20000000000000000000019f6E7C675b73C2e4D,
            symbol: "CRCLc",
            feed: 0x0231cF2635D1E17bB5c2462cc7504Ba1fBd61f33,
            usdcPerShare: 150_000000
        });
        list[4] = Entry({
            stock: 0xb2000000000000000000002D0BA3164cc74f58B7,
            symbol: "GOOGLc",
            feed: 0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2,
            usdcPerShare: 180_000000
        });
        list[5] = Entry({
            stock: 0xB2000000000000000000004AFF16039bA04bdFBc,
            symbol: "INTCc",
            feed: 0xAB657C39bac0D5886250D70849e2E3E008F2EECB,
            usdcPerShare: 30_000000
        });
        list[6] = Entry({
            stock: 0xb2000000000000000000008bC8786B856E61707C,
            symbol: "METAc",
            feed: 0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D,
            usdcPerShare: 700_000000
        });
        list[7] = Entry({
            stock: 0xB200000000000000000000Ab99cFa739E253872B,
            symbol: "MSFTc",
            feed: 0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c,
            usdcPerShare: 500_000000
        });
        list[8] = Entry({
            stock: 0xb2000000000000000000004884b426556b92883d,
            symbol: "MSTRc",
            feed: 0xB3cE282CD188b35DA0E38D8Bc7d58e33173D202a,
            usdcPerShare: 350_000000
        });
        list[9] = Entry({
            stock: 0xb20000000000000000000078ee7ce2fE4908108C,
            symbol: "NVDAc",
            feed: 0x04689a41629776563E6822F76f2e57D148d28513,
            usdcPerShare: 170_000000
        });
        list[10] = Entry({
            stock: 0xb200000000000000000000397293Cb8cda9a10c5,
            symbol: "SNDKc",
            feed: 0x388b0dC46C0Fb05A74BeE0994fa5b02c6Fcca2eA,
            usdcPerShare: 60_000000
        });
        list[11] = Entry({
            stock: 0xb2000000000000000000007b9fcbd005511aCBd5,
            symbol: "SPCXc",
            feed: 0x6A634B235903C4ad6376892180d6fF8612e3Fa68,
            usdcPerShare: 100_000000
        });
        list[12] = Entry({
            stock: 0xb2000000000000000000001e800a7f5189430cD0,
            symbol: "TSLAc",
            feed: 0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4,
            usdcPerShare: 400_000000
        });
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
