// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity 0.8.34;

import { CollateralParams, Market, Offer } from "../interfaces/IMidnight.sol";

/// @dev keccak256("CollateralParams(address token,uint256 lltv,uint256 liquidationCursor,address oracle)").
bytes32 constant COLLATERAL_PARAMS_TYPEHASH = 0x39ed3f928d24fd00574b1a02aba9c2483abcf5d9a3a366118c9a5aa29885b841;
/// @dev keccak256(bytes.concat(MARKET_TYPE, COLLATERAL_PARAMS_TYPE)).
bytes32 constant MARKET_TYPEHASH = 0x510b3862f3816a109c9340b76972e8a30984246be06e034ae12ed2934220391a;
/// @dev keccak256(bytes.concat(OFFER_TYPE, COLLATERAL_PARAMS_TYPE, MARKET_TYPE)).
bytes32 constant OFFER_TYPEHASH = 0x9905214264a9fb7b6cc1b0e33db7a04687c6e4185a84755d29914314aa9d8906;

/// @title  MidnightHashLib
/// @notice EIP-712 struct hashing for Midnight offers, vendored verbatim from `morpho-org/midnight`
///         `src/ratifiers/libraries/HashLib.sol`. Only the offer/market/collateral hashers are kept
///         (the adapter ratifies single-leaf roots, so `root == hashOffer(offer)` and no Merkle
///         helpers are needed). Typehash constants are copied byte-for-byte to match on-chain hashing.
library MidnightHashLib {
    /// @dev Computes the EIP-712 hash struct of a CollateralParams.
    function hashCollateralParams(CollateralParams memory collateralParams) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                COLLATERAL_PARAMS_TYPEHASH,
                collateralParams.token,
                collateralParams.lltv,
                collateralParams.liquidationCursor,
                collateralParams.oracle
            )
        );
    }

    /// @dev Computes the EIP-712 hash struct of a Market.
    function hashMarket(Market memory market) internal pure returns (bytes32) {
        bytes32[] memory collateralParamsHashes = new bytes32[](market.collateralParams.length);
        for (uint256 i = 0; i < market.collateralParams.length; i++) {
            collateralParamsHashes[i] = hashCollateralParams(market.collateralParams[i]);
        }

        bytes32 collateralParamsHash;
        // same as keccak256(abi.encodePacked(collateralParamsHashes));
        assembly ("memory-safe") {
            collateralParamsHash := keccak256(
                add(collateralParamsHashes, 0x20),
                mul(mload(collateralParamsHashes), 0x20)
            )
        }

        return keccak256(
            abi.encode(
                MARKET_TYPEHASH,
                market.chainId,
                market.midnight,
                market.loanToken,
                collateralParamsHash,
                market.maturity,
                market.rcfThreshold,
                market.enterGate,
                market.liquidatorGate
            )
        );
    }

    /// @dev Computes the EIP-712 hash struct of an Offer.
    /// @dev Every offer field ABI-encodes to a single static 32-byte word (the market and
    ///      callback-data sub-hashes are pre-hashed to `bytes32`), so splitting the 16-field encode
    ///      into two halves and concatenating yields byte-for-byte the same preimage as upstream
    ///      `HashLib.hashOffer` — while keeping the legacy (non-IR) codegen off the stack-too-deep
    ///      path that a single 16-argument `abi.encode` triggers.
    function hashOffer(Offer memory offer) internal pure returns (bytes32) {
        bytes32 marketHash = hashMarket(offer.market);
        bytes memory head = abi.encode(
            OFFER_TYPEHASH, marketHash, offer.buy, offer.maker, offer.start, offer.expiry, offer.tick, offer.group
        );
        bytes memory tail = abi.encode(
            offer.callback,
            keccak256(offer.callbackData),
            offer.receiverIfMakerIsSeller,
            offer.ratifier,
            offer.reduceOnly,
            offer.maxUnits,
            offer.maxAssets,
            offer.continuousFeeCap
        );
        return keccak256(bytes.concat(head, tail));
    }
}
