// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { YoMidnightAdapter } from "src/adapters/midnight/YoMidnightAdapter.sol";
import { CollateralParams, IMidnight, ISetterRatifier, Market, Offer } from "src/interfaces/IMidnight.sol";
import { IYoMidnightMarketRegistry } from "src/interfaces/IYoMidnightMarketRegistry.sol";
import { YoMidnightMarketRegistry } from "src/registries/YoMidnightMarketRegistry.sol";

import { MockMidnight } from "../mocks/MockMidnight.sol";
import { MockSetterRatifier } from "../mocks/MockSetterRatifier.sol";
import { Integration_Test } from "./Integration.t.sol";

/// @notice Shared setup for `YoMidnightAdapter` concrete + fuzz tests. Deploys the Midnight mock
///         stack, wires the standard vault stand-in (`users.vault`) with the runbook authorizations,
///         approvals, and a default allowlisted market, and provides `Market` / `Offer` builders.
abstract contract Midnight_Integration_Shared is Integration_Test {
    MockMidnight internal mockMidnight;
    MockSetterRatifier internal setterRatifier;
    YoMidnightMarketRegistry internal midnightRegistry;
    YoMidnightAdapter internal midnightAdapter;

    /// @dev A funded counterparty for take tests (the maker on the other side of the vault's fill).
    address internal maker;

    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant LIQUIDATION_CURSOR = 0.3e18;
    bytes32 internal constant GROUP_A = keccak256("MIDNIGHT_GROUP_A");
    uint256 internal constant TAKE_UNITS = 10_000e6;
    uint256 internal constant MAX_ASSETS = 10_000e6;
    /// @dev Registry sell-side price floor for the default market, and an offer tick comfortably above
    ///      it. Floor-rejection tests use a tick below `MIN_TICK` (e.g. 0).
    uint32 internal constant MIN_TICK = 100;
    uint256 internal constant TICK = 4000;

    function setUp() public virtual override {
        Integration_Test.setUp();

        mockMidnight = new MockMidnight();
        setterRatifier = new MockSetterRatifier(address(mockMidnight));

        vm.startPrank(users.owner);
        midnightRegistry = new YoMidnightMarketRegistry(users.owner);
        midnightAdapter = new YoMidnightAdapter(
            IMidnight(address(mockMidnight)),
            ISetterRatifier(address(setterRatifier)),
            IYoMidnightMarketRegistry(address(midnightRegistry)),
            yoRegistry
        );
        vm.stopPrank();

        vm.label(address(mockMidnight), "MockMidnight");
        vm.label(address(setterRatifier), "MockSetterRatifier");
        vm.label(address(midnightRegistry), "YoMidnightMarketRegistry");
        vm.label(address(midnightAdapter), "YoMidnightAdapter");

        maker = makeAddr("MidnightMaker");

        // Runbook: vault authorizes the adapter (take/withdraw/setConsumed/ratify on its behalf) and
        // the SetterRatifier (required by take for the vault's own maker offers).
        vm.startPrank(users.vault);
        mockMidnight.setIsAuthorized(address(midnightAdapter), true, users.vault);
        mockMidnight.setIsAuthorized(address(setterRatifier), true, users.vault);
        // Vault funds `takeBuy` through the adapter and, as a maker-buyer, is debited by Midnight.
        usdc.approve(address(midnightAdapter), type(uint256).max);
        usdc.approve(address(mockMidnight), type(uint256).max);
        vm.stopPrank();

        // Allowlist the default market for the vault. Resolve the id first: a view call in the
        // argument list would otherwise consume the prank before `setAllowed` runs.
        bytes32 id = marketId();
        vm.prank(users.owner);
        midnightRegistry.setAllowed(users.vault, id, true, MIN_TICK);

        // Pre-fund Midnight so redemptions can pay out.
        usdc.mint(address(mockMidnight), 1_000_000e6);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     BUILDERS
    //////////////////////////////////////////////////////////////////////////*/

    function market() internal view returns (Market memory m) {
        CollateralParams[] memory cp = new CollateralParams[](1);
        cp[0] = CollateralParams({
            token: address(weth),
            lltv: LLTV,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(0xCAFE)
        });
        m = Market({
            chainId: block.chainid,
            midnight: address(mockMidnight),
            loanToken: address(usdc),
            collateralParams: cp,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    function marketId() internal view returns (bytes32) {
        return mockMidnight.idOf(market());
    }

    /// @dev Base offer skeleton with the fields common to every side. Callers set `buy`, `maker`,
    ///      `receiverIfMakerIsSeller`, `reduceOnly`, and the size caps.
    function _baseOffer() internal view returns (Offer memory o) {
        o.market = market();
        o.maker = users.vault;
        o.start = block.timestamp;
        o.expiry = block.timestamp + 7 days;
        o.tick = TICK;
        o.group = GROUP_A;
        o.callback = address(0);
        o.callbackData = "";
        o.ratifier = address(setterRatifier);
        o.reduceOnly = false;
        o.maxUnits = 0;
        o.maxAssets = uint128(MAX_ASSETS);
        o.continuousFeeCap = type(uint256).max;
    }

    /// @dev Valid vault maker-buy offer (vault lends): `buy == true`, no seller receiver.
    function validBuyOffer() internal view returns (Offer memory o) {
        o = _baseOffer();
        o.buy = true;
        o.receiverIfMakerIsSeller = address(0);
    }

    /// @dev Valid vault maker-sell offer (vault exits credit): `buy == false`, reduce-only, proceeds
    ///      pinned to the vault.
    function validSellOffer() internal view returns (Offer memory o) {
        o = _baseOffer();
        o.buy = false;
        o.reduceOnly = true;
        o.receiverIfMakerIsSeller = users.vault;
        // Sell offers must cap by units, not assets (adapter invariant).
        o.maxUnits = uint128(TAKE_UNITS);
        o.maxAssets = 0;
    }

    /// @dev A counterparty sell offer the vault buys via `takeBuy` (`buy == false`, maker is the seller).
    function makerSellOffer() internal view returns (Offer memory o) {
        o = _baseOffer();
        o.maker = maker;
        o.buy = false;
        o.receiverIfMakerIsSeller = maker;
    }

    /// @dev A counterparty buy offer the vault sells into via `takeSell` (`buy == true`, maker is the buyer).
    function makerBuyOffer() internal view returns (Offer memory o) {
        o = _baseOffer();
        o.maker = maker;
        o.buy = true;
        o.receiverIfMakerIsSeller = address(0);
    }

    /// @dev Fund + approve the counterparty maker so Midnight can pull its buyer assets.
    function _fundMaker(uint256 amount) internal {
        usdc.mint(maker, amount);
        vm.prank(maker);
        usdc.approve(address(mockMidnight), type(uint256).max);
    }
}
