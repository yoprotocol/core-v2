// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMorpho, Id, MarketParams } from "../../interfaces/IMorpho.sol";

/// @title  RoadrunnerWithdrawer
/// @notice Thin Morpho withdraw gateway. Forces onBehalf == receiver == msg.sender
/// @dev    Users must first call `morpho.setAuthorization(<this>, true)`.
contract RoadrunnerWithdrawer {
    using SafeERC20 for IERC20;

    address public immutable owner;
    IMorpho public immutable morpho;

    error ZeroAddress();
    error NoPosition(Id id);
    error UnknownMarket(Id id);
    error Unauthorized(address caller);

    constructor(address _owner, IMorpho _morpho) {
        if (_owner == address(0)) {
            revert ZeroAddress();
        }
        owner = _owner;
        morpho = _morpho;
    }

    /// @notice Withdraw `assets` of the loan token from `id` to msg.sender.
    function withdraw(Id id, uint256 assets) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn) {
        MarketParams memory p = morpho.idToMarketParams(id);
        if (p.loanToken == address(0)) {
            revert UnknownMarket(id);
        }
        return morpho.withdraw(p, assets, 0, msg.sender, msg.sender);
    }

    /// @notice Withdraw caller's entire supply position from `id` to msg.sender.
    /// @dev    Reads supplyShares live so the amount cannot be spoofed by a caller.
    function withdrawAll(Id id) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn) {
        MarketParams memory p = morpho.idToMarketParams(id);
        if (p.loanToken == address(0)) {
            revert UnknownMarket(id);
        }

        uint256 shares = morpho.position(id, msg.sender).supplyShares;
        if (shares == 0) {
            revert NoPosition(id);
        }
        return morpho.withdraw(p, 0, shares, msg.sender, msg.sender);
    }

    /// @notice Recover ERC20 tokens accidentally sent to this contract.
    /// @dev    The contract holds no funds in normal operation; this is a safety hatch.
    /// @param  token  ERC20 to transfer out.
    /// @param  to     Recipient of the rescued tokens.
    /// @param  amount Amount to transfer.
    function rescue(IERC20 token, address to, uint256 amount) external {
        if (msg.sender != owner) {
            revert Unauthorized(msg.sender);
        }
        if (to == address(0)) {
            revert ZeroAddress();
        }
        token.safeTransfer(to, amount);
    }
}
