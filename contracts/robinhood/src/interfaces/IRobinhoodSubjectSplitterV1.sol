// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title IRobinhoodSubjectSplitterV1
/// @notice The revenue surface of one Robinhood revenue-share launch. Recognizes USDG only, skims 2%
///         exactly once into the protocol revenue inbox, and divides the remainder by how much of the
///         complete NEW supply is staked: stakers collectively receive that fraction of the net and
///         the launch treasury immediately receives the rest.
interface IRobinhoodSubjectSplitterV1 {
    event SplitterInitialized(address usdg, address indexed subject, address inbox, address indexed treasury);
    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event Claimed(address indexed account, uint256 amount);
    event RevenueRecognized(
        address indexed source,
        bytes32 indexed revenueRef,
        uint256 gross,
        uint256 skim,
        uint256 net,
        uint256 stakerShare,
        uint256 treasuryShare
    );
    event UnsupportedTokenRecovered(address indexed token, address indexed treasury, uint256 amount);
    event ForcedEthRecovered(address indexed treasury, uint256 amount);

    function usdg() external view returns (address);
    function subject() external view returns (address);
    function inbox() external view returns (address);
    function treasury() external view returns (address);
    function totalStaked() external view returns (uint256);
    function stakedOf(address account) external view returns (uint256);
    function unclaimedLiability() external view returns (uint256);
    function claimable(address account) external view returns (uint256);

    function stake(uint256 amount) external;
    function unstake(uint256 amount) external;
    function claim() external;
    /// @notice Recognize exactly `amount` of `token`, pulled from the caller inside this call. Only
    ///         USDG is ever accepted; the token argument keeps the deposit shape every Autolaunch
    ///         revenue source already speaks.
    function depositRecognizedRevenue(address token, uint256 amount, bytes32 revenueRef) external;
    function recognizeSurplusRevenue() external;
    function recoverUnsupportedToken(address token) external;
    function recoverForcedETH() external;
}
