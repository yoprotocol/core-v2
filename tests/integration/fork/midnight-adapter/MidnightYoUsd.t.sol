// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/src/Test.sol";

import { Configure_MidnightVault } from "script/Configure_MidnightVault.s.sol";
import { IRolesAuthorityMidnight, MidnightSafeBatch } from "script/MidnightSafeBatch.sol";
import { Revoke_MidnightAdapter } from "script/Revoke_MidnightAdapter.s.sol";
import { YoMidnightAdapter } from "src/adapters/midnight/YoMidnightAdapter.sol";
import { Id, IMorpho } from "src/interfaces/IMorpho.sol";
import { IYoMidnightRegistry } from "src/interfaces/IYoMidnightRegistry.sol";
import { IYoMorphoMarketRegistry } from "src/interfaces/IYoMorphoMarketRegistry.sol";
import { IYoRegistry } from "src/interfaces/IYoRegistry.sol";
import { Errors } from "src/libraries/Errors.sol";
import { YoMidnightRegistry } from "src/registries/YoMidnightRegistry.sol";
import { IMidnight, Market, Offer } from "src/vendor/morpho-midnight/interfaces/IMidnight.sol";
import {
    IBlueBuyCallbackFactory
} from "src/vendor/morpho-midnight/periphery/blue-buy-callback/interfaces/IBlueBuyCallbackFactory.sol";
import { ISetterRatifier } from "src/vendor/morpho-midnight/ratifiers/interfaces/ISetterRatifier.sol";
import { YoVault } from "src/YoVault.sol";

/// @notice The yoUSD Midnight enable batch on an Ethereum fork, against the live yoUSD vault, shared
///         `RolesAuthority`, registries, Morpho Blue, and Morpho Midnight. The test deploys a new adapter and
///         {YoMidnightRegistry}, executes the {Configure_MidnightVault} batch as the admin Safe, and then runs
///         the operator flows through `manage` as the live role-12 operator. The revoke cases run the
///         {Revoke_MidnightAdapter} batch after it.
contract MidnightYoUsdForkTest is Test {
    uint256 internal constant FORK_BLOCK = 26_276_000;

    YoVault internal constant YO_USD = YoVault(payable(0x0000000f2eB9f69274678c76222B35eEc7588a65));
    /// @dev Holds role 12 on the shared `RolesAuthority`.
    address internal constant OPERATOR = 0x93e5260Ac975B475aF8BF818c14DEEE7fEfd5927;
    IYoRegistry internal constant YO_REGISTRY = IYoRegistry(0x56c3119DC3B1a75763C87D5B0A2C55E489502232);
    IYoMorphoMarketRegistry internal constant MARKET_REGISTRY =
        IYoMorphoMarketRegistry(0xcB9737BdD076251744704cc37CE961E8417fDd7f);

    IMorpho internal constant MORPHO = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    IMidnight internal constant MIDNIGHT = IMidnight(0x471686c42792F93528B000beF54bC10E3aa2045f);
    ISetterRatifier internal constant RATIFIER = ISetterRatifier(0xb72c416382c8A6399D0765CebfB032F040B00B3c);
    IBlueBuyCallbackFactory internal constant FACTORY =
        IBlueBuyCallbackFactory(0x172d1FdC5f79bFe1ED46448f18541E591E5c93a7);

    /// @dev Morpho `market_family_id` of the USDC / cbBTC markets.
    bytes32 internal constant FAMILY = 0x92ddba8234595212f5b76d5b908690a05dfe2282d6e0af714fa9e73ac27b68e1;
    /// @dev A live Midnight market of `FAMILY`.
    bytes32 internal constant FAMILY_MARKET = 0xeea94e3f7185bb8cfcdf41aca2c9776788e86d6c14de345b911b04f75cd49959;
    /// @dev Blue cbBTC/USDC 86%.
    Id internal constant FUNDING_MARKET = Id.wrap(0x64d65c9a2d91c36d56fbc42d69e979335320169b3df63bf92789e2c8883fcc64);

    IERC20 internal constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    uint256 internal constant CBBTC_INDEX = 1;

    uint256 internal constant CAP = 1_000_000e6;
    uint256 internal constant FUND_AMOUNT = 500e6;
    uint256 internal constant TAKE_UNITS = 200e6;
    /// @dev About 7.2% per year over the 30-day term.
    uint256 internal constant TICK = 4400;
    /// @dev 3% per year.
    uint256 internal constant MIN_RATE = 0.03e18 / uint256(365 days);
    /// @dev 0.5% per year, as on the live adapter.
    uint256 internal constant MAX_CONTINUOUS_FEE_CAP = 158_548_960;

    Configure_MidnightVault internal script;
    Configure_MidnightVault.Inputs internal inputs;
    YoMidnightAdapter internal adapter;
    address internal callback;
    address internal borrower;
    Market internal market;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0, "MAINNET_RPC_URL not set; skipping fork test");
        vm.createSelectFork(rpc, FORK_BLOCK);
        // Midnight is compiled for Osaka; the repo default `cancun` rejects its opcodes.
        vm.setEvmVersion("osaka");

        address safe = YO_USD.owner();
        YoMidnightRegistry midnightRegistry = new YoMidnightRegistry(safe);
        adapter = _deployAdapter(midnightRegistry);

        script = new Configure_MidnightVault();
        bytes32[] memory families = new bytes32[](1);
        families[0] = FAMILY;
        bytes32[] memory fundingMarkets = new bytes32[](1);
        fundingMarkets[0] = Id.unwrap(FUNDING_MARKET);
        inputs = Configure_MidnightVault.Inputs({
            vault: YO_USD,
            adapter: adapter,
            midnightRegistry: midnightRegistry,
            familyIds: families,
            fundingMarketIds: fundingMarkets,
            cap: CAP,
            approvalCap: CAP,
            callbackSalt: bytes32(0),
            operatorRole: 12,
            tempRole: 250
        });

        // The admin Safe batch.
        script.execute(safe, script.build(inputs));
        script.verify(inputs);
        callback = FACTORY.callbackOf(address(YO_USD), bytes32(0));

        // A new maturity in the family, so the test does not depend on a live market's maturity.
        market = MIDNIGHT.toMarket(FAMILY_MARKET);
        market.maturity = block.timestamp + 30 days;
        MIDNIGHT.touchMarket(market);

        borrower = makeAddr("Borrower");
        // The vault may hold its USDC in venues; the flows need FUND_AMOUNT idle.
        deal(address(USDC), address(YO_USD), USDC.balanceOf(address(YO_USD)) + FUND_AMOUNT);
        vm.label(address(YO_USD), "yoUSD");
        vm.label(address(adapter), "YoMidnightAdapter");
        vm.label(callback, "yoUSDCallback");
    }

    function testFork_YoUsd_BatchIsComplete() external {
        assertEq(Id.unwrap(adapter.marketFamilyId(market)), FAMILY, "test market is in the family");
        assertEq(script.build(inputs).length, 0, "a rebuilt batch is empty");
    }

    function testFork_YoUsd_FundRatifyTakeRedeemDefund() external {
        uint256 vaultUsdcBefore = USDC.balanceOf(address(YO_USD));

        // Operator: approve, fund the callback, ratify one offer, revoke the approval.
        Offer[] memory offers = new Offer[](1);
        offers[0] = _offer();
        vm.startPrank(OPERATOR);
        YO_USD.approveToken(address(USDC), address(adapter), FUND_AMOUNT);
        bytes[] memory results = _manage(
            abi.encodeCall(YoMidnightAdapter.fundCallback, (callback, FUNDING_MARKET, FUND_AMOUNT)),
            abi.encodeCall(YoMidnightAdapter.ratify, (offers))
        );
        YO_USD.approveToken(address(USDC), address(adapter), 0);
        vm.stopPrank();
        bytes32 root = abi.decode(results[1], (bytes32));

        assertEq(adapter.deployedAssets(address(YO_USD)), FUND_AMOUNT, "deployed assets");
        assertTrue(RATIFIER.isRootRatified(address(YO_USD), root), "root ratified");

        // A borrower takes the offer. A one-leaf tree has an empty proof. The family's collaterals are
        // USDC (98%) and cbBTC (86%).
        assertEq(market.collateralParams[CBBTC_INDEX].token, CBBTC, "cbBTC collateral");
        deal(CBBTC, borrower, 0.01e8);
        vm.startPrank(borrower);
        IERC20(CBBTC).approve(address(MIDNIGHT), 0.01e8);
        MIDNIGHT.supplyCollateral(market, CBBTC_INDEX, 0.01e8, borrower);
        MIDNIGHT.take(
            offers[0], abi.encode(root, uint256(0), new bytes32[](0)), TAKE_UNITS, borrower, borrower, address(0), ""
        );
        vm.stopPrank();
        bytes32 marketId = MIDNIGHT.touchMarket(market);
        assertEq(MIDNIGHT.credit(marketId, address(YO_USD)), TAKE_UNITS, "yoUSD credit");

        // After maturity: the borrower repays; the operator redeems, defunds, and revokes the root.
        vm.warp(market.maturity + 1);
        deal(address(USDC), borrower, TAKE_UNITS);
        vm.startPrank(borrower);
        USDC.approve(address(MIDNIGHT), TAKE_UNITS);
        MIDNIGHT.repay(market, TAKE_UNITS, borrower, address(0), "");
        vm.stopPrank();

        vm.startPrank(OPERATOR);
        _manage(
            abi.encodeCall(YoMidnightAdapter.redeem, (market, TAKE_UNITS)),
            abi.encodeCall(YoMidnightAdapter.defundCallbackAll, (callback, FUNDING_MARKET))
        );
        _manage(abi.encodeCall(YoMidnightAdapter.unratify, (root)));
        vm.stopPrank();

        assertEq(MIDNIGHT.credit(marketId, address(YO_USD)), 0, "credit redeemed");
        assertEq(MORPHO.position(FUNDING_MARKET, callback).supplyShares, 0, "callback defunded");
        assertEq(adapter.deployedAssets(address(YO_USD)), 0, "deployed assets");
        assertFalse(RATIFIER.isRootRatified(address(YO_USD), root), "root revoked");
        assertGt(USDC.balanceOf(address(YO_USD)), vaultUsdcBefore, "yoUSD earned yield");
    }

    function testFork_YoUsd_RevokeMigratesToAReplacementAdapter() external {
        // A live root through the retired adapter.
        Offer[] memory offers = new Offer[](1);
        offers[0] = _offer();
        vm.prank(OPERATOR);
        bytes32 root = abi.decode(_manage(abi.encodeCall(YoMidnightAdapter.ratify, (offers)))[0], (bytes32));

        // The admin Safe enables a replacement adapter, then revokes the retired one.
        address safe = YO_USD.owner();
        Configure_MidnightVault.Inputs memory enableInputs = inputs;
        enableInputs.adapter = _deployAdapter(inputs.midnightRegistry);
        script.execute(safe, script.build(enableInputs));
        script.verify(enableInputs);
        Revoke_MidnightAdapter revoke = new Revoke_MidnightAdapter();
        Revoke_MidnightAdapter.Inputs memory revokeInputs = _revokeInputs(address(enableInputs.adapter));
        revoke.execute(safe, revoke.build(revokeInputs));
        revoke.verify(revokeInputs);
        assertEq(revoke.build(revokeInputs).length, 0, "a rebuilt batch is empty");

        // The root stays ratified until the replacement adapter revokes it.
        assertTrue(RATIFIER.isRootRatified(address(YO_USD), root), "root still ratified");
        vm.startPrank(OPERATOR);
        _manageOn(address(enableInputs.adapter), abi.encodeCall(YoMidnightAdapter.unratify, (root)));
        assertFalse(RATIFIER.isRootRatified(address(YO_USD), root), "root revoked");

        // The operator cannot call the retired adapter.
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.TargetMethodNotAuthorized.selector, address(adapter), YoMidnightAdapter.ratify.selector
            )
        );
        _manage(abi.encodeCall(YoMidnightAdapter.ratify, (offers)));
        vm.stopPrank();
        assertFalse(MIDNIGHT.isAuthorized(address(YO_USD), address(adapter)), "Midnight auth revoked");
    }

    function testFork_YoUsd_RevokeRevertsWhenTheReplacementIsNotAuthorized() external {
        Revoke_MidnightAdapter revoke = new Revoke_MidnightAdapter();
        address replacement = address(_deployAdapter(inputs.midnightRegistry));
        vm.expectRevert(
            abi.encodeWithSelector(Revoke_MidnightAdapter.ReplacementNotAuthorized.selector, "Midnight", replacement)
        );
        revoke.build(_revokeInputs(replacement));
    }

    function testFork_YoUsd_EnableRevertsWhenTheTempRoleHasACapability() external {
        Configure_MidnightVault.Inputs memory enableInputs = inputs;
        enableInputs.adapter = _deployAdapter(inputs.midnightRegistry);
        // The batch would remove this capability at its end.
        IRolesAuthorityMidnight authority = IRolesAuthorityMidnight(address(YO_USD.authority()));
        vm.prank(YO_USD.owner());
        authority.setRoleCapability(250, address(MIDNIGHT), IMidnight.setIsAuthorized.selector, true);

        vm.expectRevert(abi.encodeWithSelector(MidnightSafeBatch.TempRoleInUse.selector, uint8(250)));
        script.build(enableInputs);
    }

    function _deployAdapter(IYoMidnightRegistry midnightRegistry) internal returns (YoMidnightAdapter) {
        return new YoMidnightAdapter(
            MORPHO,
            MIDNIGHT,
            RATIFIER,
            FACTORY,
            MARKET_REGISTRY,
            midnightRegistry,
            60 days,
            1 days,
            MAX_CONTINUOUS_FEE_CAP,
            MIN_RATE,
            YO_REGISTRY
        );
    }

    function _revokeInputs(address replacement) internal view returns (Revoke_MidnightAdapter.Inputs memory) {
        return Revoke_MidnightAdapter.Inputs({
            vault: YO_USD,
            adapter: adapter,
            replacement: replacement,
            callbackSalt: bytes32(0),
            operatorRole: 12,
            tempRole: 250
        });
    }

    function _offer() internal view returns (Offer memory offer) {
        offer.market = market;
        offer.buy = true;
        offer.maker = address(YO_USD);
        offer.start = block.timestamp;
        offer.expiry = market.maturity;
        offer.tick = TICK;
        offer.group = keccak256("yoUSD.midnight.enable");
        offer.callback = callback;
        offer.callbackData = abi.encode(MORPHO.idToMarketParams(FUNDING_MARKET));
        offer.ratifier = address(RATIFIER);
        offer.maxAssets = uint128(FUND_AMOUNT);
        offer.continuousFeeCap = MAX_CONTINUOUS_FEE_CAP;
    }

    function _manage(bytes memory data0) internal returns (bytes[] memory) {
        bytes[] memory data = new bytes[](1);
        data[0] = data0;
        return _manage(data);
    }

    function _manage(bytes memory data0, bytes memory data1) internal returns (bytes[] memory) {
        bytes[] memory data = new bytes[](2);
        (data[0], data[1]) = (data0, data1);
        return _manage(data);
    }

    function _manageOn(address target, bytes memory data0) internal returns (bytes[] memory) {
        address[] memory targets = new address[](1);
        targets[0] = target;
        bytes[] memory data = new bytes[](1);
        data[0] = data0;
        return YO_USD.manage(targets, data, new uint256[](1));
    }

    function _manage(bytes[] memory data) internal returns (bytes[] memory) {
        address[] memory targets = new address[](data.length);
        for (uint256 i = 0; i < data.length; ++i) {
            targets[i] = address(adapter);
        }
        return YO_USD.manage(targets, data, new uint256[](data.length));
    }
}
