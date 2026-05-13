// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal Lido stETH stand-in. Models the share-based accounting (`sharesOf`,
///         `transferShares`) at a fixed 1:1 share-price for simplicity. Sufficient for verifying
///         adapter logic; fork tests should target the real Lido deployment.
contract MockStETH is ERC20 {
    error ZeroDeposit();

    constructor() ERC20("Liquid staked Ether", "stETH") { }

    /// @notice Stake ETH for stETH (1:1 in this mock).
    function submit(address /* referral */ ) external payable returns (uint256 sharesMinted) {
        if (msg.value == 0) {
            revert ZeroDeposit();
        }
        sharesMinted = msg.value;
        _mint(msg.sender, msg.value);
    }

    /// @notice 1:1 with `balanceOf` in this mock.
    function sharesOf(address account) external view returns (uint256) {
        return balanceOf(account);
    }

    /// @notice Same as ERC-20 transfer in this mock; real Lido uses share-denominated math.
    function transferShares(address to, uint256 sharesAmount) external returns (uint256) {
        _transfer(msg.sender, to, sharesAmount);
        return sharesAmount;
    }

    function getPooledEthByShares(uint256 sharesAmount) external pure returns (uint256) {
        return sharesAmount;
    }

    function getSharesByPooledEth(uint256 ethAmount) external pure returns (uint256) {
        return ethAmount;
    }

    /// @notice Allow tests to mint stETH directly (e.g. to pre-seed a vault for unstake tests).
    function mintForTest(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
