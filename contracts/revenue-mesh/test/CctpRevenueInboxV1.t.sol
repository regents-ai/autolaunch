// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CctpRevenueInboxV1} from "../src/CctpRevenueInboxV1.sol";
import {RevenueInboxFactoryV1} from "../src/RevenueInboxFactoryV1.sol";
import {RevenueMeshTypes} from "../src/libraries/RevenueMeshTypes.sol";
import {BaseCompatibilityV1} from "../src/libraries/BaseCompatibilityV1.sol";
import {TestBase} from "./TestBase.sol";
import {MockUsdc} from "./mocks/MockUsdc.sol";
import {MockTokenMessengerV2} from "./mocks/MockTokenMessengerV2.sol";
import {SweepActor, FactoryActor, MockBaseReceiver} from "./mocks/Actors.sol";
import {BaseCompatibilityHarness} from "./mocks/BaseCompatibilityHarness.sol";

contract CctpRevenueInboxV1Test is TestBase {
    address private constant BASE_RECEIVER = address(0xBEEF);
    address private constant BASE_SPLITTER = address(0xCAFE);
    uint32 private constant SOURCE_DOMAIN = 3;
    bytes32 private constant SOURCE_NAMESPACE = "eip155";
    uint256 private constant MINIMUM_SWEEP = 100;
    uint256 private constant MAX_BURN = 1000;
    uint256 private constant MAX_FEE_BPS = 100;

    MockUsdc private token;
    MockTokenMessengerV2 private messenger;
    RevenueInboxFactoryV1 private factory;
    SweepActor private sweeper;
    uint256 private sourceChainId;

    function setUp() public {
        token = new MockUsdc();
        messenger = new MockTokenMessengerV2();
        sourceChainId = block.chainid;
        factory = _newFactory(MINIMUM_SWEEP, MAX_BURN, MAX_FEE_BPS);
        sweeper = new SweepActor();
    }

    function testSuccessfulBoundedSweepUsesExactCctpFieldsAndAllowance() public {
        CctpRevenueInboxV1 inbox = factory.deploy(BASE_RECEIVER, BASE_SPLITTER);
        token.mint(address(inbox), 1500);

        uint256 swept = sweeper.sweep(inbox, 10);

        assertEq(swept, MAX_BURN, "swept amount");
        assertEq(token.rawBalanceOf(address(inbox)), 500, "cap residue");
        assertEq(token.rawBalanceOf(address(messenger)), MAX_BURN, "messenger consumption");
        assertEq(token.rawAllowance(address(inbox), address(messenger)), 0, "success allowance");
        assertEq(messenger.observedAllowance(), MAX_BURN, "temporary allowance");
        assertEq(messenger.amount(), MAX_BURN, "CCTP amount");
        assertEq(messenger.destinationDomain(), uint32(6), "Base domain");
        assertEq(messenger.mintRecipient(), bytes32(uint256(uint160(BASE_RECEIVER))), "fixed mint recipient");
        assertEq(messenger.burnToken(), address(token), "fixed burn token");
        assertEq(messenger.destinationCaller(), bytes32(0), "open completion");
        assertEq(messenger.maxFee(), 10, "maximum fee");
        assertEq(messenger.minFinalityThreshold(), uint32(2000), "standard finality");
    }

    function testFactoryAndInboxBindingsAreExact() public {
        CctpRevenueInboxV1 inbox = factory.deploy(BASE_RECEIVER, BASE_SPLITTER);
        bytes32 expectedRouteId = keccak256(
            abi.encode(
                "AUTOLAUNCH_REVENUE_ROUTE_V1",
                uint256(8453),
                BASE_RECEIVER,
                BASE_SPLITTER,
                SOURCE_NAMESPACE,
                sourceChainId,
                "CCTP_V2_STANDARD"
            )
        );

        assertEq(factory.sourceUsdc(), address(token), "factory token");
        assertEq(factory.tokenMessenger(), address(messenger), "factory messenger");
        assertEq(factory.sourceDomain(), SOURCE_DOMAIN, "factory source domain");
        assertEq(factory.sourceChainId(), sourceChainId, "factory chain");
        assertEq(factory.sourceNamespace(), SOURCE_NAMESPACE, "factory namespace");
        assertEq(factory.minimumSweep(), MINIMUM_SWEEP, "factory minimum");
        assertEq(factory.maxBurnPerMessage(), MAX_BURN, "factory cap");
        assertEq(factory.maxFeeBps(), MAX_FEE_BPS, "factory fee BPS");

        assertEq(inbox.routeId(), expectedRouteId, "route ID");
        assertEq(address(inbox.usdc()), address(token), "inbox token");
        assertEq(address(inbox.tokenMessenger()), address(messenger), "inbox messenger");
        assertEq(inbox.sourceDomain(), SOURCE_DOMAIN, "inbox source domain");
        assertEq(inbox.sourceChainId(), sourceChainId, "inbox chain");
        assertEq(inbox.sourceNamespace(), SOURCE_NAMESPACE, "inbox namespace");
        assertEq(inbox.minimumSweep(), MINIMUM_SWEEP, "inbox minimum");
        assertEq(inbox.maxBurnPerMessage(), MAX_BURN, "inbox cap");
        assertEq(inbox.maxFeeBps(), MAX_FEE_BPS, "inbox fee BPS");
        assertEq(inbox.baseReceiver(), BASE_RECEIVER, "Base receiver");
        assertEq(inbox.baseSplitter(), BASE_SPLITTER, "Base splitter");
    }

    function testPermissionlessDeploymentAndSweepUseOrdinaryCallers() public {
        FactoryActor deployer = new FactoryActor();
        CctpRevenueInboxV1 inbox = deployer.deploy(factory, BASE_RECEIVER, BASE_SPLITTER);
        token.mint(address(inbox), MINIMUM_SWEEP);

        SweepActor unrelatedCaller = new SweepActor();
        uint256 swept = unrelatedCaller.sweep(inbox, 1);

        assertEq(swept, MINIMUM_SWEEP, "permissionless amount");
        assertEq(token.rawBalanceOf(address(inbox)), 0, "permissionless residue");
    }

    function testBelowMinimumRevertsWithoutBalanceOrAllowanceChange() public {
        CctpRevenueInboxV1 inbox = factory.deploy(BASE_RECEIVER, BASE_SPLITTER);
        token.mint(address(inbox), MINIMUM_SWEEP - 1);

        _assertSweepFailsAndPreserves(inbox, 0, MINIMUM_SWEEP - 1);
    }

    function testExactMinimumSucceeds() public {
        CctpRevenueInboxV1 inbox = factory.deploy(BASE_RECEIVER, BASE_SPLITTER);
        token.mint(address(inbox), MINIMUM_SWEEP);

        assertEq(sweeper.sweep(inbox, 1), MINIMUM_SWEEP, "exact minimum");
        assertEq(token.rawBalanceOf(address(inbox)), 0, "minimum residue");
    }

    function testFeeAtCeilingSucceedsAndOneAboveReverts() public {
        CctpRevenueInboxV1 firstInbox = factory.deploy(BASE_RECEIVER, BASE_SPLITTER);
        token.mint(address(firstInbox), MAX_BURN);
        assertEq(sweeper.sweep(firstInbox, 10), MAX_BURN, "exact fee ceiling");

        address secondReceiver = address(0xBEE1);
        CctpRevenueInboxV1 secondInbox = factory.deploy(secondReceiver, BASE_SPLITTER);
        token.mint(address(secondInbox), MAX_BURN);
        _assertSweepFailsAndPreserves(secondInbox, 11, MAX_BURN);
    }

    function testFeeEqualToAmountRevertsAndAmountMinusOneSucceeds() public {
        RevenueInboxFactoryV1 fullFeeFactory = _newFactory(1, 100, 10_000);
        CctpRevenueInboxV1 rejectedInbox = fullFeeFactory.deploy(BASE_RECEIVER, BASE_SPLITTER);
        token.mint(address(rejectedInbox), 100);
        _assertSweepFailsAndPreserves(rejectedInbox, 100, 100);

        CctpRevenueInboxV1 acceptedInbox = fullFeeFactory.deploy(address(0xBE01), BASE_SPLITTER);
        token.mint(address(acceptedInbox), 100);
        assertEq(sweeper.sweep(acceptedInbox, 99), 100, "fee amount minus one");
    }

    function testZeroFeeCeilingAcceptsOnlyZero() public {
        RevenueInboxFactoryV1 zeroFeeFactory = _newFactory(1, 100, 0);
        CctpRevenueInboxV1 acceptedInbox = zeroFeeFactory.deploy(BASE_RECEIVER, BASE_SPLITTER);
        token.mint(address(acceptedInbox), 100);
        assertEq(sweeper.sweep(acceptedInbox, 0), 100, "zero fee");

        CctpRevenueInboxV1 rejectedInbox = zeroFeeFactory.deploy(address(0xBE02), BASE_SPLITTER);
        token.mint(address(rejectedInbox), 100);
        _assertSweepFailsAndPreserves(rejectedInbox, 1, 100);
    }

    function testMaximumAmountFeeMathDoesNotOverflow() public {
        RevenueInboxFactoryV1 maximumFactory = _newFactory(1, type(uint256).max, 10_000);
        CctpRevenueInboxV1 inbox = maximumFactory.deploy(BASE_RECEIVER, BASE_SPLITTER);
        token.mint(address(inbox), type(uint256).max);

        assertEq(sweeper.sweep(inbox, type(uint256).max - 1), type(uint256).max, "maximum amount");
        assertEq(token.rawBalanceOf(address(inbox)), 0, "maximum residue");
    }

    function testWrongTokenBalanceCannotAffectSweep() public {
        CctpRevenueInboxV1 inbox = factory.deploy(BASE_RECEIVER, BASE_SPLITTER);
        MockUsdc wrongToken = new MockUsdc();
        token.mint(address(inbox), MINIMUM_SWEEP);
        wrongToken.mint(address(inbox), 777);

        sweeper.sweep(inbox, 1);

        assertEq(wrongToken.rawBalanceOf(address(inbox)), 777, "wrong token moved");
        assertEq(messenger.burnToken(), address(token), "wrong burn token");
    }

    function testFactoryRejectsInvalidBindingsAndEconomics() public {
        assertTrue(
            _factoryConstructionFails(address(0), address(messenger), 3, sourceChainId, SOURCE_NAMESPACE, 1, 1, 0),
            "zero token"
        );
        assertTrue(
            _factoryConstructionFails(address(token), address(0), 3, sourceChainId, SOURCE_NAMESPACE, 1, 1, 0),
            "zero messenger"
        );
        assertTrue(
            _factoryConstructionFails(address(token), address(messenger), 3, 0, SOURCE_NAMESPACE, 1, 1, 0), "zero chain"
        );
        assertTrue(
            _factoryConstructionFails(address(token), address(messenger), 3, sourceChainId, bytes32(0), 1, 1, 0),
            "zero namespace"
        );
        assertTrue(
            _factoryConstructionFails(address(token), address(messenger), 3, sourceChainId, SOURCE_NAMESPACE, 0, 1, 0),
            "zero minimum"
        );
        assertTrue(
            _factoryConstructionFails(address(token), address(messenger), 3, sourceChainId, SOURCE_NAMESPACE, 2, 1, 0),
            "minimum above cap"
        );
        assertTrue(
            _factoryConstructionFails(
                address(token), address(messenger), 3, sourceChainId, SOURCE_NAMESPACE, 1, 1, 10_001
            ),
            "fee above BPS"
        );
    }

    function testFactoryAcceptsExecutingSourceChainIdentity() public {
        RevenueInboxFactoryV1 currentChainFactory = new RevenueInboxFactoryV1(
            address(token), address(messenger), SOURCE_DOMAIN, block.chainid, SOURCE_NAMESPACE, 1, 1, 0
        );
        assertEq(currentChainFactory.sourceChainId(), block.chainid, "executing chain rejected");
    }

    function testFactoryRejectsMismatchedSourceChainIdentity() public {
        assertTrue(
            _factoryConstructionFails(
                address(token), address(messenger), SOURCE_DOMAIN, block.chainid + 1, SOURCE_NAMESPACE, 1, 1, 0
            ),
            "mismatched chain accepted"
        );
    }

    function testDirectInboxConstructionRejectsZeroRouteBinding() public {
        bool failed;
        try new CctpRevenueInboxV1(
            bytes32(0),
            address(token),
            address(messenger),
            SOURCE_DOMAIN,
            sourceChainId,
            SOURCE_NAMESPACE,
            MINIMUM_SWEEP,
            MAX_BURN,
            MAX_FEE_BPS,
            BASE_RECEIVER,
            BASE_SPLITTER
        ) returns (
            CctpRevenueInboxV1
        ) {
            failed = false;
        } catch {
            failed = true;
        }
        assertTrue(failed, "zero route accepted");
    }

    function testSourceDomainZeroRemainsValidForEthereumCctp() public {
        RevenueInboxFactoryV1 ethereumFactory =
            new RevenueInboxFactoryV1(address(token), address(messenger), 0, sourceChainId, SOURCE_NAMESPACE, 1, 1, 0);
        assertEq(ethereumFactory.sourceDomain(), uint32(0), "Ethereum CCTP domain");
    }

    function testFactoryRejectsZeroBasePair() public {
        (bool receiverOk,) = address(factory).call(abi.encodeCall(factory.deploy, (address(0), BASE_SPLITTER)));
        (bool splitterOk,) = address(factory).call(abi.encodeCall(factory.deploy, (BASE_RECEIVER, address(0))));
        assertFalse(receiverOk, "zero receiver accepted");
        assertFalse(splitterOk, "zero splitter accepted");
    }

    function testCreate2FormulaIsFactoryRelativeAndRepeatDeploymentIsExact() public {
        bytes32 routeId = factory.computeRouteId(BASE_RECEIVER, BASE_SPLITTER);
        bytes memory creationCode = _creationCode(factory, routeId, BASE_RECEIVER, BASE_SPLITTER, MAX_BURN);
        address independentlyComputed = _create2Address(address(factory), routeId, keccak256(creationCode));

        assertEq(factory.computeInboxAddress(BASE_RECEIVER, BASE_SPLITTER), independentlyComputed, "formula");
        CctpRevenueInboxV1 first = factory.deploy(BASE_RECEIVER, BASE_SPLITTER);
        FactoryActor secondCaller = new FactoryActor();
        CctpRevenueInboxV1 second = secondCaller.deploy(factory, BASE_RECEIVER, BASE_SPLITTER);

        assertEq(address(first), independentlyComputed, "deployed address");
        assertEq(address(second), address(first), "repeat deployment");
        assertEq(address(first).codehash, factory.inboxRuntimeCodeHash(), "runtime identity");
        assertEq(first.routeId(), routeId, "repeat route binding");
        assertEq(first.baseReceiver(), BASE_RECEIVER, "repeat receiver binding");
        assertEq(first.baseSplitter(), BASE_SPLITTER, "repeat splitter binding");
    }

    function testConfigurationAndCreationCodeChangesCannotAlias() public {
        bytes32 routeId = factory.computeRouteId(BASE_RECEIVER, BASE_SPLITTER);
        address canonical = factory.computeInboxAddress(BASE_RECEIVER, BASE_SPLITTER);

        bytes memory alternateConfigCode = _creationCode(factory, routeId, BASE_RECEIVER, BASE_SPLITTER, MAX_BURN + 1);
        address alternateConfig = _create2Address(address(factory), routeId, keccak256(alternateConfigCode));
        assertTrue(alternateConfig != canonical, "config alias");

        bytes memory canonicalCode = _creationCode(factory, routeId, BASE_RECEIVER, BASE_SPLITTER, MAX_BURN);
        bytes memory changedCreationCode = bytes.concat(canonicalCode, hex"00");
        address changedCode = _create2Address(address(factory), routeId, keccak256(changedCreationCode));
        assertTrue(changedCode != canonical, "creation code alias");

        RevenueInboxFactoryV1 otherFactory = _newFactory(MINIMUM_SWEEP, MAX_BURN + 1, MAX_FEE_BPS);
        assertTrue(otherFactory.computeInboxAddress(BASE_RECEIVER, BASE_SPLITTER) != canonical, "factory/config alias");
    }

    function testRouteFactsAreExplicitlyOfflineAndInactive() public view {
        RevenueMeshTypes.RouteFacts memory facts = factory.routeFacts(BASE_RECEIVER, BASE_SPLITTER);

        assertEq(facts.routeId, factory.computeRouteId(BASE_RECEIVER, BASE_SPLITTER), "facts route");
        assertEq(facts.predictedInbox, factory.computeInboxAddress(BASE_RECEIVER, BASE_SPLITTER), "facts address");
        assertEq(facts.acceptedSourceToken, address(token), "facts token");
        assertEq(facts.tokenMessengerV2, address(messenger), "facts messenger");
        assertEq(facts.sourceDomain, SOURCE_DOMAIN, "facts source domain");
        assertEq(facts.sourceNamespace, SOURCE_NAMESPACE, "facts namespace");
        assertEq(facts.sourceChainId, sourceChainId, "facts chain");
        assertEq(facts.destinationDomain, uint32(6), "facts Base domain");
        assertEq(facts.finalityThreshold, uint32(2000), "facts finality");
        assertTrue(facts.permissionlessCompletion, "facts completion");
        assertEq(facts.minimumSweep, MINIMUM_SWEEP, "facts minimum");
        assertEq(facts.maxBurnPerMessage, MAX_BURN, "facts cap");
        assertEq(facts.maxFeeBps, MAX_FEE_BPS, "facts fee BPS");
        assertEq(facts.baseReceiver, BASE_RECEIVER, "facts receiver");
        assertEq(facts.baseSplitter, BASE_SPLITTER, "facts splitter");
        assertEq(facts.candidateFactory, address(factory), "facts factory");
        assertEq(facts.inboxRuntimeCodeHash, factory.inboxRuntimeCodeHash(), "facts code hash");
        assertEq(facts.bridgeSecurityClass, "CCTP_ISSUER_NATIVE", "facts class");
        assertEq(facts.settlementTransport, "CCTP_V2_STANDARD", "facts settlement");
        assertEq(facts.status, "UNVERIFIED_INACTIVE", "facts status");
        assertFalse(facts.compatibilityVerified, "compatibility claimed");
        assertFalse(facts.active, "activation claimed");
    }

    function testMessengerUnderConsumptionRevertsAtomically() public {
        CctpRevenueInboxV1 inbox = factory.deploy(BASE_RECEIVER, BASE_SPLITTER);
        token.mint(address(inbox), MAX_BURN);
        messenger.setMode(MockTokenMessengerV2.Mode.UNDER_CONSUME);

        _assertSweepFailsAndPreserves(inbox, 10, MAX_BURN);
        assertEq(token.rawBalanceOf(address(messenger)), 0, "under-consumption messenger residue");
    }

    function testMessengerFailureBeforeConsumptionRollsBack() public {
        CctpRevenueInboxV1 inbox = factory.deploy(BASE_RECEIVER, BASE_SPLITTER);
        token.mint(address(inbox), MAX_BURN);
        messenger.setMode(MockTokenMessengerV2.Mode.REVERT_BEFORE_CONSUMPTION);

        _assertSweepFailsAndPreserves(inbox, 10, MAX_BURN);
    }

    function testMessengerFailureAfterConsumptionRollsBack() public {
        CctpRevenueInboxV1 inbox = factory.deploy(BASE_RECEIVER, BASE_SPLITTER);
        token.mint(address(inbox), MAX_BURN);
        messenger.setMode(MockTokenMessengerV2.Mode.CONSUME_THEN_REVERT);

        _assertSweepFailsAndPreserves(inbox, 10, MAX_BURN);
        assertEq(token.rawBalanceOf(address(messenger)), 0, "messenger revert residue");
    }

    function testReentrancyIsRejectedWhileOuterSweepCanComplete() public {
        CctpRevenueInboxV1 inbox = factory.deploy(BASE_RECEIVER, BASE_SPLITTER);
        token.mint(address(inbox), MAX_BURN);
        messenger.setMode(MockTokenMessengerV2.Mode.REENTER_CAUGHT);

        assertEq(sweeper.sweep(inbox, 10), MAX_BURN, "outer sweep");
        assertTrue(messenger.reentryRejected(), "reentry accepted");
        assertEq(token.rawAllowance(address(inbox), address(messenger)), 0, "reentry allowance");
    }

    function testUncaughtReentrancyRevertsOuterSweepAtomically() public {
        CctpRevenueInboxV1 inbox = factory.deploy(BASE_RECEIVER, BASE_SPLITTER);
        token.mint(address(inbox), MAX_BURN);
        messenger.setMode(MockTokenMessengerV2.Mode.REENTER_UNCAUGHT);

        _assertSweepFailsAndPreserves(inbox, 10, MAX_BURN);
    }

    function testTokenReadAndApprovalFailuresRollBack() public {
        _assertTokenFaultRollsBack(MockUsdc.Fault.BALANCE_READ);
        _assertTokenFaultRollsBack(MockUsdc.Fault.ALLOWANCE_READ);
        _assertTokenFaultRollsBack(MockUsdc.Fault.APPROVE_NONZERO_REVERT);
        _assertTokenFaultRollsBack(MockUsdc.Fault.APPROVE_FALSE);
        _assertTokenFaultRollsBack(MockUsdc.Fault.APPROVE_NO_EFFECT);
    }

    function testTokenTransferAndCleanupFailuresRollBack() public {
        _assertTokenFaultRollsBack(MockUsdc.Fault.TRANSFER_FROM_REVERT);
        _assertTokenFaultRollsBack(MockUsdc.Fault.APPROVE_ZERO_REVERT);
    }

    function testSameCodeBaseReceiverBindingMismatchFailsCompatibility() public {
        address canonicalBaseUsdc = address(0x8335);
        address expectedSplitter = address(0x5151);
        bytes32 provenance = keccak256("ADMITTED_AUTOLAUNCH_RELEASE");
        MockBaseReceiver admitted = new MockBaseReceiver(expectedSplitter, canonicalBaseUsdc, 0, true);
        MockBaseReceiver wrongBinding = new MockBaseReceiver(address(0xDEAD), canonicalBaseUsdc, 0, true);
        BaseCompatibilityHarness harness = new BaseCompatibilityHarness();

        assertEq(address(admitted).codehash, address(wrongBinding).codehash, "mock code differs");
        BaseCompatibilityV1.Admission memory admission = BaseCompatibilityV1.Admission({
            receiverCodeHash: address(admitted).codehash,
            canonicalBaseUsdc: canonicalBaseUsdc,
            provenanceHash: provenance
        });
        BaseCompatibilityV1.Observation memory admittedObservation = _observation(admitted, provenance);
        BaseCompatibilityV1.Observation memory mismatchObservation = _observation(wrongBinding, provenance);

        assertTrue(
            harness.isCompatible(address(admitted), expectedSplitter, admission, admittedObservation),
            "admitted instance rejected"
        );
        assertFalse(
            harness.isCompatible(address(wrongBinding), expectedSplitter, admission, mismatchObservation),
            "same-code binding mismatch accepted"
        );
    }

    function testBaseCompatibilityFailsClosedOnEveryRequiredFact() public {
        address canonicalBaseUsdc = address(0x8335);
        address expectedSplitter = address(0x5151);
        bytes32 provenance = keccak256("ADMITTED_AUTOLAUNCH_RELEASE");
        MockBaseReceiver receiver = new MockBaseReceiver(expectedSplitter, canonicalBaseUsdc, 0, true);
        BaseCompatibilityHarness harness = new BaseCompatibilityHarness();
        BaseCompatibilityV1.Admission memory admission = BaseCompatibilityV1.Admission({
            receiverCodeHash: address(receiver).codehash,
            canonicalBaseUsdc: canonicalBaseUsdc,
            provenanceHash: provenance
        });
        BaseCompatibilityV1.Observation memory observation = _observation(receiver, provenance);

        observation.initialized = false;
        assertFalse(harness.isCompatible(address(receiver), expectedSplitter, admission, observation), "uninitialized");
        observation = _observation(receiver, provenance);
        observation.receiverCodeHash = keccak256("UNKNOWN_CODE");
        assertFalse(harness.isCompatible(address(receiver), expectedSplitter, admission, observation), "unknown code");
        observation = _observation(receiver, provenance);
        observation.receiver = address(0xBAD);
        assertFalse(harness.isCompatible(address(receiver), expectedSplitter, admission, observation), "wrong receiver");
        observation = _observation(receiver, provenance);
        observation.usdc = address(0xBAD);
        assertFalse(harness.isCompatible(address(receiver), expectedSplitter, admission, observation), "wrong USDC");
        observation = _observation(receiver, provenance);
        observation.referralBps = 1;
        assertFalse(harness.isCompatible(address(receiver), expectedSplitter, admission, observation), "referral");
        observation = _observation(receiver, provenance);
        observation.provenanceHash = keccak256("OTHER_RELEASE");
        assertFalse(harness.isCompatible(address(receiver), expectedSplitter, admission, observation), "provenance");
        admission.provenanceHash = bytes32(0);
        observation = _observation(receiver, provenance);
        assertFalse(
            harness.isCompatible(address(receiver), expectedSplitter, admission, observation), "empty admission"
        );
    }

    function _newFactory(uint256 minimum, uint256 cap, uint256 feeBps) private returns (RevenueInboxFactoryV1) {
        return new RevenueInboxFactoryV1(
            address(token), address(messenger), SOURCE_DOMAIN, sourceChainId, SOURCE_NAMESPACE, minimum, cap, feeBps
        );
    }

    function _assertSweepFailsAndPreserves(CctpRevenueInboxV1 inbox, uint256 maxFee, uint256 expectedBalance) private {
        (bool success,) = sweeper.trySweep(inbox, maxFee);
        assertFalse(success, "sweep unexpectedly succeeded");
        assertEq(token.rawBalanceOf(address(inbox)), expectedBalance, "failure balance");
        assertEq(token.rawAllowance(address(inbox), address(messenger)), 0, "failure allowance");
    }

    function _assertTokenFaultRollsBack(MockUsdc.Fault fault) private {
        address receiver = address(uint160(0x1000 + uint256(fault)));
        CctpRevenueInboxV1 inbox = factory.deploy(receiver, BASE_SPLITTER);
        token.mint(address(inbox), MAX_BURN);
        token.setFault(fault);
        _assertSweepFailsAndPreserves(inbox, 10, MAX_BURN);
        token.setFault(MockUsdc.Fault.NONE);
        assertEq(token.rawBalanceOf(address(messenger)), 0, "fault messenger residue");
    }

    function _factoryConstructionFails(
        address sourceUsdc,
        address tokenMessenger,
        uint32 domain,
        uint256 chainId,
        bytes32 namespace,
        uint256 minimum,
        uint256 cap,
        uint256 feeBps
    ) private returns (bool) {
        try new RevenueInboxFactoryV1(
            sourceUsdc, tokenMessenger, domain, chainId, namespace, minimum, cap, feeBps
        ) returns (
            RevenueInboxFactoryV1
        ) {
            return false;
        } catch {
            return true;
        }
    }

    function _creationCode(
        RevenueInboxFactoryV1 targetFactory,
        bytes32 routeId,
        address baseReceiver,
        address baseSplitter,
        uint256 cap
    ) private view returns (bytes memory) {
        return abi.encodePacked(
            type(CctpRevenueInboxV1).creationCode,
            abi.encode(
                routeId,
                targetFactory.sourceUsdc(),
                targetFactory.tokenMessenger(),
                targetFactory.sourceDomain(),
                targetFactory.sourceChainId(),
                targetFactory.sourceNamespace(),
                targetFactory.minimumSweep(),
                cap,
                targetFactory.maxFeeBps(),
                baseReceiver,
                baseSplitter
            )
        );
    }

    function _create2Address(address deployer, bytes32 salt, bytes32 creationCodeHash) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, creationCodeHash)))));
    }

    function _observation(MockBaseReceiver receiver, bytes32 provenance)
        private
        view
        returns (BaseCompatibilityV1.Observation memory)
    {
        return BaseCompatibilityV1.Observation({
            receiver: address(receiver),
            initialized: receiver.initialized(),
            receiverCodeHash: address(receiver).codehash,
            splitter: receiver.splitter(),
            usdc: receiver.usdc(),
            referralBps: receiver.referralBps(),
            provenanceHash: provenance
        });
    }
}
