// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console2 } from "forge-std/src/console2.sol";
import { Test } from "forge-std/src/Test.sol";

import { TempAuthority } from "script/Authorize_MorphoAdapter.s.sol";
import { YoMidnightAdapter } from "src/adapters/midnight/YoMidnightAdapter.sol";
import { IAuthority } from "src/interfaces/IAuthority.sol";
import { Id, IMorpho, MarketParams } from "src/interfaces/IMorpho.sol";
import { IYoApprovalRegistry } from "src/interfaces/IYoApprovalRegistry.sol";
import { IYoMorphoMarketRegistry } from "src/interfaces/IYoMorphoMarketRegistry.sol";
import { IYoRegistry } from "src/interfaces/IYoRegistry.sol";
import { Errors } from "src/libraries/Errors.sol";
import { CollateralParams, IMidnight, Market, Offer } from "src/vendor/morpho-midnight/interfaces/IMidnight.sol";
import {
    IBlueBuyCallbackFactory
} from "src/vendor/morpho-midnight/periphery/blue-buy-callback/interfaces/IBlueBuyCallbackFactory.sol";
import { ISetterRatifier } from "src/vendor/morpho-midnight/ratifiers/interfaces/ISetterRatifier.sol";
import { YoVault } from "src/YoVault.sol";

/// @dev Subset of the solmate `RolesAuthority` used by the shared YO authority.
interface IRolesAuthority {
    function setUserRole(address user, uint8 role, bool enabled) external;

    function setRoleCapability(uint8 role, address target, bytes4 functionSig, bool enabled) external;
}

interface IBlueBuyCallbackAuth {
    function setAuthorization(address authorized, bool newIsAuthorized) external;
}

/// @notice End-to-end rehearsal of the yoTest rollout on an Ethereum fork, against the LIVE yoTest
///         vault, shared `RolesAuthority`, registries, Morpho Blue, and Morpho Midnight:
///
///           1. Deploy `YoMidnightAdapter` with the production constructor arguments.
///           2. Admin Safe: role-12 capabilities for the adapter, template allowlist, approval cap.
///           3. yoTest owner (TempAuthority swap, as in `Authorize_MorphoAdapter`): create the
///              callback and set the Midnight and Blue authorizations.
///           4. Operator (role 12, batch `manage`): approve, fund the callback, ratify one offer.
///           5. A borrower takes the offer; the callback withdraws from Blue.
///           6. After maturity the borrower repays; the operator redeems and defunds.
///
///         The funding market (Blue cbBTC/USDC 86%) is already on yoTest's allowlist. The Midnight
///         market is created fresh (cbBTC collateral, the Blue market's Chainlink oracle) so the test
///         does not depend on a live market's maturity.
contract MidnightYoTestFork_Test is Test {
    uint256 internal constant FORK_BLOCK = 26_092_191;

    // Live YO deployments on Ethereum.
    YoVault internal constant YO_TEST = YoVault(payable(0xcF0fE5AB46cf260EB281650E8f999237684846AA));
    IRolesAuthority internal constant AUTHORITY = IRolesAuthority(0x9524e25079b1b04D904865704783A5aA0202d44D);
    IYoMorphoMarketRegistry internal constant MARKET_REGISTRY =
        IYoMorphoMarketRegistry(0xcB9737BdD076251744704cc37CE961E8417fDd7f);
    IYoApprovalRegistry internal constant APPROVAL_REGISTRY =
        IYoApprovalRegistry(0xB4b3F5C964A360bBd7201f72a55D0c48B8aD7021);
    IYoRegistry internal constant YO_REGISTRY = IYoRegistry(0x56c3119DC3B1a75763C87D5B0A2C55E489502232);
    /// @dev Owner of the shared authority and of the registries.
    address internal constant ADMIN_SAFE = 0x67b6F699F1c8040414032a3C2C88a54db144FCd2;
    uint8 internal constant OPERATOR_ROLE = 12;

    // Morpho on Ethereum.
    IMorpho internal constant MORPHO = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    IMidnight internal constant MIDNIGHT = IMidnight(0x471686c42792F93528B000beF54bC10E3aa2045f);
    ISetterRatifier internal constant RATIFIER = ISetterRatifier(0xb72c416382c8A6399D0765CebfB032F040B00B3c);
    IBlueBuyCallbackFactory internal constant FACTORY =
        IBlueBuyCallbackFactory(0x172d1FdC5f79bFe1ED46448f18541E591E5c93a7);
    /// @dev Blue cbBTC/USDC 86% — already allowlisted for yoTest.
    Id internal constant FUNDING_MARKET = Id.wrap(0x64d65c9a2d91c36d56fbc42d69e979335320169b3df63bf92789e2c8883fcc64);

    IERC20 internal constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    uint256 internal constant FUND_AMOUNT = 500e6;
    uint256 internal constant TAKE_UNITS = 200e6;
    uint256 internal constant TICK = 6000;

    YoMidnightAdapter internal adapter;
    address internal callback;
    address internal operator;
    address internal borrower;
    MarketParams internal fundingParams;
    Market internal market;
    bytes32 internal marketId;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0, "MAINNET_RPC_URL not set; skipping fork test");
        vm.createSelectFork(rpc, FORK_BLOCK);
        // Midnight is compiled for Osaka; the repo default `cancun` rejects its opcodes.
        vm.setEvmVersion("osaka");

        operator = makeAddr("Operator");
        borrower = makeAddr("Borrower");
        fundingParams = MORPHO.idToMarketParams(FUNDING_MARKET);

        // 1. Deploy with the production constructor arguments (see Deploy_MidnightAdapter).
        adapter = new YoMidnightAdapter(MORPHO, MIDNIGHT, RATIFIER, FACTORY, MARKET_REGISTRY, 60 days, 0, YO_REGISTRY);

        // The Midnight market: cbBTC collateral priced by the funding market's Chainlink oracle.
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] =
            CollateralParams({ token: CBBTC, lltv: 0.86e18, liquidationCursor: 0.3e18, oracle: fundingParams.oracle });
        market = Market({
            chainId: block.chainid,
            midnight: address(MIDNIGHT),
            loanToken: address(USDC),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        marketId = MIDNIGHT.touchMarket(market);

        // 2. Admin Safe batch.
        vm.startPrank(ADMIN_SAFE);
        AUTHORITY.setUserRole(operator, OPERATOR_ROLE, true);
        bytes4[6] memory selectors = [
            YoMidnightAdapter.fundCallback.selector,
            YoMidnightAdapter.defundCallback.selector,
            YoMidnightAdapter.defundCallbackAll.selector,
            YoMidnightAdapter.ratify.selector,
            YoMidnightAdapter.unratify.selector,
            YoMidnightAdapter.redeem.selector
        ];
        for (uint256 i = 0; i < selectors.length; ++i) {
            AUTHORITY.setRoleCapability(OPERATOR_ROLE, address(adapter), selectors[i], true);
        }
        MARKET_REGISTRY.setAllowed(address(YO_TEST), adapter.templateId(market), true);
        APPROVAL_REGISTRY.setApproval(address(YO_TEST), address(USDC), address(adapter), FUND_AMOUNT);
        vm.stopPrank();

        // 3. yoTest owner: one-time vault calls through a TempAuthority swap.
        callback = FACTORY.createBlueBuyCallback(address(YO_TEST), bytes32(0));
        address vaultOwner = YO_TEST.owner();
        vm.startPrank(vaultOwner);
        TempAuthority temp = new TempAuthority(vaultOwner);
        YO_TEST.setAuthority(IAuthority(address(temp)));
        _ownerManage(
            temp,
            address(MIDNIGHT),
            abi.encodeCall(IMidnight.setIsAuthorized, (address(RATIFIER), true, address(YO_TEST)))
        );
        _ownerManage(
            temp,
            address(MIDNIGHT),
            abi.encodeCall(IMidnight.setIsAuthorized, (address(adapter), true, address(YO_TEST)))
        );
        _ownerManage(temp, callback, abi.encodeCall(IBlueBuyCallbackAuth.setAuthorization, (address(adapter), true)));
        YO_TEST.setAuthority(IAuthority(address(AUTHORITY)));
        vm.stopPrank();

        vm.label(address(YO_TEST), "yoTest");
        vm.label(address(adapter), "YoMidnightAdapter");
        vm.label(callback, "yoTestCallback");
        vm.label(address(MIDNIGHT), "Midnight");
        vm.label(address(MORPHO), "MorphoBlue");
    }

    function testFork_YoTest_FundRatifyTakeRedeem() external {
        uint256 vaultUsdcBefore = USDC.balanceOf(address(YO_TEST));

        // 4. Operator: approve, fund the callback, and ratify one offer in one batch.
        vm.startPrank(operator);
        YO_TEST.approveToken(address(USDC), address(adapter), FUND_AMOUNT);
        Offer memory offer = _offer();
        Offer[] memory offers = new Offer[](1);
        offers[0] = offer;
        bytes[] memory results = _operatorBatch(
            address(adapter),
            abi.encodeCall(YoMidnightAdapter.fundCallback, (callback, FUNDING_MARKET, FUND_AMOUNT)),
            address(adapter),
            abi.encodeCall(YoMidnightAdapter.ratify, (offers))
        );
        vm.stopPrank();
        bytes32 root = abi.decode(results[1], (bytes32));

        assertEq(USDC.balanceOf(address(YO_TEST)), vaultUsdcBefore - FUND_AMOUNT, "yoTest funded the callback");
        assertGt(MORPHO.position(FUNDING_MARKET, callback).supplyShares, 0, "callback Blue position");
        assertTrue(RATIFIER.isRootRatified(address(YO_TEST), root), "root ratified");

        // 5. A borrower takes the offer. A one-leaf tree has an empty proof.
        uint256 callbackAssetsBefore = _callbackAssets();
        deal(CBBTC, borrower, 0.01e8);
        vm.startPrank(borrower);
        IERC20(CBBTC).approve(address(MIDNIGHT), 0.01e8);
        MIDNIGHT.supplyCollateral(market, 0, 0.01e8, borrower);
        (uint256 buyerAssets, uint256 sellerAssets) = MIDNIGHT.take(
            offer, abi.encode(root, uint256(0), new bytes32[](0)), TAKE_UNITS, borrower, borrower, address(0), ""
        );
        vm.stopPrank();

        assertEq(MIDNIGHT.credit(marketId, address(YO_TEST)), TAKE_UNITS, "yoTest credit");
        assertLt(buyerAssets, TAKE_UNITS, "yoTest lent at a discount");
        assertEq(USDC.balanceOf(borrower), sellerAssets, "borrower received the loan");
        assertApproxEqAbs(callbackAssetsBefore - _callbackAssets(), buyerAssets, 1, "callback funded the fill");
        console2.log("Adapter:                 ", address(adapter));
        console2.log("yoTest callback:         ", callback);
        console2.log("Ratified root:");
        console2.logBytes32(root);
        console2.log("Credit units (face):     ", TAKE_UNITS);
        console2.log("yoTest paid (buyerAssets):", buyerAssets);
        console2.log("Borrower got (seller):   ", sellerAssets);

        // 6. After maturity: the borrower repays, the operator redeems and defunds.
        vm.warp(market.maturity + 1);
        deal(address(USDC), borrower, TAKE_UNITS);
        vm.startPrank(borrower);
        USDC.approve(address(MIDNIGHT), TAKE_UNITS);
        MIDNIGHT.repay(market, TAKE_UNITS, borrower, address(0), "");
        vm.stopPrank();

        vm.prank(operator);
        _operatorBatch(
            address(adapter),
            abi.encodeCall(YoMidnightAdapter.redeem, (market, TAKE_UNITS)),
            address(adapter),
            abi.encodeCall(YoMidnightAdapter.defundCallbackAll, (callback, FUNDING_MARKET))
        );

        assertEq(MIDNIGHT.credit(marketId, address(YO_TEST)), 0, "credit redeemed");
        assertEq(MORPHO.position(FUNDING_MARKET, callback).supplyShares, 0, "callback defunded");
        // yoTest earned the fixed discount plus Blue interest on the unfilled part.
        assertGt(USDC.balanceOf(address(YO_TEST)), vaultUsdcBefore, "yoTest earned yield");
        console2.log("yoTest USDC before:      ", vaultUsdcBefore);
        console2.log("yoTest USDC after:       ", USDC.balanceOf(address(YO_TEST)));
    }

    function testFork_YoTest_OperatorCannotBypassRatify() external {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(RATIFIER);
        data[0] = abi.encodeCall(ISetterRatifier.setIsRootRatified, (address(YO_TEST), bytes32("root"), true));

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.TargetMethodNotAuthorized.selector, address(RATIFIER), ISetterRatifier.setIsRootRatified.selector
            )
        );
        YO_TEST.manage(targets, data, new uint256[](1));
    }

    function _ownerManage(TempAuthority temp, address target, bytes memory data) internal {
        address vaultOwner = YO_TEST.owner();
        temp.setCapability(vaultOwner, target, bytes4(data), true);
        YO_TEST.manage(target, data, 0);
        temp.setCapability(vaultOwner, target, bytes4(data), false);
    }

    function _operatorBatch(
        address target0,
        bytes memory data0,
        address target1,
        bytes memory data1
    )
        internal
        returns (bytes[] memory)
    {
        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);
        (targets[0], targets[1]) = (target0, target1);
        (data[0], data[1]) = (data0, data1);
        return YO_TEST.manage(targets, data, new uint256[](2));
    }

    function _offer() internal view returns (Offer memory offer) {
        offer.market = market;
        offer.buy = true;
        offer.maker = address(YO_TEST);
        offer.start = block.timestamp;
        offer.expiry = market.maturity;
        offer.tick = TICK;
        offer.group = keccak256("yoTest.midnight.rehearsal");
        offer.callback = callback;
        offer.callbackData = abi.encode(fundingParams);
        offer.ratifier = address(RATIFIER);
        offer.maxAssets = uint128(FUND_AMOUNT);
    }

    function _callbackAssets() internal view returns (uint256) {
        (uint128 totalSupplyAssets, uint128 totalSupplyShares,,,,) =
            IMorphoMarket(address(MORPHO)).market(FUNDING_MARKET);
        return MORPHO.position(FUNDING_MARKET, callback).supplyShares * totalSupplyAssets / totalSupplyShares;
    }
}

interface IMorphoMarket {
    function market(Id id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );
}
