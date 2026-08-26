// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {SubjectSplitterV1} from "../../../src/revenue/SubjectSplitterV1.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @notice Drives one real `SubjectSplitterV1` clone through every reachable caller operation and
///         keeps an accounting model of its own.
/// @dev The model here is deliberately *not* a second implementation of the splitter. It records
///         only what a caller can observe from outside — what was handed in, what was skimmed, and
///         what was paid out — so the invariants compare production storage against an independent
///         summary rather than against a mirror of the same arithmetic.
///
///      Every action is bounded to a precondition production itself enforces, and an action with
///      nothing to do returns instead of reverting. `fail_on_revert = true` therefore keeps its
///      full strength: any revert is a real one.
contract SplitterHandler is CommonBase, StdUtils {
    SubjectSplitterV1 public immutable splitter;
    MockERC20 public immutable usdc;
    MockERC20 public immutable regent;
    MockERC20 public immutable subject;
    MockERC20 public immutable unsupported;
    address public immutable regentSafe;
    address public immutable treasury;

    address[4] public actors;

    /// @notice Gross amounts handed to the splitter as recognized revenue, per token.
    mapping(address token => uint256 amount) public recognizedGross;
    /// @notice Amounts the splitter skimmed away from stakers, per token.
    mapping(address token => uint256 amount) public routedSkim;
    /// @notice Net amounts sent straight to the treasury because nothing was staked, per token.
    mapping(address token => uint256 amount) public routedToTreasury;
    /// @notice Net amounts credited to stakers, per token.
    mapping(address token => uint256 amount) public creditedToStakers;
    /// @notice Whole units actually claimed by stakers, per token.
    mapping(address token => uint256 amount) public claimedByStakers;
    /// @notice `totalStaked` at the moment this token last divided a net amount among stakers.
    /// @dev The carried scaled remainder is `numerator % totalStaked` *at that moment*, so a later
    ///      unstake legitimately leaves the carry above the current `totalStaked`. This records the
    ///      only ceiling the carry was ever measured against.
    mapping(address token => uint256 staked) public carryCeiling;

    /// @notice Principal handed in and taken back, tracked outside the splitter's own storage.
    uint256 public principalStaked;
    uint256 public principalUnstaked;

    uint256 public calls;

    constructor(
        SubjectSplitterV1 splitter_,
        MockERC20 usdc_,
        MockERC20 regent_,
        MockERC20 subject_,
        MockERC20 unsupported_,
        address regentSafe_,
        address treasury_,
        address[4] memory actors_
    ) {
        splitter = splitter_;
        usdc = usdc_;
        regent = regent_;
        subject = subject_;
        unsupported = unsupported_;
        regentSafe = regentSafe_;
        treasury = treasury_;
        actors = actors_;
    }

    // -------------------------------------------------------------------------
    // actions
    // -------------------------------------------------------------------------

    function stake(uint256 actorSeed, uint256 amount) external {
        calls += 1;
        address actor = _actor(actorSeed);
        uint256 available = subject.balanceOf(actor);
        if (available == 0) return;
        amount = bound(amount, 1, available);

        vm.startPrank(actor);
        subject.approve(address(splitter), amount);
        splitter.stake(amount);
        vm.stopPrank();

        principalStaked += amount;
    }

    function unstake(uint256 actorSeed, uint256 amount) external {
        calls += 1;
        address actor = _actor(actorSeed);
        uint256 staked = splitter.stakedOf(actor);
        if (staked == 0) return;
        amount = bound(amount, 1, staked);

        vm.prank(actor);
        splitter.unstake(amount);

        principalUnstaked += amount;
    }

    /// @dev The ordinary funded recognition path: a payer hands in an exact amount.
    function depositRevenue(uint256 tokenSeed, uint256 actorSeed, uint256 amount) external {
        calls += 1;
        MockERC20 token = _token(tokenSeed);
        address payer = _actor(actorSeed);

        // Never spend a staker's SUBJECT principal as revenue: only what is free to spend.
        uint256 available = token.balanceOf(payer);
        if (available == 0) return;
        amount = bound(amount, 1, available);

        vm.startPrank(payer);
        token.approve(address(splitter), amount);
        splitter.depositRecognizedRevenue(address(token), amount, bytes32(calls));
        vm.stopPrank();

        _recordRecognition(address(token), amount);
    }

    /// @dev A bare transfer becomes revenue only through permissionless surplus recognition.
    function giftAndRecognize(uint256 tokenSeed, uint256 actorSeed, uint256 amount) external {
        calls += 1;
        MockERC20 token = _token(tokenSeed);
        address giver = _actor(actorSeed);

        uint256 available = token.balanceOf(giver);
        if (available == 0) return;
        amount = bound(amount, 1, available);

        vm.prank(giver);
        token.transfer(address(splitter), amount);

        // The gift may complete an amount already sitting unaccounted, so recognize whatever the
        // splitter itself considers unaccounted rather than the gift alone.
        uint256 unaccounted = token.balanceOf(address(splitter)) - splitter.protectedBalance(address(token));
        if (unaccounted == 0) return;

        vm.prank(giver);
        splitter.recognizeSurplusRevenue(address(token), bytes32(calls));

        _recordRecognition(address(token), unaccounted);
    }

    function claim(uint256 actorSeed, uint256 tokenSeed) external {
        calls += 1;
        address actor = _actor(actorSeed);
        MockERC20 token = _token(tokenSeed);

        uint256 owed = splitter.claimable(address(token), actor);
        vm.prank(actor);
        splitter.claim(address(token));

        claimedByStakers[address(token)] += owed;
    }

    function claimAll(uint256 actorSeed) external {
        calls += 1;
        address actor = _actor(actorSeed);

        uint256 owedUsdc = splitter.claimable(address(usdc), actor);
        uint256 owedRegent = splitter.claimable(address(regent), actor);
        uint256 owedSubject = splitter.claimable(address(subject), actor);

        vm.prank(actor);
        splitter.claimAll();

        claimedByStakers[address(usdc)] += owedUsdc;
        claimedByStakers[address(regent)] += owedRegent;
        claimedByStakers[address(subject)] += owedSubject;
    }

    /// @dev An unsupported token can be gifted and recovered; neither touches recognized inventory.
    function giftAndRecoverUnsupported(uint256 actorSeed, uint256 amount) external {
        calls += 1;
        address giver = _actor(actorSeed);
        uint256 available = unsupported.balanceOf(giver);
        if (available == 0) return;
        amount = bound(amount, 1, available);

        vm.prank(giver);
        unsupported.transfer(address(splitter), amount);

        // Recovery is permissionless and takes the splitter's complete balance of the token, so
        // any actor may call it and no amount is chosen here.
        vm.prank(giver);
        splitter.recoverUnsupportedToken(address(unsupported));
    }

    // -------------------------------------------------------------------------
    // model
    // -------------------------------------------------------------------------

    /// @dev The observable split of one recognition, computed from the specified rule rather than
    ///      read back out of the splitter.
    function _recordRecognition(address token, uint256 gross) private {
        uint256 skim = (gross * 200) / 10_000;
        uint256 net = gross - skim;

        recognizedGross[token] += gross;
        routedSkim[token] += skim;
        uint256 staked = splitter.totalStaked();
        if (staked == 0) {
            routedToTreasury[token] += net;
        } else {
            creditedToStakers[token] += net;
            carryCeiling[token] = staked;
        }
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _token(uint256 seed) private view returns (MockERC20) {
        uint256 index = bound(seed, 0, 2);
        if (index == 0) return usdc;
        if (index == 1) return regent;
        return subject;
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function actorCount() external pure returns (uint256) {
        return 4;
    }
}
