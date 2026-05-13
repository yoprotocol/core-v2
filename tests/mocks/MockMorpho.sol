// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Id, IMorpho, MarketParams, Position } from "src/interfaces/IMorpho.sol";

/// @notice Minimal Morpho Blue stand-in. Models 1:1 share/asset accounting with no interest accrual,
///         which is sufficient for verifying adapter logic and registry gating in unit/integration tests.
///         Fork tests should target the real Morpho deployment.
contract MockMorpho is IMorpho {
    using SafeERC20 for IERC20;

    mapping(Id id => MarketParams params) private _params;
    mapping(Id id => mapping(address user => Position pos)) private _positions;
    /// @dev `keccak256(abi.encode(params))` -> the user-supplied id those params were registered under.
    ///      Real Morpho derives the id from the params hash directly; this mock indirects through the
    ///      registration so callers can use arbitrary ids in tests.
    mapping(bytes32 paramsHash => Id id) private _paramsToId;
    mapping(address authorizer => mapping(address authorized => bool)) public isAuthorized;

    /// @dev When true, `supply` pulls tokens but skips the share credit. Lets adapter tests assert
    ///      that `NoShareDelta` fires deterministically.
    bool public skipShareCredit;

    function setMarketParams(Id id, MarketParams calldata p) external {
        _params[id] = p;
        _paramsToId[keccak256(abi.encode(p))] = id;
    }

    function setSkipShareCredit(bool v) external {
        skipShareCredit = v;
    }

    function idToMarketParams(Id id) external view returns (MarketParams memory) {
        return _params[id];
    }

    function position(Id id, address user) external view returns (Position memory) {
        return _positions[id][user];
    }

    function supply(
        MarketParams memory p,
        uint256 assets,
        uint256, /* shares */
        address onBehalf,
        bytes memory /* data */
    )
        external
        returns (uint256 assetsSupplied, uint256 sharesSupplied)
    {
        IERC20(p.loanToken).safeTransferFrom(msg.sender, address(this), assets);
        Position storage pos = _positions[_idOf(p)][onBehalf];
        if (!skipShareCredit) {
            pos.supplyShares += assets;
        }
        return (assets, assets);
    }

    function withdraw(
        MarketParams memory p,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    )
        external
        returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn)
    {
        if (msg.sender != onBehalf) {
            require(isAuthorized[onBehalf][msg.sender], "not authorized");
        }
        Position storage pos = _positions[_idOf(p)][onBehalf];

        uint256 amount = assets > 0 ? assets : shares;
        require(pos.supplyShares >= amount, "insufficient");
        pos.supplyShares -= amount;

        IERC20(p.loanToken).safeTransfer(receiver, amount);
        return (amount, amount);
    }

    function setAuthorization(address authorized, bool newIsAuthorized) external {
        isAuthorized[msg.sender][authorized] = newIsAuthorized;
    }

    /// @dev Resolve a `MarketParams` back to the user-supplied id it was registered under.
    function _idOf(MarketParams memory p) internal view returns (Id) {
        return _paramsToId[keccak256(abi.encode(p))];
    }
}
