// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {DeferredAutolaunchVestingWallet} from "src/DeferredAutolaunchVestingWallet.sol";
import {IDeferredAutolaunchFactory} from "src/revenue/interfaces/IDeferredAutolaunchFactory.sol";
import {DeferredAutolaunchFactory} from "src/revenue/DeferredAutolaunchFactory.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {RevenueShareFactory} from "src/revenue/RevenueShareFactory.sol";
import {RevenueShareSplitterV2} from "src/revenue/RevenueShareSplitterV2.sol";
import {RevenueShareSplitterV2Deployer} from "src/revenue/RevenueShareSplitterV2Deployer.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {IERC20SupplyMinimal} from "src/revenue/interfaces/IERC20SupplyMinimal.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";
import {MockRegentRevenueFeeRouter} from "test/mocks/MockRegentRevenueFeeRouter.sol";
import {MockTokenFactory} from "test/mocks/MockTokenFactory.sol";

contract DeferredAutolaunchFactoryTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant TREASURY = address(0x1111);
    address internal constant CREATOR = address(0x2222);
    bytes32 internal constant TOKEN_SALT = keccak256("token-salt");
    uint256 internal constant TOTAL_SUPPLY = 1_000_000e18;

    MintableERC20Mock internal usdc;
    SubjectRegistry internal subjectRegistry;
    RevenueShareFactory internal revenueShareFactory;
    RevenueShareSplitterV2Deployer internal splitterDeployer;
    RevenueIngressFactory internal revenueIngressFactory;
    MockRegentRevenueFeeRouter internal feeRouter;
    DeferredAutolaunchFactory internal factory;
    MockTokenFactory internal tokenFactory;

    function setUp() external {
        usdc = new MintableERC20Mock("USD Coin", "USDC");
        subjectRegistry = new SubjectRegistry(OWNER);
        feeRouter = new MockRegentRevenueFeeRouter(address(usdc), address(0x8888));
        splitterDeployer = new RevenueShareSplitterV2Deployer();
        revenueShareFactory = new RevenueShareFactory(
            OWNER, address(usdc), subjectRegistry, address(feeRouter), address(splitterDeployer)
        );
        revenueIngressFactory =
            new RevenueIngressFactory(address(usdc), address(subjectRegistry), OWNER);
        factory = new DeferredAutolaunchFactory(
            OWNER, revenueShareFactory, revenueIngressFactory, feeRouter
        );
        tokenFactory = new MockTokenFactory();

        vm.startPrank(OWNER);
        subjectRegistry.setAuthorizedRegistrar(address(revenueShareFactory), true);
        revenueShareFactory.setAuthorizedCreator(address(factory), true);
        revenueIngressFactory.setAuthorizedCreator(address(factory), true);
        vm.stopPrank();
    }

    function testDeploysTokenVestingSplitterSubjectAndIngress() external {
        vm.prank(CREATOR);
        IDeferredAutolaunchFactory.DeferredAutolaunchResult memory result =
            factory.createDeferredAutolaunch(_config(0, address(0), 0));

        bytes32 expectedSubjectId = keccak256(abi.encode(block.chainid, result.token));
        assertEq(result.subjectId, expectedSubjectId);
        assertEq(
            result.revenueShareSplitter, revenueShareFactory.splitterOfSubject(expectedSubjectId)
        );
        assertEq(
            result.defaultIngress, revenueIngressFactory.defaultIngressOfSubject(expectedSubjectId)
        );
        assertEq(IERC20SupplyMinimal(result.token).balanceOf(result.vestingWallet), TOTAL_SUPPLY);
        assertEq(IERC20SupplyMinimal(result.token).balanceOf(address(factory)), 0);

        DeferredAutolaunchVestingWallet vestingWallet =
            DeferredAutolaunchVestingWallet(result.vestingWallet);
        assertEq(vestingWallet.beneficiary(), TREASURY);
        assertEq(vestingWallet.launchToken(), result.token);

        SubjectRegistry.SubjectConfig memory subject = subjectRegistry.getSubject(expectedSubjectId);
        assertEq(subject.stakeToken, result.token);
        assertEq(subject.splitter, result.revenueShareSplitter);
        assertEq(subject.treasurySafe, TREASURY);
        assertTrue(subject.active);

        RevenueShareSplitterV2 splitter = RevenueShareSplitterV2(result.revenueShareSplitter);
        assertEq(splitter.revenueShareSupplyDenominator(), TOTAL_SUPPLY);
        assertEq(splitter.protocolRecipient(), address(feeRouter));
    }

    function testIdentityLinkIsOptionalAndFullTupleCanBeLinked() external {
        vm.prank(CREATOR);
        IDeferredAutolaunchFactory.DeferredAutolaunchResult memory withoutIdentity =
            factory.createDeferredAutolaunch(_config(0, address(0), 0));

        assertEq(subjectRegistry.identityLinkCount(withoutIdentity.subjectId), 0);

        vm.prank(CREATOR);
        IDeferredAutolaunchFactory.DeferredAutolaunchResult memory withIdentity =
            factory.createDeferredAutolaunch(_config(8453, address(0x8004), 7));

        assertEq(subjectRegistry.identityLinkCount(withIdentity.subjectId), 1);
        assertEq(
            subjectRegistry.subjectForIdentity(8453, address(0x8004), 7), withIdentity.subjectId
        );
    }

    function testPartialIdentityTupleIsRejected() external {
        IDeferredAutolaunchFactory.DeferredAutolaunchConfig memory cfg =
            _config(8453, address(0), 0);

        vm.expectRevert("IDENTITY_REGISTRY_ZERO");
        factory.createDeferredAutolaunch(cfg);
    }

    function _config(uint256 identityChainId, address identityRegistry, uint256 identityAgentId)
        internal
        view
        returns (IDeferredAutolaunchFactory.DeferredAutolaunchConfig memory)
    {
        return IDeferredAutolaunchFactory.DeferredAutolaunchConfig({
            tokenName: "Deferred Agent",
            tokenSymbol: "DAGENT",
            totalSupply: TOTAL_SUPPLY,
            treasury: TREASURY,
            tokenFactory: address(tokenFactory),
            tokenFactoryData: abi.encode("config"),
            tokenFactorySalt: keccak256(
                abi.encode(TOKEN_SALT, identityChainId, identityRegistry, identityAgentId)
            ),
            subjectLabel: "Deferred agent",
            identityChainId: identityChainId,
            identityRegistry: identityRegistry,
            identityAgentId: identityAgentId
        });
    }
}
