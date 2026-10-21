// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Per-vault cap on Midnight lending through `YoMidnightAdapter`.
interface IYoMidnightRegistry {
    event CapSet(address indexed vault, uint256 assets);

    error ZeroAddress();
    error RenounceDisabled();

    /// @notice Set the cap of `vault`, in the vault's asset. 0 blocks new funding.
    function setCap(address vault, uint256 assets) external;

    /// @notice The cap of `vault`, in the vault's asset. 0 when not set.
    function cap(address vault) external view returns (uint256 assets);
}
