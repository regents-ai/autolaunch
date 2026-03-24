// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "src/auth/Owned.sol";
import {SafeTransferLib} from "src/libraries/SafeTransferLib.sol";
import {FullMath} from "src/libraries/FullMath.sol";

interface IERC20BalanceMinimal {
    function balanceOf(address account) external view returns (uint256);
}

interface ISubjectRegistryMinimal {
    struct SubjectConfig {
        address stakeToken;
        address splitter;
        address treasurySafe;
        bool active;
        string label;
    }

    function getSubject(bytes32 subjectId) external view returns (SubjectConfig memory);
    function emissionRecipient(bytes32 subjectId, uint256 chainId) external view returns (address);
    function canManageSubject(bytes32 subjectId, address account) external view returns (bool);
}

interface IRevenueShareSplitterProtocolMinimal {
    function withdrawProtocolReserve(address rewardToken, uint256 amount, address recipient)
        external;
}

interface ILaunchFeeVaultRegentMinimal {
    function withdrawRegentShare(
        bytes32 poolId,
        address currency,
        uint256 amount,
        address recipient
    ) external;
}

/// @title MainnetRegentEmissionsController
/// @notice Mainnet-only REGENT emissions controller keyed by subjectId.
/// @dev
/// - Emissions weight is based only on recognized mainnet USDC.
/// - No Merkle tree is needed because the contract stores per-subject per-epoch USDC directly.
/// - Hook-side non-USDC fees (ETH/WETH/launch token) should be normalized into USDC off-contract
///   before they are credited here. USDC hook accruals can be pulled directly from LaunchFeeVault.
/// - Splitter-side protocol reserve is expected to be USDC-only for emissions accounting.
contract MainnetRegentEmissionsController is Owned {
    using SafeTransferLib for address;

    bytes32 public constant CREDIT_ROLE = keccak256("CREDIT_ROLE");
    bytes32 public constant EPOCH_PUBLISHER_ROLE = keccak256("EPOCH_PUBLISHER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    struct EpochData {
        uint128 totalRecognizedUsdc;
        uint128 emissionAmount;
        bool published;
    }

    struct LaunchUsdcRoute {
        address vault;
        bytes32 poolId;
        bool enabled;
    }

    address public immutable regent;
    address public immutable usdc;
    ISubjectRegistryMinimal public immutable subjectRegistry;
    uint256 public immutable genesisTs;
    uint256 public immutable epochLength;
    uint256 public immutable localChainId;

    address public usdcTreasury;
    bool public paused;

    mapping(bytes32 => mapping(address => bool)) private roles;
    mapping(uint32 => EpochData) public epochs;
    mapping(uint32 => mapping(bytes32 => uint256)) public subjectRevenueUsdc;
    mapping(uint32 => mapping(bytes32 => bool)) public subjectClaimed;
    mapping(uint32 => mapping(bytes32 => address)) public subjectRecipientSnapshot;
    mapping(bytes32 => bool) public seenCreditId;
    mapping(bytes32 => LaunchUsdcRoute) public launchUsdcRoutes;

    event RoleSet(bytes32 indexed role, address indexed account, bool enabled);
    event PausedSet(bool paused);
    event UsdcTreasurySet(address indexed treasury);
    event LaunchUsdcRouteSet(
        bytes32 indexed subjectId, address indexed vault, bytes32 indexed poolId, bool enabled
    );
    event RevenueCredited(
        uint32 indexed epoch,
        bytes32 indexed subjectId,
        uint256 amount,
        bytes32 indexed sourceKind,
        bytes32 sourceRef,
        bytes32 creditId
    );
    event EpochPublished(uint32 indexed epoch, uint256 totalRecognizedUsdc, uint256 emissionAmount);
    event Claimed(
        uint32 indexed epoch, bytes32 indexed subjectId, address indexed recipient, uint256 amount
    );
    event RecipientSnapshotted(
        uint32 indexed epoch, bytes32 indexed subjectId, address indexed recipient
    );
    event UsdcSwept(address indexed recipient, uint256 amount);

    modifier onlyRole(bytes32 role) {
        require(roles[role][msg.sender], "MISSING_ROLE");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }

    modifier nonReentrant() {
        require(_reentrancyGuard == 1, "REENTRANT");
        _reentrancyGuard = 2;
        _;
        _reentrancyGuard = 1;
    }

    uint256 private _reentrancyGuard = 1;

    constructor(
        address regent_,
        address usdc_,
        ISubjectRegistryMinimal subjectRegistry_,
        address usdcTreasury_,
        uint256 genesisTs_,
        uint256 epochLength_,
        uint256 localChainId_,
        address owner_
    ) Owned(owner_) {
        require(regent_ != address(0), "REGENT_ZERO");
        require(usdc_ != address(0), "USDC_ZERO");
        require(address(subjectRegistry_) != address(0), "SUBJECT_REGISTRY_ZERO");
        require(usdcTreasury_ != address(0), "USDC_TREASURY_ZERO");
        require(genesisTs_ != 0, "GENESIS_ZERO");
        require(epochLength_ != 0, "EPOCH_LENGTH_ZERO");
        require(localChainId_ != 0, "CHAIN_ID_ZERO");

        regent = regent_;
        usdc = usdc_;
        subjectRegistry = subjectRegistry_;
        usdcTreasury = usdcTreasury_;
        genesisTs = genesisTs_;
        epochLength = epochLength_;
        localChainId = localChainId_;

        _setRole(CREDIT_ROLE, owner_, true);
        _setRole(EPOCH_PUBLISHER_ROLE, owner_, true);
        _setRole(PAUSER_ROLE, owner_, true);
    }

    function currentEpoch() public view returns (uint32) {
        if (block.timestamp <= genesisTs) {
            return 1;
        }
        return uint32((block.timestamp - genesisTs) / epochLength) + 1;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account];
    }

    function setRole(bytes32 role, address account, bool enabled) external onlyOwner {
        _setRole(role, account, enabled);
    }

    function setPaused(bool paused_) external onlyRole(PAUSER_ROLE) {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setUsdcTreasury(address usdcTreasury_) external onlyOwner {
        require(usdcTreasury_ != address(0), "USDC_TREASURY_ZERO");
        usdcTreasury = usdcTreasury_;
        emit UsdcTreasurySet(usdcTreasury_);
    }

    function configureLaunchUsdcRoute(
        bytes32 subjectId,
        address vault,
        bytes32 poolId,
        bool enabled
    ) external {
        _requireSubjectManagerOrOwner(subjectId, msg.sender);
        require(vault != address(0), "VAULT_ZERO");

        launchUsdcRoutes[subjectId] =
            LaunchUsdcRoute({vault: vault, poolId: poolId, enabled: enabled});
        emit LaunchUsdcRouteSet(subjectId, vault, poolId, enabled);
    }

    /// @notice Credit already-normalized mainnet USDC to a subject for the current epoch.
    /// @dev Intended for bridge receivers or normalizer adapters. Caller must have CREDIT_ROLE.
    function creditUsdc(
        bytes32 subjectId,
        uint256 amount,
        bytes32 creditId,
        bytes32 sourceKind,
        bytes32 sourceRef
    ) external onlyRole(CREDIT_ROLE) whenNotPaused nonReentrant returns (uint32 epoch) {
        require(amount != 0, "AMOUNT_ZERO");
        require(creditId != bytes32(0), "CREDIT_ID_ZERO");
        require(!seenCreditId[creditId], "CREDIT_ALREADY_SEEN");

        _requireKnownSubject(subjectId);
        seenCreditId[creditId] = true;

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        epoch = _credit(subjectId, amount, sourceKind, sourceRef, creditId);
    }

    /// @notice Pull USDC-only protocol reserve from the subject's splitter and credit it.
    /// @dev This contract must be the splitter's protocolRecipient (or owner).
    function pullSplitterUsdc(bytes32 subjectId, uint256 amount, bytes32 sourceRef)
        external
        whenNotPaused
        nonReentrant
        returns (uint32 epoch, uint256 received)
    {
        require(amount != 0, "AMOUNT_ZERO");

        ISubjectRegistryMinimal.SubjectConfig memory cfg = _requireKnownSubject(subjectId);
        require(cfg.splitter != address(0), "SPLITTER_ZERO");

        uint256 beforeBalance = _balanceOf(usdc, address(this));
        IRevenueShareSplitterProtocolMinimal(cfg.splitter)
            .withdrawProtocolReserve(usdc, amount, address(this));
        uint256 afterBalance = _balanceOf(usdc, address(this));
        received = afterBalance - beforeBalance;
        require(received != 0, "NOTHING_RECEIVED");

        epoch = _credit(subjectId, received, bytes32("splitter_usdc"), sourceRef, bytes32(0));
    }

    /// @notice Pull USDC hook-side Regent accrual from the configured launch fee vault and credit it.
    /// @dev This contract must be the pool's regentRecipient in LaunchFeeRegistry.
    function pullLaunchVaultUsdc(bytes32 subjectId, uint256 amount, bytes32 sourceRef)
        external
        whenNotPaused
        nonReentrant
        returns (uint32 epoch, uint256 received)
    {
        require(amount != 0, "AMOUNT_ZERO");

        LaunchUsdcRoute memory route = launchUsdcRoutes[subjectId];
        require(route.enabled, "ROUTE_DISABLED");
        require(route.vault != address(0), "VAULT_ZERO");

        _requireKnownSubject(subjectId);

        uint256 beforeBalance = _balanceOf(usdc, address(this));
        ILaunchFeeVaultRegentMinimal(route.vault)
            .withdrawRegentShare(route.poolId, usdc, amount, address(this));
        uint256 afterBalance = _balanceOf(usdc, address(this));
        received = afterBalance - beforeBalance;
        require(received != 0, "NOTHING_RECEIVED");

        epoch = _credit(subjectId, received, bytes32("launch_hook_usdc"), sourceRef, bytes32(0));
    }

    /// @notice Publish the REGENT budget for a closed epoch.
    /// @dev Total recognized USDC is taken from onchain state; no Merkle root is needed.
    function publishEpochEmission(uint32 epoch, uint256 emissionAmount)
        external
        onlyRole(EPOCH_PUBLISHER_ROLE)
        whenNotPaused
        nonReentrant
    {
        require(epoch < currentEpoch(), "EPOCH_NOT_CLOSED");
        require(emissionAmount != 0, "EMISSION_ZERO");

        EpochData storage data = epochs[epoch];
        require(!data.published, "EPOCH_ALREADY_PUBLISHED");
        require(data.totalRecognizedUsdc != 0, "NO_RECOGNIZED_REVENUE");
        require(emissionAmount <= type(uint128).max, "EMISSION_TOO_LARGE");

        data.emissionAmount = uint128(emissionAmount);
        data.published = true;

        regent.safeTransferFrom(msg.sender, address(this), emissionAmount);
        emit EpochPublished(epoch, uint256(data.totalRecognizedUsdc), emissionAmount);
    }

    function previewClaimable(uint32 epoch, bytes32 subjectId)
        public
        view
        returns (uint256 amount)
    {
        EpochData memory data = epochs[epoch];
        if (!data.published || subjectClaimed[epoch][subjectId]) {
            return 0;
        }

        uint256 subjectRevenue = subjectRevenueUsdc[epoch][subjectId];
        if (subjectRevenue == 0 || data.totalRecognizedUsdc == 0) {
            return 0;
        }

        amount = FullMath.mulDiv(
            uint256(data.emissionAmount), subjectRevenue, uint256(data.totalRecognizedUsdc)
        );
    }

    /// @notice Claim REGENT for one subject and epoch. Permissionless; funds always go to the subject's configured recipient.
    function claim(uint32 epoch, bytes32 subjectId)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 amount)
    {
        amount = _claim(epoch, subjectId);
    }

    function claimMany(uint32[] calldata epochIds, bytes32[] calldata subjectIds)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 totalAmount)
    {
        require(epochIds.length == subjectIds.length, "LENGTH_MISMATCH");
        for (uint256 i; i < epochIds.length; ++i) {
            totalAmount += _claim(epochIds[i], subjectIds[i]);
        }
    }

    /// @notice Sweep the accumulated recognized USDC to the Regent treasury.
    /// @dev This does not change already-recorded epoch totals.
    function sweepUsdcToTreasury(uint256 amount, address recipient)
        external
        onlyOwner
        whenNotPaused
        nonReentrant
    {
        require(recipient != address(0), "RECIPIENT_ZERO");
        require(recipient == usdcTreasury || recipient == owner, "RECIPIENT_NOT_TREASURY");

        usdc.safeTransfer(recipient, amount);
        emit UsdcSwept(recipient, amount);
    }

    function _claim(uint32 epoch, bytes32 subjectId) internal returns (uint256 amount) {
        require(subjectId != bytes32(0), "SUBJECT_ZERO");
        EpochData memory data = epochs[epoch];
        require(data.published, "EPOCH_NOT_PUBLISHED");
        require(!subjectClaimed[epoch][subjectId], "ALREADY_CLAIMED");

        amount = previewClaimable(epoch, subjectId);
        subjectClaimed[epoch][subjectId] = true;

        address recipient = subjectRecipientSnapshot[epoch][subjectId];
        require(recipient != address(0), "RECIPIENT_ZERO");

        if (amount != 0) {
            regent.safeTransfer(recipient, amount);
        }

        emit Claimed(epoch, subjectId, recipient, amount);
    }

    function _credit(
        bytes32 subjectId,
        uint256 amount,
        bytes32 sourceKind,
        bytes32 sourceRef,
        bytes32 creditId
    ) internal returns (uint32 epoch) {
        require(amount != 0, "AMOUNT_ZERO");
        epoch = currentEpoch();

        EpochData storage data = epochs[epoch];
        uint256 nextSubject = subjectRevenueUsdc[epoch][subjectId] + amount;
        uint256 nextTotal = uint256(data.totalRecognizedUsdc) + amount;

        require(nextSubject <= type(uint128).max, "SUBJECT_REVENUE_TOO_LARGE");
        require(nextTotal <= type(uint128).max, "TOTAL_REVENUE_TOO_LARGE");

        subjectRevenueUsdc[epoch][subjectId] = nextSubject;
        data.totalRecognizedUsdc = uint128(nextTotal);

        if (subjectRecipientSnapshot[epoch][subjectId] == address(0)) {
            address recipient = subjectRegistry.emissionRecipient(subjectId, localChainId);
            if (recipient == address(0)) {
                recipient = _requireKnownSubject(subjectId).treasurySafe;
            }
            require(recipient != address(0), "RECIPIENT_ZERO");
            subjectRecipientSnapshot[epoch][subjectId] = recipient;
            emit RecipientSnapshotted(epoch, subjectId, recipient);
        }

        emit RevenueCredited(epoch, subjectId, amount, sourceKind, sourceRef, creditId);
    }

    function _requireKnownSubject(bytes32 subjectId)
        internal
        view
        returns (ISubjectRegistryMinimal.SubjectConfig memory cfg)
    {
        require(subjectId != bytes32(0), "SUBJECT_ZERO");
        cfg = subjectRegistry.getSubject(subjectId);
        require(cfg.stakeToken != address(0), "SUBJECT_NOT_FOUND");
        require(cfg.active, "SUBJECT_INACTIVE");
    }

    function _requireSubjectManagerOrOwner(bytes32 subjectId, address account) internal view {
        if (account == owner) {
            _requireKnownSubject(subjectId);
            return;
        }
        require(subjectRegistry.canManageSubject(subjectId, account), "ONLY_SUBJECT_MANAGER");
    }

    function _balanceOf(address token, address account) internal view returns (uint256) {
        return IERC20BalanceMinimal(token).balanceOf(account);
    }

    function _setRole(bytes32 role, address account, bool enabled) internal {
        require(account != address(0), "ACCOUNT_ZERO");
        roles[role][account] = enabled;
        emit RoleSet(role, account, enabled);
    }
}
