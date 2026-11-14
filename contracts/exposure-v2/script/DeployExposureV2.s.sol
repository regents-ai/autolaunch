// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {ExposureFactoryV2} from "../src/ExposureFactoryV2.sol";
import {IAggregatorProxy} from "../src/interfaces/IExposureV2.sol";

/// @notice Builds the version 2 factory for AMZNc on Base in a local simulation and prints what it
///         would be. It never broadcasts: there is no broadcast call in this script, so running it
///         only simulates. Deploying for real is a separate, approved step.
///
///         forge script script/DeployExposureV2.s.sol --sig "run(bytes32)" <terms hash> \
///             --network base --fork-url <Base RPC>
contract DeployExposureV2 is Script {
    /// Regent governance Safe on Base: the factory's owner.
    address internal constant SAFE = 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e;
    address internal constant AMZNC = 0xb200000000000000000000d9192b6B456483C2E8;
    /// Coinbase AMZN / USD Chainlink proxy on Base.
    address internal constant AMZN_FEED = 0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295;
    /// 40 AMZNc, the same cap as version 1.
    uint256 internal constant DEPOSIT_CAP = 40e8;
    string internal constant TICKER = "AMZNc";

    function run(bytes32 termsHash) external returns (ExposureFactoryV2 factory) {
        factory = build(termsHash);
        ExposureFactoryV2.Template memory t = factory.template();
        uint256 week = factory.currentWeek();
        console.log("factory (simulated)", address(factory));
        console.log("owner", factory.owner());
        console.log("asset", t.asset);
        console.log("feed", t.feed);
        console.log("phase", t.phase);
        console.log("deposit cap", t.depositCap);
        console.logBytes32(t.termsHash);
        console.log("current week", week);
        console.log("its series at", factory.predictSeries(week));
        console.log("starts", factory.startOf(week));
        console.log("matures", factory.startOf(week + 1));
    }

    /// @notice The factory, built from the feed's current phase and the market calendar below.
    function build(bytes32 termsHash) public returns (ExposureFactoryV2) {
        ExposureFactoryV2.Template memory t = ExposureFactoryV2.Template({
            asset: AMZNC,
            feed: AMZN_FEED,
            phase: IAggregatorProxy(AMZN_FEED).phaseId(),
            depositCap: DEPOSIT_CAP,
            termsHash: termsHash,
            ticker: TICKER
        });
        return new ExposureFactoryV2(SAFE, t, closedDays(), earlyCloseDays());
    }

    /// @notice NYSE full closures from late 2026 through 2027, as days since 1970-01-01.
    function closedDays() public pure returns (uint256[] memory d) {
        d = new uint256[](12);
        d[0] = 20_783; // Thu 26 Nov 2026, Thanksgiving
        d[1] = 20_812; // Fri 25 Dec 2026, Christmas
        d[2] = 20_819; // Fri 1 Jan 2027, New Year's Day
        d[3] = 20_836; // Mon 18 Jan 2027, Martin Luther King Jr. Day
        d[4] = 20_864; // Mon 15 Feb 2027, Washington's Birthday
        d[5] = 20_903; // Fri 26 Mar 2027, Good Friday
        d[6] = 20_969; // Mon 31 May 2027, Memorial Day
        d[7] = 20_987; // Fri 18 Jun 2027, Juneteenth (observed)
        d[8] = 21_004; // Mon 5 Jul 2027, Independence Day (observed)
        d[9] = 21_067; // Mon 6 Sep 2027, Labor Day
        d[10] = 21_147; // Thu 25 Nov 2027, Thanksgiving
        d[11] = 21_176; // Fri 24 Dec 2027, Christmas (observed)
    }

    /// @notice NYSE 13:00 early closes from late 2026 through 2027.
    function earlyCloseDays() public pure returns (uint256[] memory d) {
        d = new uint256[](3);
        d[0] = 20_784; // Fri 27 Nov 2026
        d[1] = 20_811; // Thu 24 Dec 2026
        d[2] = 21_148; // Fri 26 Nov 2027
    }
}
