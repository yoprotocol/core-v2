// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IMidnight, ISetterRatifier } from "src/interfaces/IMidnight.sol";

/// @notice Minimal Midnight `SetterRatifier` stand-in. Stores ratified roots per maker and enforces
///         the same delegation check as the real contract: the caller must be the maker or authorized
///         by it on Midnight. Adapter tests assert on `isRootRatified`; the real ratifier's Merkle
///         verification is exercised end-to-end on the fork.
contract MockSetterRatifier is ISetterRatifier {
    IMidnight public immutable midnight;

    mapping(address maker => mapping(bytes32 root => bool)) public isRootRatified;

    constructor(address _midnight) {
        midnight = IMidnight(_midnight);
    }

    function setIsRootRatified(address maker, bytes32 root, bool newIsRootRatified) external {
        require(maker == msg.sender || midnight.isAuthorized(maker, msg.sender), "unauthorized");
        isRootRatified[maker][root] = newIsRootRatified;
    }
}
