// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMidnight, Market, Offer } from "src/interfaces/IMidnight.sol";

/// @notice Minimal Morpho Midnight stand-in for adapter unit/integration tests.
/// @dev Models only what `YoMidnightAdapter` observes: market ids via `keccak256(abi.encode(market))`,
///      per-user credit, per-market withdrawable, authorization, group consumed budgets, and the
///      `take` / `withdraw` token flows (payer pulls + receiver settlement). Pricing is a single
///      configurable `priceWad` (unit price) with an optional `feeWad` settlement fee — enough to
///      exercise rounding and slippage without vendoring `TickLib`. Fork tests hit the real deployment.
contract MockMidnight is IMidnight {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;

    mapping(bytes32 id => bool) public created;
    mapping(bytes32 id => mapping(address user => uint128)) public creditOf;
    mapping(bytes32 id => uint128) public withdrawableOf;
    mapping(address authorizer => mapping(address authorized => bool)) public isAuthorized;
    mapping(address user => mapping(bytes32 group => uint128)) public consumed;
    /// @dev Pending loss to apply to a position on its next accrual (models loss-factor slashing).
    mapping(bytes32 id => mapping(address user => uint128)) public slashOf;

    /// @dev Unit price in WAD (loan tokens per credit unit). Default 0.99 implies a positive yield.
    uint256 public priceWad = 0.99e18;
    /// @dev Settlement fee in WAD, skimmed by the protocol. Default 0.
    uint256 public feeWad;
    /// @dev When true, `take` performs its transfers but skips crediting the buyer — forces the
    ///      adapter's `NoCreditDelta` branch deterministically.
    bool public skipCreditOnTake;

    /*//////////////////////////////////////////////////////////////////////////
                                   TEST CONFIG
    //////////////////////////////////////////////////////////////////////////*/

    function idOf(Market memory market) public pure returns (bytes32) {
        return keccak256(abi.encode(market));
    }

    function setCredit(bytes32 id, address user, uint128 amount) external {
        creditOf[id][user] = amount;
    }

    function setWithdrawable(bytes32 id, uint128 amount) external {
        withdrawableOf[id] = amount;
    }

    /// @dev Queue a loss to be applied to `user`'s credit on the next accrual (take / withdraw / view).
    function setSlash(bytes32 id, address user, uint128 amount) external {
        slashOf[id][user] = amount;
    }

    function setPrice(uint256 newPriceWad) external {
        priceWad = newPriceWad;
    }

    function setFee(uint256 newFeeWad) external {
        feeWad = newFeeWad;
    }

    function setSkipCreditOnTake(bool value) external {
        skipCreditOnTake = value;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     IMIDNIGHT
    //////////////////////////////////////////////////////////////////////////*/

    function touchMarket(Market memory market) public returns (bytes32 id) {
        id = idOf(market);
        created[id] = true;
    }

    function credit(bytes32 id, address user) external view returns (uint128) {
        return creditOf[id][user];
    }

    function withdrawable(bytes32 id) external view returns (uint128) {
        return withdrawableOf[id];
    }

    function setIsAuthorized(address authorized, bool newIsAuthorized, address onBehalf) external {
        require(onBehalf == msg.sender || isAuthorized[onBehalf][msg.sender], "unauthorized");
        isAuthorized[onBehalf][authorized] = newIsAuthorized;
    }

    function setConsumed(bytes32 group, uint128 amount, address onBehalf) external {
        require(onBehalf == msg.sender || isAuthorized[onBehalf][msg.sender], "unauthorized");
        require(amount >= consumed[onBehalf][group], "already consumed");
        consumed[onBehalf][group] = amount;
    }

    function updatePositionView(
        Market memory,
        bytes32 id,
        address user
    )
        external
        view
        returns (uint128 newCredit, uint128 newPendingFee, uint128 accruedFee)
    {
        uint128 c = creditOf[id][user];
        uint128 s = slashOf[id][user];
        return (s < c ? c - s : 0, 0, 0);
    }

    function withdraw(Market memory market, uint256 units, address onBehalf, address receiver) external {
        require(onBehalf == msg.sender || isAuthorized[onBehalf][msg.sender], "unauthorized");
        bytes32 id = idOf(market);
        _accrue(id, onBehalf);
        creditOf[id][onBehalf] -= _toU128(units);
        withdrawableOf[id] -= _toU128(units);
        IERC20(market.loanToken).safeTransfer(receiver, units);
    }

    /// @dev Mirrors Midnight's payer/receiver wiring: the buyer's assets are pulled from the payer
    ///      (the maker when the maker buys, else `msg.sender`), the seller's assets go to `receiver`,
    ///      and the fee is retained. Credit moves from seller to buyer in `units`.
    function take(
        Offer memory offer,
        bytes memory,
        uint256 units,
        address taker,
        address receiverIfTakerIsSeller,
        address,
        bytes memory
    )
        external
        returns (uint256 buyerAssets, uint256 sellerAssets)
    {
        require(taker == msg.sender || isAuthorized[taker][msg.sender], "taker unauthorized");
        bytes32 id = idOf(offer.market);
        created[id] = true;

        uint256 sellerPrice = offer.buy ? priceWad - feeWad : priceWad;
        uint256 buyerPrice = sellerPrice + feeWad;
        buyerAssets = offer.buy ? (units * buyerPrice) / WAD : _ceilDiv(units * buyerPrice, WAD);
        sellerAssets = offer.buy ? (units * sellerPrice) / WAD : _ceilDiv(units * sellerPrice, WAD);

        IERC20 token = IERC20(offer.market.loanToken);
        if (offer.buy) {
            // Maker buys, taker (vault) sells: maker pays, proceeds go to the taker's receiver.
            token.safeTransferFrom(offer.maker, address(this), buyerAssets - sellerAssets);
            token.safeTransferFrom(offer.maker, receiverIfTakerIsSeller, sellerAssets);
            _accrue(id, taker);
            creditOf[id][taker] -= _toU128(units);
        } else {
            // Maker sells, taker (vault) buys: msg.sender (adapter) pays, proceeds go to the maker.
            token.safeTransferFrom(msg.sender, address(this), buyerAssets - sellerAssets);
            token.safeTransferFrom(msg.sender, offer.receiverIfMakerIsSeller, sellerAssets);
            if (!skipCreditOnTake) {
                _accrue(id, taker);
                creditOf[id][taker] += _toU128(units);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     INTERNAL
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Applies any queued loss to `user`'s credit and clears it — models a one-shot loss-factor
    ///      slash realised at accrual time (take / withdraw).
    function _accrue(bytes32 id, address user) internal {
        uint128 s = slashOf[id][user];
        if (s > 0) {
            uint128 c = creditOf[id][user];
            creditOf[id][user] = s < c ? c - s : 0;
            slashOf[id][user] = 0;
        }
    }

    function _ceilDiv(uint256 x, uint256 d) internal pure returns (uint256) {
        return (x + d - 1) / d;
    }

    function _toU128(uint256 x) internal pure returns (uint128) {
        require(x <= type(uint128).max, "overflow");
        return uint128(x);
    }
}
