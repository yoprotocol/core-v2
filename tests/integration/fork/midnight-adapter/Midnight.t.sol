// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YoMidnightAdapter } from "src/adapters/midnight/YoMidnightAdapter.sol";
import { CollateralParams, IMidnight, ISetterRatifier, Market, Offer } from "src/interfaces/IMidnight.sol";
import { IYoMidnightMarketRegistry } from "src/interfaces/IYoMidnightMarketRegistry.sol";
import { MidnightHashLib } from "src/libraries/MidnightHashLib.sol";
import { YoMidnightMarketRegistry } from "src/registries/YoMidnightMarketRegistry.sol";

import { Fork_Test } from "../Fork_Test.t.sol";

/// @dev EIP-712 signature tuple accepted by Midnight's `EcrecoverRatifier`.
struct Signature {
    uint8 v;
    bytes32 r;
    bytes32 s;
}

/// @dev Extended Midnight surface used only by the fork harness to drive the counterparty borrower
///      (collateral supply + repay). The production `IMidnight` omits these because the adapter
///      never calls them.
interface IMidnightExtended is IMidnight {
    function supplyCollateral(Market memory market, uint256 collateralIndex, uint256 assets, address onBehalf) external;
    function repay(
        Market memory market,
        uint256 units,
        address onBehalf,
        address callback,
        bytes calldata data
    )
        external;
}

/// @dev Fixed high price so a small cbBTC collateral massively over-collateralizes the borrow, keeping
///      the counterparty healthy without depending on a live oracle. Quoted at Midnight's 1e36 scale.
contract ForkPriceOracle {
    function price() external pure returns (uint256) {
        return 1e40;
    }
}

/// @notice End-to-end: real YoVault → real Morpho Midnight on Base mainnet.
///         `test_Fork_Midnight_LenderRoundTrip` has the vault buy credit from a borrower's
///         Ecrecover-signed sell offer, then redeem it post-maturity after the borrower repays,
///         proving a lossless fixed-rate round trip.
///         `test_Fork_Midnight_MakeOrderSingleLeafRatified` has the vault ratify a single-leaf root
///         through the real `SetterRatifier` and an EOA fill it directly — proving the vendored
///         `MidnightHashLib.hashOffer` matches on-chain hashing byte-for-byte.
/// @dev    Skips unless `BASE_RPC_URL` is set. Midnight relies on the `clz` opcode (Osaka), so this
///         must run under an Osaka-capable EVM (set `FOUNDRY_EVM_VERSION=osaka`). Under the repo's
///         default `cancun` profile the collateral health check reverts with `NotActivated`, matching
///         Midnight's documented opcode requirements.
contract MidnightFork_Test is Fork_Test {
    // Latest block: the public RPC may not retain historical state.
    uint256 internal constant BASE_BLOCK = 0;

    IMidnight internal constant MIDNIGHT = IMidnight(0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A);
    address internal constant SETTER_RATIFIER = 0x800B5F12A61B8198a5a6EfD794Cac6699B294d63;
    address internal constant ECRECOVER_RATIFIER = 0xd6e70365C8E8DDa9a4ca662C07bbE663b017755E;
    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant LIQUIDATION_CURSOR = 0.3e18;

    /// @dev keccak256("EIP712Domain(uint256 chainId,address verifyingContract)").
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218;
    /// @dev `HashLib.offerTreeTypeHash(0)` — the single-leaf (height-0) offer-tree typehash.
    bytes32 internal constant OFFER_TREE_TYPEHASH_0 =
        0x270da1ebafc0f24637af3612fb8c3a1d828fcb56d3637c24e86dd006b12ca7f9;

    uint256 internal constant UNITS = 10_000e6;
    uint256 internal constant COLLATERAL = 1e8; // 1 cbBTC
    uint256 internal constant FUND = 50_000e6;
    uint256 internal constant TICK = 4000; // multiple of the default tick spacing (4); price < 1
    uint32 internal constant MIN_TICK = 3000; // registry sell-side price floor, below TICK

    YoMidnightMarketRegistry internal midnightRegistry;
    YoMidnightAdapter internal adapter;
    ForkPriceOracle internal oracle;
    uint256 internal maturityTs;
    bytes32 internal marketId;

    function setUp() public {
        _maybeSkip(_forkIfAvailable("BASE_RPC_URL", BASE_BLOCK), "BASE_RPC_URL");

        _deployStack(USDC, "Yo USDC Vault", "yoUSDC");

        vm.prank(users.owner);
        midnightRegistry = new YoMidnightMarketRegistry(users.owner);

        adapter = new YoMidnightAdapter(
            MIDNIGHT, ISetterRatifier(SETTER_RATIFIER), IYoMidnightMarketRegistry(address(midnightRegistry)), yoRegistry
        );
        vm.label(address(adapter), "YoMidnightAdapter");

        oracle = new ForkPriceOracle();
        maturityTs = block.timestamp + 30 days;

        // Create the market (permissionless first touch); use the real id for the allowlist.
        marketId = MIDNIGHT.touchMarket(_market());

        vm.prank(users.owner);
        midnightRegistry.setAllowed(address(yoVault), marketId, true, MIN_TICK);

        // Fund + wire the vault per the runbook.
        deal(address(USDC), address(yoVault), FUND);
        _vaultApprove(USDC, address(adapter), FUND); // funds takeBuy
        _vaultApprove(USDC, address(MIDNIGHT), FUND); // maker-buyer direct debit
        _opManage(
            address(MIDNIGHT), abi.encodeCall(IMidnight.setIsAuthorized, (address(adapter), true, address(yoVault)))
        );
        _opManage(
            address(MIDNIGHT), abi.encodeCall(IMidnight.setIsAuthorized, (SETTER_RATIFIER, true, address(yoVault)))
        );
    }

    function test_Fork_Midnight_LenderRoundTrip() external {
        (address borrower, uint256 pk) = makeAddrAndKey("MidnightBorrower");
        _supplyCollateral(borrower);

        // Borrower authorizes the Ecrecover ratifier and signs a sell offer the vault will buy.
        vm.prank(borrower);
        MIDNIGHT.setIsAuthorized(ECRECOVER_RATIFIER, true, borrower);

        Offer memory offer = _borrowerSellOffer(borrower);
        bytes memory ratifierData = _ecrecoverData(offer, pk);

        uint256 vaultBefore = USDC.balanceOf(address(yoVault));
        _opManage(address(adapter), abi.encodeCall(YoMidnightAdapter.takeBuy, (offer, ratifierData, UNITS, UNITS)));

        uint256 vaultAfterBuy = USDC.balanceOf(address(yoVault));
        uint256 buyerAssets = vaultBefore - vaultAfterBuy;
        assertGt(buyerAssets, 0, "vault paid for credit");
        assertLt(buyerAssets, UNITS, "bought credit at a discount");
        assertEq(MIDNIGHT.credit(marketId, address(yoVault)), UNITS, "vault holds the credit");

        // Warp past maturity; borrower repays, making the credit withdrawable.
        vm.warp(maturityTs + 1);
        deal(address(USDC), borrower, UNITS);
        vm.startPrank(borrower);
        USDC.approve(address(MIDNIGHT), type(uint256).max);
        IMidnightExtended(address(MIDNIGHT)).repay(_market(), UNITS, borrower, address(0), "");
        vm.stopPrank();

        _opManage(address(adapter), abi.encodeCall(YoMidnightAdapter.withdrawAll, (_market())));

        uint256 vaultFinal = USDC.balanceOf(address(yoVault));
        assertEq(MIDNIGHT.credit(marketId, address(yoVault)), 0, "credit fully redeemed");
        assertEq(vaultFinal - vaultAfterBuy, UNITS, "redeemed the full unit face value");
        assertEq(vaultFinal, vaultBefore - buyerAssets + UNITS, "round-trip yield == units - buyerAssets");
        assertGt(vaultFinal, vaultBefore, "vault earned the fixed-rate yield");
    }

    function test_Fork_Midnight_MakeOrderSingleLeafRatified() external {
        // Vault posts a maker-buy offer (it lends). makeOrder ratifies the single-leaf root.
        Offer memory offer = _vaultBuyOffer();
        bytes32 root = MidnightHashLib.hashOffer(offer);

        _opManage(address(adapter), abi.encodeCall(YoMidnightAdapter.makeOrder, (offer)));
        assertTrue(ISetterRatifier(SETTER_RATIFIER).isRootRatified(address(yoVault), root), "single-leaf root ratified");

        // An EOA seller supplies collateral and fills the vault's offer directly through Midnight,
        // proving the real SetterRatifier accepts our on-chain-computed hashOffer.
        (address seller,) = makeAddrAndKey("MidnightSeller");
        _supplyCollateral(seller);

        bytes memory ratifierData = abi.encode(root, uint256(0), new bytes32[](0));
        vm.prank(seller);
        MIDNIGHT.take(offer, ratifierData, UNITS, seller, seller, address(0), "");

        assertEq(MIDNIGHT.credit(marketId, address(yoVault)), UNITS, "vault credited from its own ratified offer");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _market() internal view returns (Market memory m) {
        CollateralParams[] memory cp = new CollateralParams[](1);
        cp[0] = CollateralParams({
            token: CBBTC,
            lltv: LLTV,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });
        m = Market({
            chainId: block.chainid,
            midnight: address(MIDNIGHT),
            loanToken: address(USDC),
            collateralParams: cp,
            maturity: maturityTs,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    function _supplyCollateral(address who) internal {
        deal(CBBTC, who, COLLATERAL);
        vm.startPrank(who);
        IERC20(CBBTC).approve(address(MIDNIGHT), type(uint256).max);
        IMidnightExtended(address(MIDNIGHT)).supplyCollateral(_market(), 0, COLLATERAL, who);
        vm.stopPrank();
    }

    function _baseOffer() internal view returns (Offer memory o) {
        o.market = _market();
        o.start = block.timestamp;
        o.expiry = block.timestamp + 7 days;
        o.tick = TICK;
        o.group = keccak256("MIDNIGHT_FORK_GROUP");
        o.callback = address(0);
        o.callbackData = "";
        o.reduceOnly = false;
        o.maxUnits = uint128(UNITS);
        o.maxAssets = 0;
        o.continuousFeeCap = type(uint256).max;
    }

    /// @dev Borrower sells credit to the vault (vault buys via takeBuy). Ecrecover-ratified.
    function _borrowerSellOffer(address borrower) internal view returns (Offer memory o) {
        o = _baseOffer();
        o.buy = false;
        o.maker = borrower;
        o.receiverIfMakerIsSeller = borrower;
        o.ratifier = ECRECOVER_RATIFIER;
    }

    /// @dev Vault's maker-buy offer (vault lends). SetterRatifier-ratified via makeOrder.
    function _vaultBuyOffer() internal view returns (Offer memory o) {
        o = _baseOffer();
        o.buy = true;
        o.maker = address(yoVault);
        o.receiverIfMakerIsSeller = address(0);
        o.ratifier = SETTER_RATIFIER;
    }

    function _ecrecoverData(Offer memory offer, uint256 pk) internal view returns (bytes memory) {
        bytes32 root = MidnightHashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(OFFER_TREE_TYPEHASH_0, root));
        bytes32 domainSeparator = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, ECRECOVER_RATIFIER));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encode(Signature(v, r, s), root, uint256(0), new bytes32[](0));
    }
}
