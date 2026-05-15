// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoVault } from "src/YoVault.sol";

/// @dev Test harness exposing `YoVault` internals for fee-application assertions.
contract YoVaultHarness is YoVault {
    function exposed_feeOnRaw(uint256 assets, uint256 feeBasisPoints) external pure returns (uint256) {
        return _feeOnRaw(assets, feeBasisPoints);
    }

    function exposed_feeOnTotal(uint256 assets, uint256 feeBasisPoints) external pure returns (uint256) {
        return _feeOnTotal(assets, feeBasisPoints);
    }
}
