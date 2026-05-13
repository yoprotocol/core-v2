// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC-20 that calls back into a configured target during `transferFrom`. Used to verify that
///         adapters' `nonReentrant` guards reject re-entrant flows triggered by malicious tokens.
contract MockReentrantERC20 is ERC20 {
    address public target;
    bytes public reentryCalldata;
    bool public armed;

    constructor() ERC20("Reentrant Token", "RENT") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Arm the trap. The next `transferFrom` will perform `target.call(reentryCalldata)` and
    ///         then disarm itself, so subsequent transfers behave normally.
    function arm(address _target, bytes calldata _calldata) external {
        target = _target;
        reentryCalldata = _calldata;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            (bool ok, bytes memory ret) = target.call(reentryCalldata);
            // Bubble the inner revert verbatim — tests expect `ReentrancyGuardReentrantCall`.
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        return super.transferFrom(from, to, amount);
    }
}
