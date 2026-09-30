// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YoMidnightAdapter } from "src/adapters/midnight/YoMidnightAdapter.sol";
import { Id, IMorpho, MarketParams } from "src/interfaces/IMorpho.sol";
import { CollateralParams, IMidnight, Market, Offer } from "src/vendor/morpho-midnight/interfaces/IMidnight.sol";
import {
    IBlueBuyCallbackFactory
} from "src/vendor/morpho-midnight/periphery/blue-buy-callback/interfaces/IBlueBuyCallbackFactory.sol";
import { ISetterRatifier } from "src/vendor/morpho-midnight/ratifiers/interfaces/ISetterRatifier.sol";
import { HashLib } from "src/vendor/morpho-midnight/ratifiers/libraries/HashLib.sol";

import { Fork_Test } from "../Fork_Test.t.sol";

interface IBlueBuyCallbackExtended {
    function setAuthorization(address authorized, bool newIsAuthorized) external;
}

interface IMorphoExtended is IMorpho {
    function createMarket(MarketParams memory) external;
}

/// @dev Collateral oracle for the test market: 1 cbBTC (8 decimals) = 60,000 USDC (6 decimals).
contract FixedPriceOracle {
    function price() external pure returns (uint256) {
        return 60_000e6 * 1e36 / 1e8;
    }
}

/// @notice End-to-end against the real Morpho Midnight stack: a real YoVault funds its
///         `BlueBuyCallback` from USDC, ratifies a two-offer tree through `YoMidnightAdapter`, a
///         borrower takes one offer (the callback withdraws from Blue), and the vault redeems its
///         credit after maturity.
abstract contract MidnightFork_Test is Fork_Test {
    bytes32 internal constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    IMorphoExtended internal constant MORPHO = IMorphoExtended(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant LIQUIDATION_CURSOR = 0.3e18;
    uint256 internal constant TERM = 30 days;
    uint256 internal constant TICK = 6000;
    uint256 internal constant FUND_AMOUNT = 100_000e6;
    uint256 internal constant TAKE_UNITS = 10_000e6;

    IMidnight internal midnight;
    ISetterRatifier internal ratifier;
    IBlueBuyCallbackFactory internal factory;
    IERC20 internal usdc;

    YoMidnightAdapter internal adapter;
    address internal callback;
    address internal borrower;
    MarketParams internal fundingParams;
    Id internal fundingId;
    bytes32 internal marketId;

    function _rpcEnv() internal pure virtual returns (string memory);

    function _forkBlock() internal pure virtual returns (uint256);

    function _chainConfig()
        internal
        pure
        virtual
        returns (address midnight_, address ratifier_, address factory_, address usdc_, address weth_, address irm_);

    function setUp() public {
        _maybeSkip(_forkIfAvailable(_rpcEnv(), _forkBlock()), _rpcEnv());
        // Midnight is compiled for Osaka; the repo default `cancun` rejects its opcodes.
        vm.setEvmVersion("osaka");
        (address m, address r, address f, address u, address weth, address irm) = _chainConfig();
        midnight = IMidnight(m);
        ratifier = ISetterRatifier(r);
        factory = IBlueBuyCallbackFactory(f);
        usdc = IERC20(u);

        _deployStack(usdc, "Yo USDC Vault", "yoUSDC");
        borrower = makeAddr("Borrower");

        adapter = new YoMidnightAdapter(
            IMorpho(address(MORPHO)), midnight, ratifier, factory, marketRegistry, 60 days, 0, yoRegistry
        );
        callback = factory.createBlueBuyCallback(address(yoVault), bytes32(0));
        vm.label(address(adapter), "YoMidnightAdapter");
        vm.label(callback, "BlueBuyCallback");

        // Fresh Blue funding market. `createMarket` does not validate the oracle.
        fundingParams =
            MarketParams({ loanToken: u, collateralToken: weth, oracle: address(0xCAFE), irm: irm, lltv: LLTV });
        MORPHO.createMarket(fundingParams);
        fundingId = Id.wrap(keccak256(abi.encode(fundingParams)));

        // Fresh Midnight market, so the test does not depend on a market that expires.
        Market memory market = _market();
        marketId = midnight.touchMarket(market);

        vm.startPrank(users.owner);
        marketRegistry.setAllowed(address(yoVault), fundingId, true);
        marketRegistry.setAllowed(address(yoVault), adapter.marketFamilyId(market), true);
        vm.stopPrank();

        // Governance set-up for the vault. The operator keeps no rights on these selectors.
        _governanceManage(
            address(midnight), abi.encodeCall(IMidnight.setIsAuthorized, (address(ratifier), true, address(yoVault)))
        );
        _governanceManage(
            address(midnight), abi.encodeCall(IMidnight.setIsAuthorized, (address(adapter), true, address(yoVault)))
        );
        bytes memory authorizeAdapter =
            abi.encodeCall(IBlueBuyCallbackExtended.setAuthorization, (address(adapter), true));
        _governanceManage(callback, authorizeAdapter);
        _vaultApprove(usdc, address(adapter), FUND_AMOUNT);

        deal(address(usdc), address(yoVault), FUND_AMOUNT);
    }

    function testFork_Midnight_FundRatifyTakeRedeem() external {
        // Fund the callback.
        _opManage(address(adapter), abi.encodeCall(YoMidnightAdapter.fundCallback, (callback, fundingId, FUND_AMOUNT)));
        assertEq(usdc.balanceOf(address(yoVault)), 0, "vault funded the callback");
        assertGt(MORPHO.position(fundingId, callback).supplyShares, 0, "callback Blue position");
        assertEq(MORPHO.position(fundingId, address(yoVault)).supplyShares, 0, "no vault Blue position");

        // Ratify a two-offer tree.
        Offer[] memory offers = new Offer[](2);
        offers[0] = _offer(TICK);
        offers[1] = _offer(TICK + 4);
        bytes memory ret = _opManage(address(adapter), abi.encodeCall(YoMidnightAdapter.ratify, (offers)));
        bytes32 root = abi.decode(ret, (bytes32));
        assertTrue(ratifier.isRootRatified(address(yoVault), root), "root ratified");

        // Morpho's ratifier accepts both leaves, so our root matches Midnight's hashing.
        bytes32 leaf0 = HashLib.hashOffer(offers[0]);
        bytes32 leaf1 = HashLib.hashOffer(offers[1]);
        assertEq(ratifier.isRatified(offers[0], _proof(root, 0, leaf1), borrower), CALLBACK_SUCCESS, "leaf 0");
        assertEq(ratifier.isRatified(offers[1], _proof(root, 1, leaf0), borrower), CALLBACK_SUCCESS, "leaf 1");

        // A borrower takes offer 0: the callback withdraws from Blue and the vault gets credit.
        uint256 callbackBlueBefore = _callbackBlueAssets();
        Market memory market = _market();
        deal(CBBTC, borrower, 1e8);
        vm.startPrank(borrower);
        IERC20(CBBTC).approve(address(midnight), 1e8);
        midnight.supplyCollateral(market, 0, 1e8, borrower);
        (uint256 buyerAssets,) =
            midnight.take(offers[0], _proof(root, 0, leaf1), TAKE_UNITS, borrower, borrower, address(0), "");
        vm.stopPrank();

        assertEq(midnight.credit(marketId, address(yoVault)), TAKE_UNITS, "vault credit");
        assertLt(buyerAssets, TAKE_UNITS, "bought at a discount");
        assertApproxEqAbs(callbackBlueBefore - _callbackBlueAssets(), buyerAssets, 1, "callback funded the fill");

        // After maturity the borrower repays and the vault redeems its credit.
        vm.warp(market.maturity + 1);
        deal(address(usdc), borrower, TAKE_UNITS);
        vm.startPrank(borrower);
        usdc.approve(address(midnight), TAKE_UNITS);
        midnight.repay(market, TAKE_UNITS, borrower, address(0), "");
        vm.stopPrank();

        _opManage(address(adapter), abi.encodeCall(YoMidnightAdapter.redeem, (market, TAKE_UNITS)));
        assertEq(midnight.credit(marketId, address(yoVault)), 0, "credit redeemed");
        assertEq(usdc.balanceOf(address(yoVault)), TAKE_UNITS, "vault received face value");

        // Pull the rest of the callback position back to the vault.
        _opManage(address(adapter), abi.encodeCall(YoMidnightAdapter.defundCallbackAll, (callback, fundingId)));
        assertEq(MORPHO.position(fundingId, callback).supplyShares, 0, "callback position closed");
        assertGe(
            usdc.balanceOf(address(yoVault)), FUND_AMOUNT - buyerAssets + TAKE_UNITS - 1, "vault made the discount"
        );
    }

    function testFork_Midnight_UnratifiedRootCannotBeTaken() external {
        _opManage(address(adapter), abi.encodeCall(YoMidnightAdapter.fundCallback, (callback, fundingId, FUND_AMOUNT)));
        Offer[] memory offers = new Offer[](1);
        offers[0] = _offer(TICK);
        bytes memory ret = _opManage(address(adapter), abi.encodeCall(YoMidnightAdapter.ratify, (offers)));
        bytes32 root = abi.decode(ret, (bytes32));

        _opManage(address(adapter), abi.encodeCall(YoMidnightAdapter.unratify, (root)));

        assertFalse(ratifier.isRootRatified(address(yoVault), root), "root cleared");
        vm.expectRevert();
        ratifier.isRatified(offers[0], abi.encode(root, uint256(0), new bytes32[](0)), borrower);
    }

    /// @dev Run one set-up call through `manage`, then revoke the operator's right on that selector.
    function _governanceManage(address target, bytes memory data) internal {
        _opManage(target, data);
        authority.setAllowed(users.operator, target, bytes4(data), false);
    }

    function _market() internal returns (Market memory market) {
        market.chainId = block.chainid;
        market.midnight = address(midnight);
        market.loanToken = address(usdc);
        market.collateralParams = new CollateralParams[](1);
        market.collateralParams[0] = CollateralParams({
            token: CBBTC,
            lltv: LLTV,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(_oracle())
        });
        // Fixed per test run: every call must return the same market.
        market.maturity = _maturity();
    }

    FixedPriceOracle private _cachedOracle;
    uint256 private _cachedMaturity;

    function _oracle() private returns (FixedPriceOracle) {
        if (address(_cachedOracle) == address(0)) {
            _cachedOracle = new FixedPriceOracle();
        }
        return _cachedOracle;
    }

    function _maturity() private returns (uint256) {
        if (_cachedMaturity == 0) {
            _cachedMaturity = block.timestamp + TERM;
        }
        return _cachedMaturity;
    }

    function _offer(uint256 tick) internal returns (Offer memory offer) {
        offer.market = _market();
        offer.buy = true;
        offer.maker = address(yoVault);
        offer.start = block.timestamp;
        offer.expiry = offer.market.maturity;
        offer.tick = tick;
        offer.group = keccak256("yo.test.group");
        offer.callback = callback;
        offer.callbackData = abi.encode(fundingParams);
        offer.ratifier = address(ratifier);
        offer.maxAssets = uint128(FUND_AMOUNT);
        // Matches the adapter's `maxContinuousFeeCap` (0); the default USDC continuous fee is 0.
        offer.continuousFeeCap = 0;
    }

    function _proof(bytes32 root, uint256 index, bytes32 sibling) internal pure returns (bytes memory) {
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = sibling;
        return abi.encode(root, index, proof);
    }

    function _callbackBlueAssets() internal returns (uint256) {
        // Blue supply is 1e6 shares per asset at creation and no interest accrues without borrows.
        return MORPHO.position(fundingId, callback).supplyShares / 1e6;
    }
}

contract MidnightFork_Base_Test is MidnightFork_Test {
    function _rpcEnv() internal pure override returns (string memory) {
        return "BASE_RPC_URL";
    }

    function _forkBlock() internal pure override returns (uint256) {
        return 52_001_205;
    }

    function _chainConfig() internal pure override returns (address, address, address, address, address, address) {
        return (
            0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A, // Midnight
            0x800B5F12A61B8198a5a6EfD794Cac6699B294d63, // SetterRatifier
            0x7337f119Eca028bD39E0e543cEf71631D2333425, // BlueBuyCallbackFactory
            0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, // USDC
            0x4200000000000000000000000000000000000006, // WETH
            0x46415998764C29aB2a25CbeA6254146D50D22687 // AdaptiveCurveIrm
        );
    }
}

contract MidnightFork_Ethereum_Test is MidnightFork_Test {
    function _rpcEnv() internal pure override returns (string memory) {
        return "MAINNET_RPC_URL";
    }

    function _forkBlock() internal pure override returns (uint256) {
        return 26_091_993;
    }

    function _chainConfig() internal pure override returns (address, address, address, address, address, address) {
        return (
            0x471686c42792F93528B000beF54bC10E3aa2045f, // Midnight
            0xb72c416382c8A6399D0765CebfB032F040B00B3c, // SetterRatifier
            0x172d1FdC5f79bFe1ED46448f18541E591E5c93a7, // BlueBuyCallbackFactory
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
            0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, // WETH
            0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC // AdaptiveCurveIrm
        );
    }
}
