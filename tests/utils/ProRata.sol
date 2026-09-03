// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The vault's release rule, single-sourced for tests: `floor(total * part / whole)`.
///         For `part == whole` this is exactly `total`, which is what makes the final slice of a
///         partial fulfilment settle the exact remainder.
library ProRata {
    using Math for uint256;

    function slice(uint256 total, uint256 part, uint256 whole) internal pure returns (uint256) {
        return total.mulDiv(part, whole, Math.Rounding.Floor);
    }
}
