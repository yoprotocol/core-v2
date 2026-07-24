// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Market, Offer } from "./IMidnight.sol";

/// @notice Immutable adapter that brokers all Morpho Midnight lending interactions on behalf of a vault.
/// @dev The vault is always the maker/taker/`onBehalf`; proceeds and redemptions always settle to the
///      vault, and every maker offer is validated field-by-field before its single-leaf root is ratified.
interface IYoMidnightAdapter {
    /// @notice Emitted when the vault ratifies a single-offer root through the SetterRatifier.
    event OrderMade(address indexed vault, bytes32 indexed marketId, bytes32 root);
    /// @notice Emitted when the vault un-ratifies a single-offer root.
    event OrderCancelled(address indexed vault, bytes32 root);
    /// @notice Emitted when the vault hard-cancels a group by maxing out its consumed budget.
    event GroupCancelled(address indexed vault, bytes32 group);

    error MarketNotAllowed(bytes32 marketId);
    error InvalidAmount();
    error NotOfferMaker();
    error RootNotRatified();
    error InvalidRatifier();
    error CallbackNotEmpty();
    error InvalidReceiver();
    error InvalidOfferCaps();
    error NotReduceOnly();
    error SellCapMustBeUnits();
    error TickBelowFloor();
    error WrongOfferSide();
    error InsufficientCredit();
    error NoCreditDelta();
    error NoPosition();
    error SlippageExceeded();

    function makeOrder(Offer calldata offer) external returns (bytes32 root);

    function makeOrders(Offer[] calldata offers) external returns (bytes32[] memory roots);

    function cancelOrder(Offer calldata offer) external returns (bytes32 root);

    function cancelGroup(bytes32 group) external;

    function takeBuy(
        Offer calldata offer,
        bytes calldata ratifierData,
        uint256 units,
        uint256 maxAssets
    )
        external
        returns (uint256 buyerAssets, uint256 creditReceived);

    function takeSell(
        Offer calldata offer,
        bytes calldata ratifierData,
        uint256 units,
        uint256 minAssets
    )
        external
        returns (uint256 sellerAssets);

    function withdraw(Market calldata market, uint256 units) external;

    function withdrawAll(Market calldata market) external returns (uint256 units);
}
