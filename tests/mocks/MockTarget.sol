// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Trivial contract used by `manage` tests — `someFunction` stores its argument and is
///         payable so tests can also verify ETH forwarding.
contract MockTarget {
    uint256 public value;

    function someFunction(uint256 _value) external payable {
        value = _value;
    }
}
