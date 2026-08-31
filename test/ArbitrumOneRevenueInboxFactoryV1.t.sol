// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CctpRevenueInboxV1} from "../src/CctpRevenueInboxV1.sol";
import {ArbitrumOneRevenueInboxFactoryV1} from "../src/chains/ArbitrumOneRevenueInboxFactoryV1.sol";
import {RevenueMeshTypes} from "../src/libraries/RevenueMeshTypes.sol";
import {TestBase} from "./TestBase.sol";

interface Vm {
    function chainId(uint256 newChainId) external;
}

contract ArbitrumOneRevenueInboxFactoryV1Test is TestBase {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant ARBITRUM_ONE_CHAIN_ID = 42161;
    uint32 private constant ARBITRUM_ONE_CCTP_DOMAIN = 3;
    address private constant ARBITRUM_ONE_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant ARBITRUM_ONE_TOKEN_MESSENGER_V2 = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    bytes32 private constant EIP155_NAMESPACE = 0x6569703135350000000000000000000000000000000000000000000000000000;
    uint256 private constant CCTP_MAX_BURN_PER_MESSAGE = 10_000_000e6;
    uint256 private constant MINIMUM_SWEEP = 100e6;
    uint256 private constant MAX_FEE_BPS = 50;

    address private constant VECTOR_BASE_RECEIVER = 0x1111111111111111111111111111111111111111;
    address private constant VECTOR_BASE_SPLITTER = 0x2222222222222222222222222222222222222222;
    bytes32 private constant VECTOR_ROUTE_ID = 0x816118fa8cee7c00584d3965730ec11d752e7c97525586e160dbc03e88d734ab;

    ArbitrumOneRevenueInboxFactoryV1 private factory;

    function setUp() public {
        VM.chainId(ARBITRUM_ONE_CHAIN_ID);
        factory = new ArbitrumOneRevenueInboxFactoryV1(MINIMUM_SWEEP, MAX_FEE_BPS);
    }

    function testCorrectChainConstructionFixesEveryArbitrumConstant() public view {
        assertEq(factory.ARBITRUM_ONE_CHAIN_ID(), ARBITRUM_ONE_CHAIN_ID, "wrapper chain constant");
        assertEq(factory.ARBITRUM_ONE_CCTP_DOMAIN(), ARBITRUM_ONE_CCTP_DOMAIN, "wrapper domain constant");
        assertEq(factory.ARBITRUM_ONE_USDC(), ARBITRUM_ONE_USDC, "wrapper USDC constant");
        assertEq(
            factory.ARBITRUM_ONE_TOKEN_MESSENGER_V2(), ARBITRUM_ONE_TOKEN_MESSENGER_V2, "wrapper messenger constant"
        );
        assertEq(factory.EIP155_NAMESPACE(), EIP155_NAMESPACE, "wrapper namespace constant");
        assertEq(factory.CCTP_MAX_BURN_PER_MESSAGE(), CCTP_MAX_BURN_PER_MESSAGE, "wrapper burn cap constant");

        assertEq(factory.sourceChainId(), ARBITRUM_ONE_CHAIN_ID, "factory chain binding");
        assertEq(factory.sourceDomain(), ARBITRUM_ONE_CCTP_DOMAIN, "factory domain binding");
        assertEq(factory.sourceUsdc(), ARBITRUM_ONE_USDC, "factory USDC binding");
        assertEq(factory.tokenMessenger(), ARBITRUM_ONE_TOKEN_MESSENGER_V2, "factory messenger binding");
        assertEq(factory.sourceNamespace(), EIP155_NAMESPACE, "factory namespace binding");
        assertEq(factory.maxBurnPerMessage(), CCTP_MAX_BURN_PER_MESSAGE, "factory burn cap binding");
    }

    function testWrongChainRejectsConstruction() public {
        VM.chainId(ARBITRUM_ONE_CHAIN_ID + 1);
        assertTrue(_constructionFails(MINIMUM_SWEEP, MAX_FEE_BPS), "wrong chain accepted");
    }

    function testPolicyValuesForwardExactly() public view {
        assertEq(factory.minimumSweep(), MINIMUM_SWEEP, "minimum sweep forwarding");
        assertEq(factory.maxFeeBps(), MAX_FEE_BPS, "fee ceiling forwarding");
    }

    function testPolicyBoundsRemainInherited() public {
        assertTrue(_constructionFails(0, 0), "zero minimum accepted");
        assertTrue(_constructionFails(CCTP_MAX_BURN_PER_MESSAGE + 1, 0), "minimum above cap accepted");
        assertTrue(_constructionFails(1, 10_001), "fee above BPS accepted");

        ArbitrumOneRevenueInboxFactoryV1 boundary =
            new ArbitrumOneRevenueInboxFactoryV1(CCTP_MAX_BURN_PER_MESSAGE, 10_000);
        assertEq(boundary.minimumSweep(), CCTP_MAX_BURN_PER_MESSAGE, "maximum minimum rejected");
        assertEq(boundary.maxFeeBps(), 10_000, "maximum fee ceiling rejected");
    }

    function testFixedRouteVectorAndAddressAreDeterministic() public {
        assertEq(
            factory.computeRouteId(VECTOR_BASE_RECEIVER, VECTOR_BASE_SPLITTER), VECTOR_ROUTE_ID, "fixed route vector"
        );

        address firstPrediction = factory.computeInboxAddress(VECTOR_BASE_RECEIVER, VECTOR_BASE_SPLITTER);
        address secondPrediction = factory.computeInboxAddress(VECTOR_BASE_RECEIVER, VECTOR_BASE_SPLITTER);
        assertEq(firstPrediction, secondPrediction, "repeated address prediction");

        CctpRevenueInboxV1 inbox = factory.deploy(VECTOR_BASE_RECEIVER, VECTOR_BASE_SPLITTER);
        CctpRevenueInboxV1 repeated = factory.deploy(VECTOR_BASE_RECEIVER, VECTOR_BASE_SPLITTER);
        assertEq(address(inbox), firstPrediction, "deployed address");
        assertEq(address(repeated), firstPrediction, "repeat deployment address");
        assertEq(inbox.routeId(), VECTOR_ROUTE_ID, "deployed route ID");
        assertEq(inbox.baseReceiver(), VECTOR_BASE_RECEIVER, "deployed receiver");
        assertEq(inbox.baseSplitter(), VECTOR_BASE_SPLITTER, "deployed splitter");
    }

    function testCreate2AddressRemainsFactoryRelative() public {
        ArbitrumOneRevenueInboxFactoryV1 other = new ArbitrumOneRevenueInboxFactoryV1(MINIMUM_SWEEP, MAX_FEE_BPS);

        assertTrue(
            other.computeInboxAddress(VECTOR_BASE_RECEIVER, VECTOR_BASE_SPLITTER)
                != factory.computeInboxAddress(VECTOR_BASE_RECEIVER, VECTOR_BASE_SPLITTER),
            "factory-relative addresses aliased"
        );
    }

    function testRouteFactsRemainOfflineAndExposeFixedConfiguration() public view {
        RevenueMeshTypes.RouteFacts memory facts = factory.routeFacts(VECTOR_BASE_RECEIVER, VECTOR_BASE_SPLITTER);

        assertEq(facts.routeId, VECTOR_ROUTE_ID, "facts route ID");
        assertEq(facts.acceptedSourceToken, ARBITRUM_ONE_USDC, "facts USDC");
        assertEq(facts.tokenMessengerV2, ARBITRUM_ONE_TOKEN_MESSENGER_V2, "facts messenger");
        assertEq(facts.sourceDomain, ARBITRUM_ONE_CCTP_DOMAIN, "facts source domain");
        assertEq(facts.sourceNamespace, EIP155_NAMESPACE, "facts namespace");
        assertEq(facts.sourceChainId, ARBITRUM_ONE_CHAIN_ID, "facts chain");
        assertEq(facts.minimumSweep, MINIMUM_SWEEP, "facts minimum sweep");
        assertEq(facts.maxBurnPerMessage, CCTP_MAX_BURN_PER_MESSAGE, "facts burn cap");
        assertEq(facts.maxFeeBps, MAX_FEE_BPS, "facts fee ceiling");
        assertEq(facts.status, "UNVERIFIED_INACTIVE", "facts status");
        assertFalse(facts.compatibilityVerified, "compatibility claimed");
        assertFalse(facts.active, "activation claimed");
    }

    function _constructionFails(uint256 minimumSweep, uint256 maxFeeBps) private returns (bool failed) {
        try new ArbitrumOneRevenueInboxFactoryV1(minimumSweep, maxFeeBps) returns (ArbitrumOneRevenueInboxFactoryV1) {
            failed = false;
        } catch {
            failed = true;
        }
    }
}
