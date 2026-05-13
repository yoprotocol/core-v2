// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal WETH9 stand-in. ERC-20 + deposit/withdraw at 1:1.
/// @dev    Does not formally implement `IWETH9` — its function signatures match, and Solidity
///         duck-types at the cast site (`IWETH9(address(mock))`).
contract MockWETH9 is ERC20 {
    error EthTransferFailed();

    constructor() ERC20("Wrapped Ether", "WETH") { }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{ value: amount }("");
        if (!ok) {
            revert EthTransferFailed();
        }
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}
