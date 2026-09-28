// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BaseBindings} from "../../src/bindings/BaseBindings.sol";
import {ConditionalVestingEscrowV2} from "../../src/escrow/ConditionalVestingEscrowV2.sol";
import {RegentsAutolaunchFactoryV2} from "../../src/factory/RegentsAutolaunchFactoryV2.sol";
import {SubjectSplitterV1} from "../../src/revenue/SubjectSplitterV1.sol";
import {RegentLBPStrategyV2} from "../../src/strategy/RegentLBPStrategyV2.sol";
import {AuctionParameters} from "continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {MaxBidPriceLib} from "continuous-clearing-auction/libraries/MaxBidPriceLib.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {UERC20Metadata} from "uerc20-factory/libraries/UERC20MetadataLibrary.sol";
import {UERC20} from "uerc20-factory/tokens/UERC20.sol";
import {AutolaunchFixture} from "../integration/AutolaunchFixture.sol";
import {InertTreasury} from "../mocks/InertTreasury.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice `C4-I3` and `C4-I4`: one `launch` call produces exactly one canonical SUBJECT, one
///         pending escrow and one canonical CCA auction, with a fixed supply, a fixed split, a fixed
///         schedule, no caller-chosen entropy, and complete isolation between launches.
contract AutolaunchFactoryLaunchTest is AutolaunchFixture {
    /// @notice The price a bid of exactly the floor raise clears at: the exact Q96 price at which the
    ///         floor raise buys the whole 20 billion allocation, rounded up. The floor is that same
    ///         quotient rounded down, so the book settles one Q96 unit above the floor.
    uint256 internal constant FLOOR_RAISE_CLEARING_PRICE_Q96 = 79_228_162_514_264_337_593_501;

    event LaunchCreated(
        uint256 indexed launchId,
        address indexed launcher,
        address indexed subject,
        address auction,
        address escrow,
        address treasury,
        uint256 floorPriceQ96,
        uint128 requiredRegentRaised,
        uint64 startBlock,
        uint64 endBlock
    );

    function setUp() public {
        _deployAutolaunch();
    }

    /// @notice `FAC-001`: IDs start at one, rise by exactly one per successful launch, and zero is
    ///         the absent sentinel rather than a launch.
    function test_FAC_001_LaunchUsesSequentialIdentity() public {
        assertEq(factory.nextLaunchId(), 1, "IDs do not start at one");
        assertEq(factory.launches(0).subject, address(0), "zero is not the absent sentinel");

        Launched[3] memory launches;
        for (uint256 i; i < 3; ++i) {
            launches[i] = _launchAs(launcher, _params());
            assertEq(launches[i].launchId, i + 1, "launch ID is not sequential");
            assertEq(factory.nextLaunchId(), i + 2, "nextLaunchId did not advance by exactly one");
        }

        for (uint256 i; i < 3; ++i) {
            RegentsAutolaunchFactoryV2.Launch memory record = factory.launches(i + 1);
            assertEq(record.subject, address(launches[i].subject), "the record names another SUBJECT");
            assertEq(record.auction, address(launches[i].auction), "the record names another auction");
            assertEq(record.escrow, address(launches[i].escrow), "the record names another escrow");
            assertEq(factory.launchIdOfSubject(address(launches[i].subject)), i + 1, "the reverse index disagrees");
        }

        // A failed launch consumes no ID: the whole call, allocation included, rolls back.
        RegentsAutolaunchFactoryV2.LaunchParams memory bad = _params();
        bad.name = "";
        vm.expectRevert(abi.encodeWithSelector(RegentsAutolaunchFactoryV2.EmptyMetadataField.selector, uint256(0)));
        vm.prank(launcher);
        factory.launch(bad);
        assertEq(factory.nextLaunchId(), 4, "a failed launch consumed an ID");
    }

    /// @notice `FAC-002`: the only launch-specific entropy the factory supplies is the launch ID,
    ///         used as UERC20 graffiti and as the CCA caller salt. No caller chooses anything.
    /// @dev Both upstream derivations are recomputed here from their own pinned rules, so the claim
    ///      is that the addresses are exactly what those rules produce from the ID — not merely that
    ///      two launches differ.
    function test_FAC_002_SaltDerivesOnlyFromLaunchId() public {
        RegentsAutolaunchFactoryV2.LaunchParams memory params = _params();

        for (uint256 id = 1; id <= 2; ++id) {
            address predictedSubject =
                uerc20Factory.getUERC20Address(params.name, params.symbol, 18, address(factory), bytes32(id));
            Launched memory launched = _launchAs(launcher, params);

            assertEq(launched.launchId, id, "unexpected launch ID");
            assertEq(address(launched.subject), predictedSubject, "SUBJECT is not at the ID-derived UERC20 address");
            assertEq(launched.subject.graffiti(), bytes32(id), "graffiti is not the launch ID");
            assertEq(
                address(launched.auction),
                _predictedAuction(address(launched.subject), address(launched.escrow), id),
                "the auction is not at the ID-derived CCA address"
            );
        }

        // The signature carries exactly the eight admitted fields, so there is nowhere for a
        // user-supplied salt to enter.
        assertEq(
            RegentsAutolaunchFactoryV2.launch.selector,
            bytes4(keccak256("launch((string,string,string,string,string,address,uint256,uint128))")),
            "the launch signature is not the admitted eight-field tuple"
        );

        // C5 correction: name and symbol *do* move the created address, because the pinned UERC20
        // factory hashes its own identity fields — name, symbol, decimals, creator, graffiti — into
        // its CREATE2 salt. That is upstream identity derivation, not an Autolaunch salt.
        uint256 nextId = factory.nextLaunchId();
        address base = uerc20Factory.getUERC20Address(params.name, params.symbol, 18, address(factory), bytes32(nextId));
        assertTrue(
            uerc20Factory.getUERC20Address("Another Name", params.symbol, 18, address(factory), bytes32(nextId))
                != base,
            "the name does not reach the pinned UERC20 address derivation"
        );
        assertTrue(
            uerc20Factory.getUERC20Address(params.name, "OTHR", 18, address(factory), bytes32(nextId)) != base,
            "the symbol does not reach the pinned UERC20 address derivation"
        );

        // And it confers nothing. The creator is always this factory, the graffiti is always the
        // launch ID, and the resulting token is an admitted SUBJECT only because the factory made it.
        Launched memory chosen = _launchAs(outsider, params);
        assertEq(address(chosen.subject), base, "a launcher-chosen name did not land at the derived address");
        assertEq(chosen.subject.creator(), address(factory), "a launcher became the creator by choosing a name");
        assertEq(chosen.subject.graffiti(), bytes32(nextId), "a launcher moved the graffiti by choosing a name");
        assertEq(factory.launches(chosen.launchId).launcher, outsider, "provenance is recorded");
        assertEq(_distribution(chosen).treasury, params.treasury, "a launcher gained authority by choosing a name");
    }

    /// @notice `FAC-003`: two launches may carry byte-identical metadata; the launch ID alone keeps
    ///         their tokens, escrows and auctions distinct.
    function test_FAC_003_DuplicateNamesAndSymbolsAreAllowed() public {
        RegentsAutolaunchFactoryV2.LaunchParams memory params = _params();
        Launched memory first = _launchAs(launcher, params);
        Launched memory second = _launchAs(outsider, params);

        assertEq(first.subject.name(), second.subject.name(), "the two launches did not share a name");
        assertEq(first.subject.symbol(), second.subject.symbol(), "the two launches did not share a symbol");
        assertTrue(address(first.subject) != address(second.subject), "duplicate metadata collided");
        assertTrue(address(first.escrow) != address(second.escrow), "the escrows collided");
        assertTrue(address(first.auction) != address(second.auction), "the auctions collided");
        assertEq(first.subject.graffiti(), bytes32(uint256(1)), "first graffiti");
        assertEq(second.subject.graffiti(), bytes32(uint256(2)), "second graffiti");
    }

    /// @notice `FAC-004`: exactly one hundred billion 18-decimal SUBJECT exist and they sit in
    ///         exactly three places in exactly the fixed proportions.
    function test_FAC_004_SupplySplitsExactlyTwentyFifteenSixtyFive() public {
        Launched memory launched = _defaultLaunch();
        UERC20 subject = launched.subject;

        assertEq(subject.totalSupply(), 100_000_000_000e18, "supply is not one hundred billion");
        assertEq(subject.decimals(), 18, "supply is not 18-decimal");

        uint256 auctionHeld = subject.balanceOf(address(launched.auction));
        uint256 reserveHeld = subject.balanceOf(address(strategy));
        uint256 escrowHeld = subject.balanceOf(address(launched.escrow));

        assertEq(auctionHeld, 20_000_000_000e18, "the auction does not hold exactly 20%");
        assertEq(reserveHeld, 15_000_000_000e18, "the strategy reserve is not exactly 15%");
        assertEq(escrowHeld, 65_000_000_000e18, "escrow does not hold exactly 65%");
        assertEq(auctionHeld + reserveHeld + escrowHeld, subject.totalSupply(), "the three parts are not the whole");

        assertEq(subject.balanceOf(address(factory)), 0, "the factory kept SUBJECT");
        assertEq(subject.balanceOf(launcher), 0, "the launcher received SUBJECT");
        assertEq(subject.balanceOf(treasury), 0, "the treasury received SUBJECT before graduation");
        assertEq(subject.balanceOf(BaseBindings.DEAD_ADDRESS), 0, "SUBJECT was retired at launch");
    }

    /// @notice `STR-017`: the canonical initialization moves exactly 20%, 15% and 65% through the
    ///         factory-created graph and leaves no rounding residue anywhere.
    function test_STR_017_DistributionIsExactlyTwentyFifteenSixtyFive() public {
        Launched memory launched = _defaultLaunch();
        RegentLBPStrategyV2.Distribution memory d = _distribution(launched);

        assertEq(uint256(d.reserve), strategy.RESERVE_ALLOCATION(), "the recorded reserve is not the fixed 15%");
        assertEq(
            launched.subject.balanceOf(address(strategy)),
            uint256(d.reserve),
            "the strategy's custody does not equal the recorded reserve"
        );
        assertEq(
            launched.subject.balanceOf(address(launched.auction)),
            uint256(strategy.AUCTION_ALLOCATION()),
            "the auction did not receive exactly the fixed 20%"
        );
        assertEq(
            launched.subject.balanceOf(address(launched.escrow)),
            strategy.PENDING_ALLOCATION(),
            "escrow did not receive exactly the fixed 65%"
        );
        assertEq(
            strategy.AUCTION_ALLOCATION() + strategy.RESERVE_ALLOCATION(),
            strategy.DISTRIBUTION_PULL(),
            "the 35% pull is not exactly the auction plus the reserve"
        );
        assertEq(launched.subject.balanceOf(address(factory)), 0, "an initialization residue stayed at the factory");
        assertEq(launched.subject.balanceOf(address(uerc20Factory)), 0, "a residue stayed at the token factory");

        // A second launch's reserve is its own; the shared strategy custodies both separately.
        Launched memory other = _launchAs(outsider, _params());
        assertEq(uint256(_distribution(other).reserve), strategy.RESERVE_ALLOCATION(), "the second reserve is wrong");
        assertEq(
            launched.subject.balanceOf(address(strategy)),
            strategy.RESERVE_ALLOCATION(),
            "the first launch's reserve changed when a second launched"
        );
    }

    /// @notice `FAC-011`: every auction starts exactly 300 blocks after the block that created it,
    ///         whatever block that is and whoever the launcher is.
    function test_FAC_011_AuctionStartIsAlwaysBlockNumberPlus300() public {
        assertEq(strategy.START_DELAY_BLOCKS(), 300, "the frozen start delay is not 300 blocks");
        uint256[3] memory heights = [uint256(1_000_000), 1_000_001, 9_876_543];
        for (uint256 i; i < heights.length; ++i) {
            vm.roll(heights[i]);
            Launched memory launched = _launchAs(launcher, _params());
            assertEq(uint256(launched.auction.startBlock()), heights[i] + 300, "the start is not block.number + 300");
            assertEq(
                uint256(launched.auction.endBlock()),
                heights[i] + 300 + strategy.AUCTION_DURATION_BLOCKS(),
                "the end is not the start plus the fixed duration"
            );
        }
    }

    /// @notice `FAC-012`: a launcher supplies no start, hook, pool setting, Safe, identity or salt, and
    ///         two different launchers in one block with the same floor and minimum receive
    ///         byte-identical economics.
    function test_FAC_012_NoUserSuppliedStartHookPoolSafeIdentityOrSalt() public {
        Launched memory first = _launchAs(launcher, _params());
        Launched memory second = _launchAs(outsider, _params());

        assertEq(first.auction.startBlock(), second.auction.startBlock(), "starts differ between launchers");
        assertEq(first.auction.endBlock(), second.auction.endBlock(), "ends differ between launchers");
        assertEq(first.auction.claimBlock(), second.auction.claimBlock(), "claim blocks differ between launchers");
        assertEq(first.auction.floorPrice(), DEFAULT_FLOOR_Q96, "the floor is not the launch's floor");
        assertEq(second.auction.floorPrice(), DEFAULT_FLOOR_Q96, "the floor is not the launch's floor");
        assertEq(first.auction.tickSpacing(), DEFAULT_TICK_Q96, "the bid tick is not one hundredth of the floor");
        assertEq(first.auction.tokensRecipient(), address(strategy), "the tokens recipient is not the strategy");
        assertEq(address(first.auction.validationHook()), address(0), "a validation hook was supplied");
        assertEq(first.auction.currency(), BaseBindings.REGENT, "the auction currency is not REGENT");
        assertEq(first.auction.fundsRecipient(), address(strategy), "the funds recipient is not the shared strategy");

        PoolKey memory key = strategy.poolKeyOf(address(first.subject));
        assertEq(address(key.hooks), address(hook), "the pool hook is not the one shared hook");
        assertEq(key.fee, 3000, "the pool fee is not the fixed 0.30%");
        assertEq(key.tickSpacing, int24(60), "the pool tick spacing is not the fixed 60");

        // Neither the launch record nor the runtime exposes a caller-chosen Safe or identity.
        RegentsAutolaunchFactoryV2.Launch memory record = factory.launches(first.launchId);
        assertEq(record.launcher, launcher, "the record does not name the launcher");
        bytes memory runtime = address(factory).code;
        string[6] memory forbidden = [
            "launchWithSalt((string,string,string,string,string,address,uint256,uint128),bytes32)",
            "setStartDelay(uint64)",
            "setFloorPrice(uint256)",
            "setPoolFee(uint24)",
            "setSafe(address)",
            "setIdentity(uint256,address)"
        ];
        for (uint256 i; i < forbidden.length; ++i) {
            assertFalse(
                _carriesSelector(runtime, bytes4(keccak256(bytes(forbidden[i])))),
                string.concat("a caller-chosen surface exists: ", forbidden[i])
            );
        }
    }

    /// @notice `FAC-013`: every metadata field must be nonempty and within its exact byte cap.
    function test_FAC_013_MetadataIsNonemptyAndByteBounded() public {
        assertEq(factory.MAX_NAME_BYTES(), 64, "name cap");
        assertEq(factory.MAX_SYMBOL_BYTES(), 16, "symbol cap");
        assertEq(factory.MAX_DESCRIPTION_BYTES(), 512, "description cap");
        assertEq(factory.MAX_WEBSITE_BYTES(), 256, "website cap");
        assertEq(factory.MAX_IMAGE_BYTES(), 256, "image cap");

        uint256[5] memory caps = [uint256(64), 16, 512, 256, 256];
        for (uint256 field; field < 5; ++field) {
            _expectMetadataRevert(
                _withField(field, ""),
                abi.encodeWithSelector(RegentsAutolaunchFactoryV2.EmptyMetadataField.selector, field)
            );
            _expectMetadataRevert(
                _withField(field, _repeat(caps[field] + 1)),
                abi.encodeWithSelector(
                    RegentsAutolaunchFactoryV2.MetadataFieldTooLong.selector, field, caps[field], caps[field] + 1
                )
            );
        }
        assertEq(factory.nextLaunchId(), 1, "a rejected metadata launch allocated an ID");
    }

    /// @notice `FAC-014`: the caps are byte caps, not character caps. Exactly-at-cap input is
    ///         accepted, one byte over is refused, and malformed UTF-8 is carried through unchanged.
    function test_FAC_014_MetadataBoundaryInputsBehaveExactly() public {
        RegentsAutolaunchFactoryV2.LaunchParams memory params = _params();
        params.name = _repeat(64);
        params.symbol = _repeat(16);
        params.description = _repeat(512);
        params.website = _repeat(256);
        params.image = _repeat(256);

        Launched memory maxed = _launchAs(launcher, params);
        assertEq(bytes(maxed.subject.name()).length, 64, "the maximum name did not survive");
        assertEq(bytes(maxed.subject.symbol()).length, 16, "the maximum symbol did not survive");
        (string memory description, string memory website, string memory image) = maxed.subject.metadata();
        assertEq(bytes(description).length, 512, "the maximum description did not survive");
        assertEq(bytes(website).length, 256, "the maximum website did not survive");
        assertEq(bytes(image).length, 256, "the maximum image did not survive");

        // Malformed UTF-8: a lone continuation byte, a truncated sequence, and an embedded NUL are
        // all just bytes here. The factory performs no normalization or character policy.
        RegentsAutolaunchFactoryV2.LaunchParams memory malformed = _params();
        malformed.name = _raw(hex"80ff00fe");
        malformed.symbol = _raw(hex"e2");
        malformed.description = _raw(hex"f0289c8c");
        Launched memory odd = _launchAs(launcher, malformed);
        assertEq(bytes(odd.subject.name()), hex"80ff00fe", "malformed name bytes were altered");
        assertEq(bytes(odd.subject.symbol()), hex"e2", "malformed symbol bytes were altered");
        assertEq(bytes(odd.subject.name()).length, 4, "a malformed name is measured in bytes");

        // One byte over any cap is still one byte over, malformed or not.
        RegentsAutolaunchFactoryV2.LaunchParams memory over = _params();
        over.symbol = _repeat(17);
        _expectMetadataRevert(
            over,
            abi.encodeWithSelector(
                RegentsAutolaunchFactoryV2.MetadataFieldTooLong.selector, uint256(1), uint256(16), uint256(17)
            )
        );
    }

    /// @notice `FAC-015`: the launch treasury is fixed at launch and nothing anywhere can move it.
    function test_FAC_015_TreasuryIsImmutable() public {
        address otherTreasury = makeAddr("otherTreasury");
        Launched memory launched = _defaultLaunch();

        assertEq(launched.escrow.treasury(), treasury, "escrow bound another treasury");
        assertEq(_distribution(launched).treasury, treasury, "the strategy recorded another treasury");
        assertEq(factory.launches(launched.launchId).treasury, treasury, "the factory recorded another treasury");

        // A second launch with a different treasury changes nothing about the first.
        RegentsAutolaunchFactoryV2.LaunchParams memory params = _params();
        params.treasury = otherTreasury;
        Launched memory second = _launchAs(outsider, params);
        assertEq(second.escrow.treasury(), otherTreasury, "the second escrow bound the wrong treasury");
        assertEq(launched.escrow.treasury(), treasury, "the first treasury moved");

        // No treasury setter exists on the escrow or on the factory. C5 correction: the scan runs
        // against the escrow *implementation*, never against a 44-byte clone. A minimal proxy
        // carries no dispatcher at all, so scanning one proves nothing about the surface it
        // forwards to; the implementation artifact is the ABI authority.
        string[3] memory forbidden = ["setTreasury(address)", "changeTreasury(address)", "setBeneficiary(address)"];
        for (uint256 i; i < forbidden.length; ++i) {
            bytes4 selector = bytes4(keccak256(bytes(forbidden[i])));
            assertFalse(_carriesSelector(address(escrowImplementation).code, selector), "escrow treasury setter");
            assertFalse(_carriesSelector(address(factory).code, selector), "factory treasury setter");
        }

        // The treasury survives all the way into the graduated splitter.
        _bidToGraduation(launched, FLOOR_RAISE);
        strategy.migrate(address(launched.auction));
        assertEq(
            SubjectSplitterV1(_distribution(launched).splitter).treasury(),
            treasury,
            "graduation bound another treasury"
        );

        _assertTreasuryBlastRadiusIsOneLaunch();
    }

    /// @notice `FAC-015`: value a launcher deliberately routes to another launch's artifact is not
    ///         promised to stay isolated. Lifecycle state and the isolated 15% reserve still are.
    /// @dev The named accepted consequence, produced exactly as production produces it and with no
    ///      predicted address anywhere. A first launch graduates and its splitter becomes a real,
    ///      deployed, ordinary contract. A second launcher then names *that already-deployed
    ///      splitter* as its own treasury, and launch-time admission accepts it: admission judges six
    ///      exact shared-system addresses and nothing else, so an existing Autolaunch artifact is an
    ///      ordinary launcher-selected destination. The second launch's own vested payout then sits
    ///      inside the first launch's ordinary accounting, where permissionless recovery sends it to
    ///      the first launch's treasury. Nothing about it corrupts either launch's lifecycle or
    ///      reserve.
    function test_FAC_015_CrossLaunchTreasuryIsNotValueIsolated() public {
        Launched memory host = _launchSorted(false, _params());
        _bidToGraduation(host, FLOOR_RAISE);
        strategy.migrate(address(host.auction));

        address hostSplitter = _distribution(host).splitter;
        assertGt(hostSplitter.code.length, 0, "the host launch's splitter is not deployed");

        // The second launcher names that deployed splitter, and admission accepts it.
        RegentsAutolaunchFactoryV2.LaunchParams memory guestParams = _params();
        guestParams.treasury = hostSplitter;
        Launched memory guest = _launchSorted(true, guestParams);
        assertEq(_distribution(guest).treasury, hostSplitter, "the guest launch did not record the treasury it chose");
        assertEq(SubjectSplitterV1(hostSplitter).treasury(), treasury, "the host splitter changed its own treasury");

        _bidToGraduation(guest, FLOOR_RAISE);
        strategy.migrate(address(guest.auction));
        assertEq(
            SubjectSplitterV1(_distribution(guest).splitter).treasury(),
            hostSplitter,
            "the guest launch did not keep the treasury it chose"
        );

        // The guest launch's own vested payout, released by its own permissionless escrow call.
        vm.warp(block.timestamp + 30 days);
        guest.escrow.release();
        uint256 crossed = guest.subject.balanceOf(hostSplitter);
        assertGt(crossed, 0, "the guest launch paid its chosen treasury nothing");

        // It is now the host launch's inventory, and anyone may route it to the host's treasury.
        vm.prank(outsider);
        SubjectSplitterV1(hostSplitter).recoverUnsupportedToken(address(guest.subject));
        assertEq(guest.subject.balanceOf(treasury), crossed, "the guest launch's payout did not cross launches");

        // What stays isolated: each launch's lifecycle, its own reserve, and its own SUBJECT ledger.
        assertEq(
            uint8(_distribution(host).lifecycle),
            uint8(RegentLBPStrategyV2.Lifecycle.Graduated),
            "the host launch's lifecycle was disturbed"
        );
        assertEq(
            uint8(_distribution(guest).lifecycle),
            uint8(RegentLBPStrategyV2.Lifecycle.Graduated),
            "the guest launch's lifecycle was disturbed"
        );
        assertEq(SubjectSplitterV1(hostSplitter).totalStaked(), 0, "the crossed value was counted as staked principal");
        assertEq(
            SubjectSplitterV1(hostSplitter).unclaimedLiability(address(host.subject)),
            0,
            "the crossed value was recognized as the host launch's revenue"
        );
        assertEq(host.subject.totalSupply(), TOTAL_SUPPLY, "the host launch's supply moved");
        assertEq(guest.subject.totalSupply(), TOTAL_SUPPLY, "the guest launch's supply moved");
    }

    /// @dev `FAC-015`, C5 correction: the treasury is launcher-chosen as well as immutable, so its
    ///      blast radius is worth naming. A treasury that can never move a token strands its own
    ///      launch's payouts permanently — and reaches nothing else. A second launch created in the
    ///      same factory, sharing the same strategy and the same hook, graduates normally, registers
    ///      its own pool, and gets its own splitter and receiver. No denylist is added: the damage is
    ///      confined by construction, because every payout destination is per-launch.
    function _assertTreasuryBlastRadiusIsOneLaunch() private {
        // A deployed contract with no token-moving surface at all. Anything sent here is stranded.
        address strandingTreasury = address(new InertTreasury());

        RegentsAutolaunchFactoryV2.LaunchParams memory bad = _params();
        bad.treasury = strandingTreasury;
        Launched memory stranded = _launchSorted(true, bad);

        RegentsAutolaunchFactoryV2.LaunchParams memory good = _params();
        Launched memory healthy = _launchSorted(false, good);

        _rollToStart(stranded);
        _bid(stranded, bidder, FLOOR_RAISE, _bidPrice(10));
        _bid(healthy, bidder, FLOOR_RAISE, _bidPrice(10));
        _rollToMigration(healthy);

        strategy.migrate(address(stranded.auction));
        strategy.migrate(address(healthy.auction));

        RegentLBPStrategyV2.Distribution memory bruised = _distribution(stranded);
        RegentLBPStrategyV2.Distribution memory intact = _distribution(healthy);

        // The bad launch graduated and then stranded its own value, exactly where it chose to.
        assertEq(uint8(bruised.lifecycle), uint8(RegentLBPStrategyV2.Lifecycle.Graduated), "the bad launch stalled");
        assertGt(strandingTreasury.code.length, 0, "the stranding treasury is not a deployed contract");

        // Time moves forward only. Once part of the schedule has vested, the permissionless release
        // pays the launch's own immutable treasury, where it stays for good.
        vm.warp(block.timestamp + 30 days);
        stranded.escrow.release();
        assertGt(stranded.subject.balanceOf(strandingTreasury), 0, "the stranding treasury received nothing to strand");
        assertEq(
            SubjectSplitterV1(bruised.splitter).treasury(), strandingTreasury, "the bad splitter escaped its treasury"
        );

        // And the other launch is untouched: its own treasury, its own pool, its own infrastructure.
        assertEq(uint8(intact.lifecycle), uint8(RegentLBPStrategyV2.Lifecycle.Graduated), "the healthy launch stalled");
        assertEq(SubjectSplitterV1(intact.splitter).treasury(), treasury, "the healthy splitter took the bad treasury");
        assertEq(hook.splitterOf(_poolId(healthy)), intact.splitter, "the healthy pool did not register");
        assertEq(hook.splitterOf(_poolId(stranded)), bruised.splitter, "the two launches shared a pool registration");
        assertTrue(intact.splitter != bruised.splitter, "the two launches shared a splitter");
        assertTrue(intact.receiver != bruised.receiver, "the two launches shared a receiver");
        healthy.escrow.release();
        assertGt(healthy.subject.balanceOf(treasury), 0, "the healthy launch could not pay its own treasury");
        assertEq(healthy.subject.balanceOf(strandingTreasury), 0, "the bad treasury reached the healthy launch");
        assertEq(stranded.subject.balanceOf(treasury), 0, "the healthy treasury reached the stranded launch");

        // The shared hook retains nothing attributable through either launch.
        assertEq(regent.balanceOf(address(hook)), 0, "the shared hook retained REGENT");
    }

    /// @notice `FAC-017`: being the launcher is provenance and nothing else.
    function test_FAC_017_LauncherProvenanceGivesNoAuthority() public {
        Launched memory launched = _defaultLaunch();
        assertEq(factory.launches(launched.launchId).launcher, launcher, "the launcher was not recorded");

        vm.expectRevert(abi.encodeWithSelector(RegentsAutolaunchFactoryV2.NotGovernance.selector, launcher));
        vm.prank(launcher);
        factory.pauseLaunches();

        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategyV2.NotFactory.selector, launcher));
        vm.prank(launcher);
        strategy.bindHook(outsider);

        vm.expectRevert(abi.encodeWithSelector(ConditionalVestingEscrowV2.NotStrategy.selector, launcher));
        vm.prank(launcher);
        launched.escrow.resolveFailure(address(launched.auction));

        assertEq(launched.subject.balanceOf(launcher), 0, "the launcher holds launch SUBJECT");
        assertEq(regent.balanceOf(launcher), 0, "the launcher kept REGENT from the launch");

        // Vested SUBJECT goes to the immutable treasury, never to the launcher.
        _bidToGraduation(launched, FLOOR_RAISE);
        vm.prank(outsider);
        strategy.migrate(address(launched.auction));
        vm.warp(block.timestamp + 365 days);
        vm.prank(launcher);
        launched.escrow.release();
        assertEq(launched.subject.balanceOf(launcher), 0, "releasing paid the launcher");
        assertGt(launched.subject.balanceOf(treasury), 0, "releasing did not pay the treasury");
    }

    /// @notice `FAC-020`: one transaction produces the token, the auction and the escrow together,
    ///         all of them agreeing, and announces exactly that.
    function test_FAC_020_CompleteLaunchProducesTokenAuctionAndEscrow() public {
        RegentsAutolaunchFactoryV2.LaunchParams memory params = _params();

        uint64 expectedStart = uint64(block.number) + strategy.START_DELAY_BLOCKS();
        address expectedSubject =
            uerc20Factory.getUERC20Address(params.name, params.symbol, 18, address(factory), bytes32(uint256(1)));

        vm.recordLogs();
        vm.prank(launcher);
        (uint256 launchId, address subject, address auction, address escrow) = factory.launch(params);

        assertEq(launchId, 1, "launch ID");
        assertEq(subject, expectedSubject, "the returned SUBJECT is not the derived one");
        assertTrue(subject.code.length != 0, "the SUBJECT has no code");
        assertTrue(auction.code.length != 0, "the auction has no code");
        assertTrue(escrow.code.length != 0, "the escrow has no code");

        assertEq(UERC20(subject).creator(), address(factory), "the SUBJECT creator is not the factory");
        assertEq(ConditionalVestingEscrowV2(escrow).subject(), subject, "the escrow is bound to another SUBJECT");
        assertEq(ConditionalVestingEscrowV2(escrow).strategy(), address(strategy), "the escrow is misbound");
        assertEq(
            uint8(ConditionalVestingEscrowV2(escrow).lifecycle()),
            uint8(ConditionalVestingEscrowV2.Lifecycle.Pending),
            "the escrow is not pending"
        );
        assertEq(strategy.auctionOfSubject(subject), auction, "the strategy did not record this auction");

        RegentLBPStrategyV2.Distribution memory d = strategy.distribution(auction);
        assertEq(uint8(d.lifecycle), uint8(RegentLBPStrategyV2.Lifecycle.Active), "the launch is not active");
        assertEq(d.startBlock, expectedStart, "the recorded start is not the fixed start");

        _assertLaunchCreated(launchId, subject, auction, escrow, params, d.startBlock, d.endBlock);
    }

    /// @notice `FAC-022`: two launches created in one block share the one strategy and the one hook,
    ///         start together, and stay completely disjoint through opposite terminal states.
    /// @dev One monotone timeline: create both, move forward once to their shared start, bid
    ///      independently, then move forward once to terminal eligibility. Nothing rewinds.
    function test_FAC_022_SimultaneousLaunchesShareOneStrategyAndHookAndStayIsolated() public {
        uint256 creationBlock = block.number;
        Launched memory first = _launchSorted(true, _params());
        Launched memory second = _launchSorted(false, _params());
        assertEq(block.number, creationBlock, "the two launches were not created in one block");

        assertEq(first.launchId, 1, "first ID");
        assertEq(second.launchId, 2, "second ID");
        assertEq(first.auction.startBlock(), second.auction.startBlock(), "simultaneous launches start apart");
        assertTrue(address(first.subject) != address(second.subject), "the SUBJECTs collided");
        assertTrue(address(first.escrow) != address(second.escrow), "the escrows collided");
        assertTrue(address(first.auction) != address(second.auction), "the auctions collided");

        assertEq(strategy.auctionOfSubject(address(first.subject)), address(first.auction), "first auction index");
        assertEq(strategy.auctionOfSubject(address(second.subject)), address(second.auction), "second auction index");
        assertEq(
            first.subject.balanceOf(address(strategy)) + second.subject.balanceOf(address(strategy)),
            2 * RESERVE_ALLOCATION,
            "the shared strategy does not custody both reserves"
        );

        vm.roll(first.auction.startBlock());
        _bid(first, bidder, FLOOR_RAISE, _bidPrice(10));
        vm.roll(uint256(first.auction.endBlock()) + strategy.MIGRATION_DELAY_BLOCKS());

        strategy.migrate(address(first.auction));
        strategy.migrate(address(second.auction));

        RegentLBPStrategyV2.Distribution memory a = _distribution(first);
        RegentLBPStrategyV2.Distribution memory b = _distribution(second);
        assertEq(
            uint8(a.lifecycle), uint8(RegentLBPStrategyV2.Lifecycle.Graduated), "the bid-on launch did not graduate"
        );
        assertEq(uint8(b.lifecycle), uint8(RegentLBPStrategyV2.Lifecycle.Failed), "the unbid launch did not fail");

        assertTrue(a.splitter != address(0), "the graduated launch has no splitter");
        assertEq(b.splitter, address(0), "the failed launch created a splitter");
        assertEq(
            second.subject.balanceOf(BaseBindings.DEAD_ADDRESS), TOTAL_SUPPLY, "the failed launch was not retired whole"
        );
        assertEq(first.subject.balanceOf(BaseBindings.DEAD_ADDRESS), 0, "the graduated launch retired SUBJECT");
        assertEq(
            first.subject.balanceOf(address(strategy)), a.subjectShared, "the graduated launch holds only its share-out"
        );
        assertEq(second.subject.balanceOf(address(strategy)), 0, "the failed reserve was not returned");
        assertTrue(hook.splitterOf(_poolId(first)) != address(0), "the graduated pool was not registered");
        assertEq(hook.splitterOf(_poolId(second)), address(0), "the failed pool was registered");
    }

    /// @notice `FAC-023`: the launcher chooses the floor and may set a higher minimum raise; the required
    ///         raise is the whole sale allocation at the floor, rounded up, or that minimum when it is
    ///         higher, and a minimum the auction can never reach is refused.
    /// @dev The floor raise's economics are measured, not assumed: a real pinned auction, filled by a
    ///      single bid of exactly the floor raise, sells its whole allocation at the floor clearing
    ///      price and migrates in both PoolKey orderings and at both reachable bid-price endpoints —
    ///      the floor and the highest on-grid price.
    function test_FAC_023_RequiredRaiseIsTheFloorMinimumOrTheLauncherMinimum() public {
        RegentsAutolaunchFactoryV2.LaunchParams memory params = _params();

        uint128 tooHigh = uint128(strategy.maxReachableRaiseFor(DEFAULT_TICK_Q96)) + 1;
        params.minimumRegentRaised = tooHigh;
        _expectMetadataRevert(
            params, abi.encodeWithSelector(RegentLBPStrategyV2.UnreachableRequiredRaise.selector, tooHigh)
        );
        params.minimumRegentRaised = 0;
        params.floorPriceQ96 = DEFAULT_FLOOR_Q96 + 1;
        _expectMetadataRevert(
            params, abi.encodeWithSelector(RegentLBPStrategyV2.FloorPriceNotOnGrid.selector, DEFAULT_FLOOR_Q96 + 1)
        );
        assertEq(factory.nextLaunchId(), 1, "a refused launch allocated an ID");

        // No minimum, or one below the floor minimum, records the floor minimum; a higher one is kept.
        params = _params();
        Launched memory plain = _launchAs(launcher, params);
        assertEq(_distribution(plain).requiredRegentRaised, FLOOR_RAISE, "no minimum is the floor minimum");
        params.minimumRegentRaised = 1;
        Launched memory lower = _launchAs(launcher, params);
        assertEq(_distribution(lower).requiredRegentRaised, FLOOR_RAISE, "a lower minimum is the floor minimum");
        params.minimumRegentRaised = 3 * FLOOR_RAISE;
        Launched memory higher = _launchAs(launcher, params);
        assertEq(_distribution(higher).requiredRegentRaised, 3 * FLOOR_RAISE, "a higher minimum is kept");
        params.minimumRegentRaised = tooHigh - 1;
        _launchAs(launcher, params);

        // The floor-raise graduated outcome resolves at both endpoints, both orderings.
        uint256 structuralMax = MaxBidPriceLib.maxBidPrice(uint128(AUCTION_ALLOCATION));
        uint256 maxOnGridTicks =
            (structuralMax - structuralMax % DEFAULT_TICK_Q96 - DEFAULT_FLOOR_Q96) / DEFAULT_TICK_Q96;
        _assertFloorRaiseMigrates(true, 1);
        _assertFloorRaiseMigrates(false, 1);
        _assertFloorRaiseMigrates(true, maxOnGridTicks);
        _assertFloorRaiseMigrates(false, maxOnGridTicks);

        // And so does the largest admitted raise, in both orderings.
        _assertBoundaryRaiseMigrates(true, maxOnGridTicks);
        _assertBoundaryRaiseMigrates(false, maxOnGridTicks);
    }

    /// @notice `TOK-001`: an admitted SUBJECT's supply is exactly one hundred billion units.
    function test_TOK_001_TotalSupplyIsExactlyOneHundredBillion() public {
        Launched memory launched = _defaultLaunch();
        assertEq(launched.subject.totalSupply(), 100_000_000_000e18, "supply is not one hundred billion");
        assertEq(launched.subject.totalSupply(), factory.TOTAL_SUPPLY(), "supply is not the factory's constant");

        // Nothing in the launch mints or burns after creation.
        _bidToGraduation(launched, FLOOR_RAISE);
        strategy.migrate(address(launched.auction));
        assertEq(launched.subject.totalSupply(), 100_000_000_000e18, "graduation changed the supply");
    }

    /// @notice `TOK-002`: an admitted SUBJECT has exactly 18 decimals.
    function test_TOK_002_DecimalsAreEighteen() public {
        Launched memory launched = _defaultLaunch();
        assertEq(launched.subject.decimals(), 18, "SUBJECT decimals");
        assertEq(factory.SUBJECT_DECIMALS(), 18, "the factory asks for other decimals");
    }

    /// @notice `TOK-003`: only this factory creates an admitted SUBJECT. Anyone may create an
    ///         unrelated UERC20 through the same permissionless pinned factory, but it is never
    ///         recorded, never admitted, and can never become a launch.
    function test_TOK_003_AutolaunchFactoryIsTheOnlyRecordedCreator() public {
        Launched memory launched = _defaultLaunch();
        assertEq(launched.subject.creator(), address(factory), "an admitted SUBJECT names another creator");
        assertEq(factory.launchIdOfSubject(address(launched.subject)), launched.launchId, "the SUBJECT is not indexed");

        vm.prank(outsider);
        address impostor = uerc20Factory.createToken(
            "Subject One",
            "SUBJ",
            18,
            100_000_000_000e18,
            outsider,
            abi.encode(UERC20Metadata({description: "d", website: "w", image: "i"})),
            bytes32(uint256(1))
        );
        assertEq(UERC20(impostor).creator(), outsider, "the impostor did not record its own creator");
        assertEq(factory.launchIdOfSubject(impostor), 0, "an unrelated token was admitted as a SUBJECT");
        assertEq(strategy.auctionOfSubject(impostor), address(0), "an unrelated token reached the strategy");

        // And it cannot be attached to a launch: an escrow it funds is not an authentic clone of the
        // admitted implementation, so the strategy refuses it outright.
        vm.expectRevert(abi.encodeWithSelector(RegentLBPStrategyV2.NotAuthenticEscrow.selector, impostor));
        vm.prank(address(factory));
        strategy.initializeDistribution(
            RegentLBPStrategyV2.DistributionParams({
                launchId: 99, escrow: impostor, floorPriceQ96: DEFAULT_FLOOR_Q96, minimumRegentRaised: 0
            })
        );
    }

    /// @notice `TOK-004`: the token's metadata is exactly what the launch asked for and stays that
    ///         way for the life of the token.
    function test_TOK_004_LaunchMetadataIsImmutableAndEqualsItsLaunchParameters() public {
        RegentsAutolaunchFactoryV2.LaunchParams memory params = _params();
        Launched memory launched = _launchAs(launcher, params);

        assertEq(launched.subject.name(), params.name, "name");
        assertEq(launched.subject.symbol(), params.symbol, "symbol");
        (string memory description, string memory website, string memory image) = launched.subject.metadata();
        assertEq(description, params.description, "description");
        assertEq(website, params.website, "website");
        assertEq(image, params.image, "image");

        // The token exposes no way to change any of it.
        bytes memory runtime = address(launched.subject).code;
        string[6] memory forbidden = [
            "setName(string)",
            "setSymbol(string)",
            "setMetadata(string,string,string)",
            "setTokenURI(string)",
            "updateMetadata(bytes)",
            "setGraffiti(bytes32)"
        ];
        for (uint256 i; i < forbidden.length; ++i) {
            assertFalse(
                _carriesSelector(runtime, bytes4(keccak256(bytes(forbidden[i])))),
                string.concat("the token exposes: ", forbidden[i])
            );
        }

        // It is still exactly the same after the launch reaches a terminal state.
        _bidToGraduation(launched, FLOOR_RAISE);
        strategy.migrate(address(launched.auction));
        assertEq(launched.subject.name(), params.name, "the name changed at graduation");
        assertEq(launched.subject.symbol(), params.symbol, "the symbol changed at graduation");
    }

    /// @notice `TOK-005`: an admitted SUBJECT carries no mint, owner, tax, blacklist, upgrade or
    ///         administrative burn power once it exists.
    /// @dev A selector diff over the deployed token runtime, not calls to functions that must not
    ///      exist: the dispatcher carries every live selector as a literal.
    function test_TOK_005_NoPublicMintOwnerTaxBlacklistUpgradeOrAdministrativeBurn() public {
        Launched memory launched = _defaultLaunch();
        bytes memory runtime = address(launched.subject).code;

        string[4] memory live = ["totalSupply()", "balanceOf(address)", "transfer(address,uint256)", "decimals()"];
        for (uint256 i; i < live.length; ++i) {
            assertTrue(
                _carriesSelector(runtime, bytes4(keccak256(bytes(live[i])))),
                string.concat("an ordinary ERC20 surface is missing: ", live[i])
            );
        }

        string[16] memory forbidden = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burn(address,uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "setTaxRate(uint256)",
            "setFee(uint256)",
            "blacklist(address)",
            "setBlacklisted(address,bool)",
            "pause()",
            "upgradeTo(address)",
            "upgradeToAndCall(address,bytes)",
            "initialize(string,string,uint8)"
        ];
        for (uint256 i; i < forbidden.length; ++i) {
            assertFalse(
                _carriesSelector(runtime, bytes4(keccak256(bytes(forbidden[i])))),
                string.concat("the token exposes an administrative power: ", forbidden[i])
            );
        }
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    function _assertLaunchCreated(
        uint256 launchId,
        address subject,
        address auction,
        address escrow,
        RegentsAutolaunchFactoryV2.LaunchParams memory params,
        uint64 startBlock,
        uint64 endBlock
    ) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic =
            keccak256("LaunchCreated(uint256,address,address,address,address,address,uint256,uint128,uint64,uint64)");
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(factory) || logs[i].topics[0] != topic) continue;
            assertFalse(seen, "LaunchCreated was emitted more than once");
            seen = true;
            assertEq(uint256(logs[i].topics[1]), launchId, "event launch ID");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), launcher, "event launcher");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), subject, "event SUBJECT");
            (
                address loggedAuction,
                address loggedEscrow,
                address loggedTreasury,
                uint256 loggedFloor,
                uint128 loggedRaise,
                uint64 loggedStart,
                uint64 loggedEnd
            ) = abi.decode(logs[i].data, (address, address, address, uint256, uint128, uint64, uint64));
            assertEq(loggedAuction, auction, "event auction");
            assertEq(loggedEscrow, escrow, "event escrow");
            assertEq(loggedTreasury, params.treasury, "event treasury");
            assertEq(loggedFloor, params.floorPriceQ96, "event floor");
            assertEq(
                loggedRaise,
                strategy.requiredRegentRaisedFor(params.floorPriceQ96, params.minimumRegentRaised),
                "event required raise"
            );
            assertEq(loggedStart, startBlock, "event start block");
            assertEq(loggedEnd, endBlock, "event end block");
        }
        assertTrue(seen, "the launch announced nothing");
    }

    function _predictedAuction(address subject, address escrow, uint256 launchId) private view returns (address) {
        bytes memory configData = abi.encode(
            AuctionParameters({
                currency: BaseBindings.REGENT,
                tokensRecipient: address(strategy),
                fundsRecipient: address(strategy),
                startBlock: uint64(block.number) + strategy.START_DELAY_BLOCKS(),
                endBlock: uint64(block.number) + strategy.START_DELAY_BLOCKS() + strategy.AUCTION_DURATION_BLOCKS(),
                claimBlock: uint64(block.number) + strategy.START_DELAY_BLOCKS() + strategy.AUCTION_DURATION_BLOCKS()
                    + strategy.CLAIM_DELAY_BLOCKS(),
                tickSpacing: DEFAULT_TICK_Q96,
                validationHook: address(0),
                floorPrice: DEFAULT_FLOOR_Q96,
                requiredCurrencyRaised: FLOOR_RAISE,
                auctionStepsData: strategy.AUCTION_STEPS()
            })
        );
        return
            address(
                ccaFactory.getAddress(subject, AUCTION_ALLOCATION, configData, bytes32(launchId), address(strategy))
            );
    }

    function _assertFloorRaiseMigrates(bool subjectBelowRegent, uint256 ticksAboveFloor) private {
        uint256 snap = vm.snapshotState();
        Launched memory launched = _launchSorted(subjectBelowRegent, _params());

        _rollToStart(launched);
        _bid(launched, bidder, FLOOR_RAISE, _bidPrice(ticksAboveFloor));
        _rollToMigration(launched);

        strategy.migrate(address(launched.auction));
        assertTrue(launched.auction.isGraduated(), "a floor raise did not graduate");
        assertEq(uint256(launched.auction.currencyRaised()), FLOOR_RAISE, "the raise was not the floor");
        assertEq(
            uint8(_distribution(launched).lifecycle),
            uint8(RegentLBPStrategyV2.Lifecycle.Graduated),
            "the smallest reachable graduated outcome did not resolve"
        );

        // A bid's maximum price is not the price the auction settles on: a bid of exactly the floor
        // raise pays for the whole allocation and nothing beyond it, so the book clears at the one
        // price where that raise buys the whole allocation, whichever tick the bidder would pay to.
        assertEq(
            launched.auction.clearingPrice(),
            FLOOR_RAISE_CLEARING_PRICE_Q96,
            "a floor raise cleared somewhere other than the floor clearing price"
        );
        assertEq(
            launched.auction.lbpInitializationParams().initialPriceX96,
            FLOOR_RAISE_CLEARING_PRICE_Q96,
            "the final price handed to migration was not the floor clearing price"
        );

        // The pool opens at the raise over the whole sale allocation, so the whole reserve pairs with
        // three quarters of the raise and the last quarter reaches the treasury.
        RegentLBPStrategyV2.Distribution memory d = _distribution(launched);
        assertApproxEqRel(uint256(d.lpSubjectUsed), RESERVE_ALLOCATION, 1e12, "the whole reserve, to the crumb");
        assertLe(uint256(d.lpSubjectUsed), RESERVE_ALLOCATION, "the position consumed more than the isolated reserve");
        assertApproxEqRel(uint256(d.lpRegentUsed), (uint256(FLOOR_RAISE) * 3) / 4, 1e12, "three quarters of the raise");
        assertEq(regent.balanceOf(treasury), FLOOR_RAISE - d.lpRegentUsed, "the rest of the raise to the treasury");
        assertGt(positionManager.getPositionLiquidity(d.lpTokenId), 0, "the minted position carries no liquidity");
        require(vm.revertToState(snap), "revert to snapshot failed");
    }

    function _assertBoundaryRaiseMigrates(bool subjectBelowRegent, uint256 ticksAboveFloor) private {
        uint256 snap = vm.snapshotState();
        uint128 boundary = uint128(strategy.maxReachableRaiseFor(DEFAULT_TICK_Q96));
        RegentsAutolaunchFactoryV2.LaunchParams memory params = _params();
        params.minimumRegentRaised = boundary;
        Launched memory launched = _launchSorted(subjectBelowRegent, params);

        _rollToStart(launched);
        _bid(launched, bidder, boundary + 1, _bidPrice(ticksAboveFloor));
        _rollToMigration(launched);

        strategy.migrate(address(launched.auction));
        assertEq(
            uint256(launched.auction.currencyRaised()), uint256(boundary), "the boundary raise was not settled exactly"
        );
        assertEq(
            uint8(_distribution(launched).lifecycle),
            uint8(RegentLBPStrategyV2.Lifecycle.Graduated),
            "the largest admitted raise did not resolve"
        );
        require(vm.revertToState(snap), "revert to snapshot failed");
    }

    function _withField(uint256 field, string memory value)
        private
        view
        returns (RegentsAutolaunchFactoryV2.LaunchParams memory params)
    {
        params = _params();
        if (field == 0) params.name = value;
        if (field == 1) params.symbol = value;
        if (field == 2) params.description = value;
        if (field == 3) params.website = value;
        if (field == 4) params.image = value;
    }

    function _expectMetadataRevert(RegentsAutolaunchFactoryV2.LaunchParams memory params, bytes memory expected)
        private
    {
        vm.expectRevert(expected);
        vm.prank(launcher);
        factory.launch(params);
    }

    /// @dev A string built from raw bytes, so a malformed UTF-8 sequence can be supplied at all.
    function _raw(bytes memory value) private pure returns (string memory) {
        return string(value);
    }

    function _repeat(uint256 length) private pure returns (string memory) {
        bytes memory value = new bytes(length);
        for (uint256 i; i < length; ++i) {
            value[i] = "a";
        }
        return string(value);
    }
}
