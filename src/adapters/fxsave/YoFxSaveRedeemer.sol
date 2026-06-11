// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ISavingFxUSD } from "../../interfaces/external/ISavingFxUSD.sol";

/// @title  YoFxSaveRedeemer
/// @notice Per-vault isolation shim for the fxSAVE cooldown redemption path. One redeemer is
///         deployed deterministically (CREATE2, salt = the vault address) by {YoFxSaveAdapter} the
///         first time a vault calls `requestRedeem`.
/// @dev    fxSAVE keys its internal locked-redeem proxy by `msg.sender` and `claim` redeems the
///         entire locked position to a single receiver. Routing each vault's cooldown redemption
///         through its own redeemer gives every vault a distinct `msg.sender` toward fxSAVE, so
///         locked positions never commingle and one vault can never claim another's funds.
///
///         INVARIANTS:
///           - Only the deploying adapter can drive `requestRedeem` / `claim`.
///           - Holds fxSAVE shares only transiently: the adapter transfers them in, then calls
///             `requestRedeem` in the same transaction, which burns them.
///           - Claim payouts (fxUSD + USDC) are sent straight to `receiver`; the redeemer never
///             custodies them.
contract YoFxSaveRedeemer {
    /// @notice The fxSAVE vault this redeemer redeems from. Immutable for the redeemer's lifetime.
    ISavingFxUSD public immutable fxSave;

    /// @notice The adapter that deployed this redeemer and is its sole authorized caller.
    address public immutable adapter;

    error CallerNotAdapter();

    constructor(ISavingFxUSD _fxSave) {
        fxSave = _fxSave;
        adapter = msg.sender;
    }

    modifier onlyAdapter() {
        if (msg.sender != adapter) {
            revert CallerNotAdapter();
        }
        _;
    }

    /// @notice Register a fee-free redemption of the `shares` fxSAVE this redeemer holds.
    /// @dev    The adapter must transfer `shares` of fxSAVE to this redeemer before calling.
    /// @return assets The amount of base-pool shares locked for the request.
    function requestRedeem(uint256 shares) external onlyAdapter returns (uint256 assets) {
        assets = fxSave.requestRedeem(shares);
    }

    /// @notice Claim this redeemer's matured redemption, sending fxUSD + USDC to `receiver`.
    function claim(address receiver) external onlyAdapter {
        fxSave.claim(receiver);
    }
}
