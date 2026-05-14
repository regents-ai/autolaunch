// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {
    IPermissionlessExistingTokenRevenueFactory
} from "src/revenue/interfaces/IPermissionlessExistingTokenRevenueFactory.sol";
import {LiveStakeFeePoolSplitter} from "src/revenue/LiveStakeFeePoolSplitter.sol";
import {
    PermissionlessExistingTokenRevenueFactory
} from "src/revenue/PermissionlessExistingTokenRevenueFactory.sol";
import {RevenueIngressFactory} from "src/revenue/RevenueIngressFactory.sol";
import {SubjectRegistry} from "src/revenue/SubjectRegistry.sol";
import {MintableERC20Mock} from "test/mocks/MintableERC20Mock.sol";
import {MockRegentStakingRevenueRouter} from "test/mocks/MockRegentStakingRevenueRouter.sol";

contract NoTotalSupplyToken {}

contract PermissionlessExistingTokenRevenueFactoryTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant CREATOR = address(0x1111);
    address internal constant OTHER_CREATOR = address(0x2222);
    address internal constant TREASURY = address(0x3333);
    bytes32 internal constant SALT = keccak256("salt");

    MintableERC20Mock internal usdc;
    MintableERC20Mock internal stakeToken;
    SubjectRegistry internal subjectRegistry;
    RevenueIngressFactory internal ingressFactory;
    MockRegentStakingRevenueRouter internal feeRouter;
    PermissionlessExistingTokenRevenueFactory internal factory;

    function setUp() external {
        usdc = new MintableERC20Mock("USD Coin", "USDC");
        stakeToken = new MintableERC20Mock("Agent", "AGENT");
        stakeToken.mint(address(0x9999), 1000e18);
        subjectRegistry = new SubjectRegistry(OWNER);
        ingressFactory = new RevenueIngressFactory(address(usdc), address(subjectRegistry), OWNER);
        feeRouter = new MockRegentStakingRevenueRouter(address(usdc), address(0x8888));
        factory = new PermissionlessExistingTokenRevenueFactory(
            OWNER, address(usdc), address(ingressFactory), subjectRegistry, feeRouter
        );

        vm.startPrank(OWNER);
        subjectRegistry.setAuthorizedRegistrar(address(factory), true);
        ingressFactory.setAuthorizedCreator(address(factory), true);
        vm.stopPrank();
    }

    function testAnyAddressCanCreateSubjectWithoutTokenOwnershipProof() external {
        vm.recordLogs();

        vm.prank(CREATOR);
        (bytes32 subjectId, address splitter, address ingress) =
            factory.createExistingTokenRevenueSubject(_config(TREASURY, SALT));

        assertEq(
            subjectId,
            keccak256(
                abi.encode(
                    block.chainid, address(factory), address(stakeToken), TREASURY, CREATOR, SALT
                )
            )
        );
        assertTrue(splitter.code.length > 0);
        assertTrue(ingress.code.length > 0);
        assertEq(factory.splitterOfSubject(subjectId), splitter);
        assertEq(ingressFactory.defaultIngressOfSubject(subjectId), ingress);
        assertEq(subjectRegistry.getSubject(subjectId).splitter, splitter);
        assertEq(subjectRegistry.subjectOfStakeToken(address(stakeToken)), bytes32(0));
        assertTrue(subjectRegistry.canManageSubject(subjectId, TREASURY));
        assertTrue(subjectRegistry.canManageSubject(subjectId, CREATOR));
        assertEq(LiveStakeFeePoolSplitter(splitter).stakerPoolBps(), 2500);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSig = keccak256(
            "ExistingTokenRevenueSubjectCreated(bytes32,address,address,address,address,address,uint16,string)"
        );
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 4 && logs[i].topics[0] == eventSig) {
                assertEq(logs[i].topics[1], subjectId);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(stakeToken));
                assertEq(address(uint160(uint256(logs[i].topics[3]))), splitter);
                (
                    address eventIngress,
                    address eventCreator,
                    address eventTreasury,
                    uint16 eventBps,
                    string memory label
                ) = abi.decode(logs[i].data, (address, address, address, uint16, string));
                assertEq(eventIngress, ingress);
                assertEq(eventCreator, CREATOR);
                assertEq(eventTreasury, TREASURY);
                assertEq(eventBps, 2500);
                assertEq(label, "Existing token");
                found = true;
            }
        }
        assertTrue(found);
    }

    function testMultipleSubjectsCanExistForSameStakeToken() external {
        vm.prank(CREATOR);
        (bytes32 firstSubjectId,,) =
            factory.createExistingTokenRevenueSubject(_config(TREASURY, SALT));

        bytes32 secondSalt = keccak256("second");
        vm.prank(OTHER_CREATOR);
        (bytes32 secondSubjectId,,) =
            factory.createExistingTokenRevenueSubject(_config(address(0x4444), secondSalt));

        assertTrue(firstSubjectId != secondSubjectId);
        assertEq(subjectRegistry.subjectCountForStakeToken(address(stakeToken)), 2);
        assertEq(factory.subjectCountForStakeToken(address(stakeToken)), 2);
        assertEq(subjectRegistry.subjectForStakeTokenAt(address(stakeToken), 0), firstSubjectId);
        assertEq(subjectRegistry.subjectForStakeTokenAt(address(stakeToken), 1), secondSubjectId);
        assertEq(subjectRegistry.subjectOfStakeToken(address(stakeToken)), bytes32(0));
    }

    function testRejectsBadTokenAndTreasuryInputs() external {
        IPermissionlessExistingTokenRevenueFactory.ExistingTokenRevenueConfig memory cfg =
            _config(address(0), SALT);

        vm.expectRevert("TREASURY_ZERO");
        factory.createExistingTokenRevenueSubject(cfg);

        cfg = _config(TREASURY, SALT);
        cfg.stakeToken = address(0);
        vm.expectRevert("STAKE_TOKEN_ZERO");
        factory.createExistingTokenRevenueSubject(cfg);

        cfg.stakeToken = address(0xABCD);
        vm.expectRevert("STAKE_TOKEN_NOT_CONTRACT");
        factory.createExistingTokenRevenueSubject(cfg);
    }

    function testMalformedErc20RejectedByTotalSupplySmokeTest() external {
        IPermissionlessExistingTokenRevenueFactory.ExistingTokenRevenueConfig memory cfg =
            _config(TREASURY, SALT);
        cfg.stakeToken = address(new NoTotalSupplyToken());

        vm.expectRevert();
        factory.createExistingTokenRevenueSubject(cfg);
    }

    function _config(address treasury, bytes32 salt)
        internal
        view
        returns (IPermissionlessExistingTokenRevenueFactory.ExistingTokenRevenueConfig memory)
    {
        return IPermissionlessExistingTokenRevenueFactory.ExistingTokenRevenueConfig({
            stakeToken: address(stakeToken),
            treasury: treasury,
            stakerPoolBps: 2500,
            label: "Existing token",
            salt: salt
        });
    }
}
