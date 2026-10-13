// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { YoMidnightAdapter } from "src/adapters/midnight/YoMidnightAdapter.sol";
import { IYoMidnightRegistry } from "src/interfaces/IYoMidnightRegistry.sol";
import { Id, IMorpho, MarketParams } from "src/interfaces/IMorpho.sol";
import { CollateralParams, IMidnight, Market, Offer } from "src/vendor/morpho-midnight/interfaces/IMidnight.sol";
import {
    IBlueBuyCallbackFactory
} from "src/vendor/morpho-midnight/periphery/blue-buy-callback/interfaces/IBlueBuyCallbackFactory.sol";
import { YoMidnightRegistry } from "src/registries/YoMidnightRegistry.sol";
import { ISetterRatifier } from "src/vendor/morpho-midnight/ratifiers/interfaces/ISetterRatifier.sol";

import {
    MockBlueBuyCallback,
    MockBlueBuyCallbackFactory,
    MockMidnight,
    MockSetterRatifier
} from "../../../mocks/MockMidnight.sol";
import { Integration_Test } from "../../Integration.t.sol";

/// @notice Shared set-up for `YoMidnightAdapter` concrete tests: mock Midnight stack, one callback
///         per vault, and an allowlisted funding market and market family for `users.vault`.
abstract contract MidnightAdapter_Integration_Concrete_Test is Integration_Test {
    uint256 internal constant MAX_TIME_TO_MATURITY = 60 days;
    uint256 internal constant MIN_TERM = 1 days;
    /// @dev Midnight's `MAX_CONTINUOUS_FEE`: 1% per year.
    uint256 internal constant MAX_CONTINUOUS_FEE_CAP = 0.01e18 / uint256(365 days);
    /// @dev 3% per year.
    uint256 internal constant MIN_RATE = 0.03e18 / uint256(365 days);
    uint256 internal constant TERM = 30 days;
    /// @dev About 7.2% per year over `TERM`.
    uint256 internal constant TICK = 4400;
    /// @dev About 2.7% per year over `TERM`, below `MIN_RATE`.
    uint256 internal constant TICK_BELOW_MIN_RATE = 4600;
    uint256 internal constant FUND_AMOUNT = 10_000e6;
    /// @dev `users.vault`'s cap in `midnightRegistry`: twice `FUND_AMOUNT`.
    uint256 internal constant CAP = 20_000e6;

    MockMidnight internal mockMidnight;
    MockSetterRatifier internal mockRatifier;
    MockBlueBuyCallbackFactory internal mockCallbackFactory;
    YoMidnightRegistry internal midnightRegistry;
    YoMidnightAdapter internal midnightAdapter;

    /// @dev `users.vault`'s callback.
    address internal callback;
    /// @dev A factory callback owned by `users.eve`.
    address internal eveCallback;

    MarketParams internal fundingParams;
    /// @dev Real Blue id of `fundingParams`, as the adapter derives it from offer callback data.
    Id internal fundingId;

    function setUp() public virtual override {
        Integration_Test.setUp();

        mockMidnight = new MockMidnight();
        mockRatifier = new MockSetterRatifier(address(mockMidnight));
        mockCallbackFactory = new MockBlueBuyCallbackFactory(address(mockMidnight), address(mockMorpho));
        midnightRegistry = new YoMidnightRegistry(users.owner);
        midnightAdapter = _deployAdapter(
            IMorpho(address(mockMorpho)),
            IMidnight(address(mockMidnight)),
            ISetterRatifier(address(mockRatifier)),
            IBlueBuyCallbackFactory(address(mockCallbackFactory))
        );
        callback = mockCallbackFactory.createBlueBuyCallback(users.vault);
        eveCallback = mockCallbackFactory.createBlueBuyCallback(users.eve);
        vm.label(address(mockMidnight), "MockMidnight");
        vm.label(address(mockRatifier), "MockSetterRatifier");
        vm.label(address(mockCallbackFactory), "MockBlueBuyCallbackFactory");
        vm.label(address(midnightRegistry), "YoMidnightRegistry");
        vm.label(address(midnightAdapter), "YoMidnightAdapter");
        vm.label(callback, "VaultCallback");
        vm.label(eveCallback, "EveCallback");

        fundingParams = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(0xC0),
            oracle: address(0),
            irm: address(0),
            lltv: 0
        });
        fundingId = Id.wrap(keccak256(abi.encode(fundingParams)));
        mockMorpho.setMarketParams(fundingId, fundingParams);
        _allowMarket(users.vault, fundingId);
        _allowMarket(users.vault, midnightAdapter.marketFamilyId(_market(block.timestamp + TERM)));

        // `users.vault` stands in for a USDC YoVault.
        vm.mockCall(users.vault, abi.encodeCall(IERC4626.asset, ()), abi.encode(address(usdc)));
        vm.prank(users.owner);
        midnightRegistry.setCap(users.vault, CAP);

        // Governance set-up for the vault.
        vm.startPrank(users.vault);
        usdc.approve(address(midnightAdapter), type(uint256).max);
        mockMidnight.setIsAuthorized(address(mockRatifier), true, users.vault);
        mockMidnight.setIsAuthorized(address(midnightAdapter), true, users.vault);
        MockBlueBuyCallback(callback).setAuthorization(address(midnightAdapter), true);
        vm.stopPrank();
    }

    function _deployAdapter(
        IMorpho morpho,
        IMidnight midnight,
        ISetterRatifier ratifier,
        IBlueBuyCallbackFactory factory
    )
        internal
        returns (YoMidnightAdapter)
    {
        return new YoMidnightAdapter(
            morpho,
            midnight,
            ratifier,
            factory,
            marketRegistry,
            IYoMidnightRegistry(address(midnightRegistry)),
            MAX_TIME_TO_MATURITY,
            MIN_TERM,
            MAX_CONTINUOUS_FEE_CAP,
            MIN_RATE,
            yoRegistry
        );
    }

    function _market(uint256 maturity) internal view returns (Market memory market) {
        market.chainId = block.chainid;
        market.midnight = address(mockMidnight);
        market.loanToken = address(usdc);
        market.collateralParams = new CollateralParams[](1);
        market.collateralParams[0] = CollateralParams({
            token: address(weth),
            lltv: 0.86e18,
            liquidationCursor: 0.3e18,
            oracle: address(0x0AC1E)
        });
        market.maturity = maturity;
    }

    /// @dev A valid `users.vault` lend bid in the default market family.
    function _offer() internal view returns (Offer memory offer) {
        offer.market = _market(block.timestamp + TERM);
        offer.buy = true;
        offer.maker = users.vault;
        offer.expiry = offer.market.maturity;
        offer.tick = TICK;
        offer.group = keccak256("GROUP");
        offer.callback = callback;
        offer.callbackData = abi.encode(fundingParams);
        offer.ratifier = address(mockRatifier);
        offer.maxAssets = uint128(FUND_AMOUNT);
    }

    /// @dev `count` independent copies of `offer`, so tests can edit one leaf.
    function _offers(Offer memory offer, uint256 count) internal pure returns (Offer[] memory offers) {
        offers = new Offer[](count);
        for (uint256 i = 0; i < count; ++i) {
            offers[i] = abi.decode(abi.encode(offer), (Offer));
        }
    }

    function _fundCallback(uint256 assets) internal {
        vm.prank(users.vault);
        midnightAdapter.fundCallback(callback, fundingId, assets);
    }
}
