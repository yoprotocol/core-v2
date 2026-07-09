// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ITokenMessengerV2 } from "src/interfaces/external/ITokenMessengerV2.sol";

/// @notice Minimal CCTP V2 `TokenMessengerV2` stand-in. Pulls `amount` of `burnToken` from the
///         caller (the adapter) and records the last burn so tests can assert forwarded parameters.
contract MockTokenMessengerV2 is ITokenMessengerV2 {
    using SafeERC20 for IERC20;

    struct LastBurn {
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        address burnToken;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32 minFinalityThreshold;
    }

    LastBurn public last;
    uint256 public callCount;

    /// @inheritdoc ITokenMessengerV2
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    )
        external
    {
        IERC20(burnToken).safeTransferFrom(msg.sender, address(this), amount);

        last = LastBurn({
            amount: amount,
            destinationDomain: destinationDomain,
            mintRecipient: mintRecipient,
            burnToken: burnToken,
            destinationCaller: destinationCaller,
            maxFee: maxFee,
            minFinalityThreshold: minFinalityThreshold
        });
        ++callCount;
    }
}
