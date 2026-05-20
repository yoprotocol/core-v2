// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAuthority } from "src/interfaces/IAuthority.sol";
import { YoOracle } from "src/YoOracle.sol";
import { YoVault } from "src/YoVault.sol";

import { Base_Test } from "../Base.t.sol";
import { MockAuthority } from "../mocks/MockAuthority.sol";

import { ERC4626AdapterHandler } from "./handlers/ERC4626AdapterHandler.sol";
import { IPORAdapterHandler } from "./handlers/IPORAdapterHandler.sol";
import { LidoAdapterHandler } from "./handlers/LidoAdapterHandler.sol";
import { MorphoAdapterHandler } from "./handlers/MorphoAdapterHandler.sol";
import { OracleHandler } from "./handlers/OracleHandler.sol";
import { SwapAdapterHandler } from "./handlers/SwapAdapterHandler.sol";
import { VaultHandler } from "./handlers/VaultHandler.sol";
import { Store } from "./stores/Store.sol";

/// @notice Protocol-wide invariants for the operator-safety architecture.
/// @dev    Deploys a real `YoVault` behind an ERC-1967 proxy and a real `YoOracle` etched at the
///         hard-coded `ORACLE_ADDRESS`, so vault accounting and oracle drift are exercised end-to-
///         end by the same set of handlers. `StdInvariant` is inherited transitively via Test.
// solhint-disable-next-line contract-name-capwords
contract Invariant_Test is Base_Test {
    /// @dev Selector for `manage(address,bytes,uint256)` — overloaded so we hash explicitly.
    bytes4 internal constant MANAGE_SINGLE_SELECTOR = bytes4(keccak256("manage(address,bytes,uint256)"));

    YoVault internal yoVault;
    YoOracle internal oracle;
    MockAuthority internal authority;
    address internal updater;
    Store internal store;

    // Handlers.
    VaultHandler internal vaultHandler;
    OracleHandler internal oracleHandler;
    MorphoAdapterHandler internal morphoHandler;
    SwapAdapterHandler internal swapHandler;
    ERC4626AdapterHandler internal erc4626Handler;
    IPORAdapterHandler internal iporHandler;
    LidoAdapterHandler internal lidoHandler;

    // Actors for VaultHandler.
    address internal alice2;
    address internal bob2;
    address internal carol;

    function setUp() public virtual override {
        Base_Test.setUp();

        updater = makeAddr("OracleUpdater");
        alice2 = users.alice;
        bob2 = users.bob;
        carol = makeAddr("Carol");

        // ------------------------------------------------------------------
        // 1. Etch a real YoOracle at the hard-coded ORACLE_ADDRESS
        // ------------------------------------------------------------------
        // Window: 1h. Max change: 10% (1e8 in 1e9-BPS units).
        YoOracle template = new YoOracle(updater, 1 hours, 1e8);
        address oracleAddr = 0x6E879d0CcC85085A709eBf5539224f53d0D396B0;
        vm.etch(oracleAddr, address(template).code);
        // Ownable._owner (slot 0) → this test contract so we can call onlyOwner setters.
        vm.store(oracleAddr, bytes32(uint256(0)), bytes32(uint256(uint160(address(this)))));
        // YoOracle.updater (slot 2, after Ownable._owner and Ownable2Step._pendingOwner).
        vm.store(oracleAddr, bytes32(uint256(2)), bytes32(uint256(uint160(updater))));
        oracle = YoOracle(oracleAddr);
        vm.label(oracleAddr, "YoOracle@etch");

        // ------------------------------------------------------------------
        // 2. Deploy YoVault behind an ERC-1967 proxy (USDC, 6 decimals)
        // ------------------------------------------------------------------
        YoVault impl = new YoVault();
        bytes memory initData =
            abi.encodeCall(YoVault.initialize, (IERC20(address(usdc)), users.owner, "Yo USDC Vault", "yoUSDC"));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        yoVault = YoVault(payable(address(proxy)));
        vm.label(address(impl), "YoVaultImpl");
        vm.label(address(yoVault), "YoVault");

        // Authority — single shared instance gating manage/fulfill/cancel/pause/fee setters.
        authority = new MockAuthority();
        vm.prank(users.owner);
        yoVault.setAuthority(IAuthority(address(authority)));
        authority.setAllowed(users.operator, address(yoVault), MANAGE_SINGLE_SELECTOR, true);
        authority.setAllowed(users.operator, address(yoVault), YoVault.fulfillRedeem.selector, true);
        authority.setAllowed(users.operator, address(yoVault), YoVault.cancelRedeem.selector, true);
        authority.setAllowed(users.operator, address(yoVault), YoVault.pause.selector, true);
        authority.setAllowed(users.operator, address(yoVault), YoVault.unpause.selector, true);
        authority.setAllowed(users.operator, address(yoVault), YoVault.updateWithdrawFee.selector, true);
        authority.setAllowed(users.operator, address(yoVault), YoVault.updateDepositFee.selector, true);
        authority.setAllowed(users.operator, address(yoVault), YoVault.updateFeeRecipient.selector, true);
        // Operator must also be allowed to call `approveToken` via manage's inner check.
        authority.setAllowed(users.operator, address(yoVault), YoVault.approveToken.selector, true);

        // Approval registry binding.
        vm.prank(users.owner);
        yoVault.setApprovalRegistry(approvalRegistry);

        // Configure a deposit fee recipient up-front so we can verify fee accrual.
        vm.prank(users.owner);
        yoVault.updateFeeRecipient(makeAddr("FeeSink"));

        // ------------------------------------------------------------------
        // 3. Oracle bootstrap — set per-vault config and seed an initial price
        // ------------------------------------------------------------------
        oracle.setAssetConfig(address(yoVault), 1 hours, 1e8);
        vm.prank(updater);
        oracle.updateSharePrice(address(yoVault), 1e6);

        // ------------------------------------------------------------------
        // 4. Register YoVault everywhere so adapters accept it as caller
        // ------------------------------------------------------------------
        yoRegistry.setVault(address(yoVault), true);
        _setupMarket(defaults.MARKET_A(), address(usdc));
        _allowMarket(address(yoVault), defaults.MARKET_A());
        mockOracle.setQuote(address(usdc), address(usdt), defaults.ORACLE_QUOTE_1_TO_1());
        _allowPair(address(yoVault), address(usdc), address(usdt));
        _allowYieldVault(address(yoVault), mockYieldVault);
        _allowYieldVault(address(yoVault), mockPlasmaVault);

        // Pre-approve every adapter from the vault (sidesteps the approveToken/registry-cap dance
        // for non-approveToken-focused handlers; the VaultHandler exercises approveToken directly).
        vm.startPrank(address(yoVault));
        usdc.approve(address(morphoAdapter), type(uint256).max);
        usdc.approve(address(swapAdapter), type(uint256).max);
        usdc.approve(address(yieldAdapter), type(uint256).max);
        usdc.approve(address(iporAdapter), type(uint256).max);
        mockYieldVault.approve(address(yieldAdapter), type(uint256).max);
        mockPlasmaVault.approve(address(iporAdapter), type(uint256).max);
        mockWETH.approve(address(lidoAdapter), type(uint256).max);
        mockStETH.approve(address(lidoAdapter), type(uint256).max);
        mockLidoQueue.setApprovalForAll(address(lidoAdapter), true);
        mockMorpho.setAuthorization(address(morphoAdapter), true);
        vm.stopPrank();

        // Seed an approval-registry cap for one of the actors so `approveToken` has a valid path.
        _setApproval(address(yoVault), address(usdc), carol, 2_000_000e6);

        // ------------------------------------------------------------------
        // 5. Deploy store + handlers
        // ------------------------------------------------------------------
        store = new Store();
        vm.label(address(store), "Store");

        address[3] memory actors = [alice2, bob2, carol];

        vaultHandler = new VaultHandler(yoVault, usdc, approvalRegistry, users.operator, actors, store);
        oracleHandler = new OracleHandler(oracle, address(yoVault), updater, store);
        morphoHandler = new MorphoAdapterHandler(morphoAdapter, address(yoVault), usdc, defaults.MARKET_A(), store);
        swapHandler =
            new SwapAdapterHandler(swapAdapter, address(yoVault), usdc, usdt, mockAggregator, mockOracle, store);
        erc4626Handler = new ERC4626AdapterHandler(yieldAdapter, address(yoVault), usdc, mockYieldVault, store);
        iporHandler = new IPORAdapterHandler(
            iporAdapter, address(yoVault), usdc, mockPlasmaVault, mockIPORWithdrawManager, store
        );
        lidoHandler = new LidoAdapterHandler(lidoAdapter, address(yoVault), mockWETH, mockStETH, mockLidoQueue, store);

        // Pre-fund the swap aggregator to deliver tokenOut.
        usdt.mint(address(mockAggregator), 5_000_000e6);

        // Target handlers; exclude infrastructure as senders.
        targetContract(address(vaultHandler));
        targetContract(address(oracleHandler));
        targetContract(address(morphoHandler));
        targetContract(address(swapHandler));
        targetContract(address(erc4626Handler));
        targetContract(address(iporHandler));
        targetContract(address(lidoHandler));

        excludeSender(address(store));
        excludeSender(address(yoVault));
        excludeSender(address(oracle));
        excludeSender(address(authority));
        excludeSender(address(mockMorpho));
        excludeSender(address(mockAggregator));
        excludeSender(address(mockOracle));
        excludeSender(address(mockYieldVault));
        excludeSender(address(mockPlasmaVault));
        excludeSender(address(mockIPORWithdrawManager));
        excludeSender(address(mockWETH));
        excludeSender(address(mockStETH));
        excludeSender(address(mockLidoQueue));
        excludeSender(address(morphoAdapter));
        excludeSender(address(swapAdapter));
        excludeSender(address(yieldAdapter));
        excludeSender(address(iporAdapter));
        excludeSender(address(lidoAdapter));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     VAULT MATH
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice sum pending[u].assets == totalPendingAssets.
    function invariant_PendingAssets_SumMatches() external view {
        address[] memory recipients = store.pendingRecipients();
        uint256 sum;
        for (uint256 i; i < recipients.length; ++i) {
            (uint256 a,) = yoVault.pendingRedeemRequest(recipients[i]);
            sum += a;
        }
        assertEq(sum, yoVault.totalPendingAssets(), "sum pending assets != totalPendingAssets");
    }

    /// @notice sum pending[u].shares == balanceOf(vault).
    function invariant_PendingShares_MatchVaultEscrow() external view {
        address[] memory recipients = store.pendingRecipients();
        uint256 sum;
        for (uint256 i; i < recipients.length; ++i) {
            (, uint256 s) = yoVault.pendingRedeemRequest(recipients[i]);
            sum += s;
        }
        assertEq(sum, yoVault.balanceOf(address(yoVault)), "sum pending shares != vault self-balance");
    }

    /// @notice asset.balanceOf(vault) >= totalPendingAssets — solvency for queued claims.
    function invariant_Solvency_ForPendingClaims() external view {
        assertGe(usdc.balanceOf(address(yoVault)), yoVault.totalPendingAssets(), "vault asset balance below pending");
    }

    /// @notice totalAssets() == price * totalSupply() / 10**decimals.
    function invariant_TotalAssets_MatchesOraclePricing() external view {
        uint256 supply = yoVault.totalSupply();
        if (supply == 0) {
            assertEq(yoVault.totalAssets(), 0, "totalAssets non-zero on empty vault");
            return;
        }
        (uint256 price,) = oracle.getLatestPrice(address(yoVault));
        uint256 expected = (price * supply) / (10 ** yoVault.decimals());
        assertEq(yoVault.totalAssets(), expected, "totalAssets != oracle * supply");
    }

    /// @notice For every recipient, assets==0 ⟺ shares==0.
    function invariant_PendingState_AssetsAndSharesPair() external view {
        address[] memory recipients = store.pendingRecipients();
        for (uint256 i; i < recipients.length; ++i) {
            (uint256 a, uint256 s) = yoVault.pendingRedeemRequest(recipients[i]);
            if (a == 0) assertEq(s, 0, "assets==0 but shares!=0");
            if (s == 0) assertEq(a, 0, "shares==0 but assets!=0");
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ROUNDING / CONVERSIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice previewMint(previewDeposit(x)) <= x.
    function invariant_PreviewRoundTrip_DepositMint() external view {
        uint256[3] memory amounts = [uint256(1), 1e6, 1e12];
        for (uint256 i; i < amounts.length; ++i) {
            uint256 shares = yoVault.previewDeposit(amounts[i]);
            if (shares == 0) continue;
            uint256 back = yoVault.previewMint(shares);
            assertLe(back, amounts[i], "previewMint(previewDeposit(x)) > x");
        }
    }

    /// @notice previewWithdraw(previewRedeem(s)) <= s.
    function invariant_PreviewRoundTrip_RedeemWithdraw() external view {
        uint256[3] memory shares = [uint256(1), 1e6, 1e12];
        for (uint256 i; i < shares.length; ++i) {
            uint256 assets = yoVault.previewRedeem(shares[i]);
            if (assets == 0) continue;
            uint256 back = yoVault.previewWithdraw(assets);
            assertLe(back, shares[i], "previewWithdraw(previewRedeem(s)) > s");
        }
    }

    /// @notice previewDeposit is non-decreasing in assets.
    function invariant_PreviewDeposit_Monotonic() external view {
        assertLe(yoVault.previewDeposit(1), yoVault.previewDeposit(1e6), "previewDeposit not monotonic");
        assertLe(yoVault.previewDeposit(1e6), yoVault.previewDeposit(1e12), "previewDeposit not monotonic");
    }

    /// @notice convertToShares ∘ convertToAssets <= identity.
    function invariant_ConvertRoundTrip_Floors() external view {
        uint256[3] memory shares = [uint256(1), 1e6, 1e12];
        for (uint256 i; i < shares.length; ++i) {
            uint256 assets = yoVault.convertToAssets(shares[i]);
            uint256 back = yoVault.convertToShares(assets);
            assertLe(back, shares[i], "convertToShares(convertToAssets(s)) > s");
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                       FEES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice deposit / withdraw fees stay below MAX_FEE.
    function invariant_FeesWithinBound() external view {
        uint256 max = 1e17;
        assertLt(yoVault.feeOnDeposit(), max, "deposit fee exceeds MAX_FEE");
        assertLt(yoVault.feeOnWithdraw(), max, "withdraw fee exceeds MAX_FEE");
    }

    /// @notice fee recipient holds at least the cumulative fees accrued in this run.
    function invariant_FeeRecipient_BalanceLowerBound() external view {
        address r = yoVault.feeRecipient();
        if (r == address(0)) return;
        assertGe(usdc.balanceOf(r), store.cumulativeFeesAccrued(), "fee recipient balance below accrued");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   STATE MACHINE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice while paused, totalSupply cannot change.
    function invariant_Pause_FreezesSupply() external view {
        if (!yoVault.paused() || !store.frozen()) return;
        assertEq(yoVault.totalSupply(), store.frozenSupply(), "supply changed while paused");
    }

    /// @notice cumulativeMinted - cumulativeBurned == totalSupply.
    function invariant_ShareSupply_TracksMintsAndBurns() external view {
        assertEq(
            store.cumulativeMinted() - store.cumulativeBurned(),
            yoVault.totalSupply(),
            "cumulative mint/burn delta != totalSupply"
        );
    }

    /// @notice every successful `approveToken(amount > 0)` had cap >= amount at call time.
    function invariant_ApproveToken_RespectsRegistryCap() external view {
        assertFalse(store.approveTokenViolation(), "approveToken bypassed registry cap");
    }

    /// @notice swap output matches vault balance delta within the slippage tolerance.
    function invariant_SwapOutput_BindsVaultDelta() external view {
        assertFalse(store.swapOutputViolation(), "swap output did not match vault delta");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                      ORACLE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice oracle drift / timestamp / window-rotation rules.
    function invariant_Oracle_DriftAndRotation() external view {
        assertFalse(store.oracleViolation(), "oracle invariant violated");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  ADAPTER CUSTODY
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Morpho adapter holds zero loanToken between txs.
    function invariant_MorphoAdapter_HoldsZeroBalance() external view {
        assertEq(usdc.balanceOf(address(morphoAdapter)), 0, "morpho adapter holds USDC");
    }

    /// @notice Morpho adapter has zero standing Morpho allowance.
    function invariant_MorphoAdapter_ZeroAllowance() external view {
        assertEq(
            usdc.allowance(address(morphoAdapter), address(mockMorpho)),
            0,
            "morpho adapter has standing Morpho allowance"
        );
    }

    /// @notice Morpho authorization on the singleton stays intact.
    function invariant_MorphoAuthorization_Intact() external view {
        assertTrue(
            mockMorpho.isAuthorized(address(yoVault), address(morphoAdapter)), "morpho adapter authorization revoked"
        );
    }

    /// @notice Swap adapter holds zero tokenIn / tokenOut between txs.
    function invariant_SwapAdapter_HoldsZeroBalance() external view {
        assertEq(usdc.balanceOf(address(swapAdapter)), 0, "swap adapter holds USDC");
        assertEq(usdt.balanceOf(address(swapAdapter)), 0, "swap adapter holds USDT");
    }

    /// @notice Swap adapter has zero standing aggregator allowance.
    function invariant_SwapAdapter_ZeroAllowance() external view {
        assertEq(
            usdc.allowance(address(swapAdapter), address(mockAggregator)),
            0,
            "swap adapter has standing aggregator allowance"
        );
    }

    /// @notice ERC-4626 adapter holds zero asset and zero yield-vault shares between txs.
    function invariant_ERC4626Adapter_HoldsZeroBalance() external view {
        assertEq(usdc.balanceOf(address(yieldAdapter)), 0, "4626 adapter holds USDC");
        assertEq(mockYieldVault.balanceOf(address(yieldAdapter)), 0, "4626 adapter holds yield-vault shares");
    }

    /// @notice ERC-4626 adapter has zero allowance to the yield vault.
    function invariant_ERC4626Adapter_ZeroAllowance() external view {
        assertEq(
            usdc.allowance(address(yieldAdapter), address(mockYieldVault)),
            0,
            "4626 adapter has standing yield-vault allowance"
        );
    }

    /// @notice IPOR adapter holds zero asset / zero shares between txs.
    function invariant_IPORAdapter_HoldsZeroBalance() external view {
        assertEq(usdc.balanceOf(address(iporAdapter)), 0, "ipor adapter holds USDC");
        assertEq(mockPlasmaVault.balanceOf(address(iporAdapter)), 0, "ipor adapter holds plasma shares");
    }

    /// @notice IPOR adapter has zero allowance to the PlasmaVault.
    function invariant_IPORAdapter_ZeroAllowance() external view {
        assertEq(
            usdc.allowance(address(iporAdapter), address(mockPlasmaVault)),
            0,
            "ipor adapter has standing plasma-vault allowance"
        );
    }

    /// @notice Lido adapter holds zero stETH **shares** and zero WETH / ETH between txs.
    function invariant_LidoAdapter_HoldsZeroBalance() external view {
        assertEq(mockStETH.sharesOf(address(lidoAdapter)), 0, "lido adapter holds stETH shares");
        assertEq(mockWETH.balanceOf(address(lidoAdapter)), 0, "lido adapter holds WETH");
        assertEq(address(lidoAdapter).balance, 0, "lido adapter holds ETH");
    }

    /// @notice Lido adapter has zero standing allowance to the withdrawal queue.
    function invariant_LidoAdapter_ZeroAllowance() external view {
        assertEq(
            IERC20(address(mockStETH)).allowance(address(lidoAdapter), address(mockLidoQueue)),
            0,
            "lido adapter has standing queue allowance"
        );
    }
}
