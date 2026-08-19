// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { YoVault } from "../src/YoVault.sol";
import { yoUSDT } from "../src/yoUSDT.sol";

import { BaseScript } from "./Base.s.sol";
import { ChainId } from "./ChainId.sol";

/// @notice Deploys the vault implementations for the fleet-wide upgrade, via deterministic CREATE2
///         (salt `Version V3.0.0`), idempotently:
///
///           - {YoVault}: expected at {EXPECTED_YOVAULT_IMPL} on every chain. Already deployed on
///             Ethereum, Base, Arbitrum, and HyperEVM (2026-07-22 build, live on Arbitrum yoUSD),
///             so this is a no-op safety net there. The script REVERTS if the locally compiled
///             bytecode does not land on the expected address — that catches building with the
///             wrong profile (must be the default profile: optimizer on, 10k runs, solc 0.8.34)
///             or with drifted sources.
///
///           - {yoUSDT} (Ethereum only): the USDT extension subclass. The yoUSDT proxy must NOT be
///             upgraded to the plain {YoVault} impl — it overrides `_oracleAsset` to price against
///             yoUSD and relays deposits — so it gets its own freshly compiled implementation.
///
///         Anyone can broadcast (deployment goes through the canonical CREATE2 factory; the
///         resulting addresses are sender-independent).
///
///         Run per chain (default profile — do NOT set FOUNDRY_PROFILE=lite):
///           forge script script/Deploy_VaultImpls.s.sol:Deploy_VaultImpls \
///               --rpc-url <mainnet|base|arbitrum|hyperliquid> -vvv --broadcast <signer flags>
contract Deploy_VaultImpls is BaseScript {
    error UnexpectedImplAddress(string what, address computed, address expected);

    /// @dev The 2026-07-22 {YoVault} build every proxy is being upgraded to.
    address internal constant EXPECTED_YOVAULT_IMPL = 0xcfF43A89d3Ee3Ad8DAb0117cf679f45a34c87AA7;

    /// @dev Current-repo {yoUSDT} build (computed with the default profile).
    address internal constant EXPECTED_YOUSDT_IMPL = 0x5AB7761c08b7b6d9Ac08404Ad107ecf16C4b650e;

    function run() public broadcast {
        address yoVaultImpl = vm.computeCreate2Address(SALT, keccak256(type(YoVault).creationCode));
        if (yoVaultImpl != EXPECTED_YOVAULT_IMPL) {
            revert UnexpectedImplAddress("YoVault", yoVaultImpl, EXPECTED_YOVAULT_IMPL);
        }
        if (yoVaultImpl.code.length == 0) {
            yoVaultImpl = address(new YoVault{ salt: SALT }());
            console2.log("YoVault impl deployed:", yoVaultImpl);
        } else {
            console2.log("YoVault impl already deployed:", yoVaultImpl);
        }

        if (chainId == ChainId.ETHEREUM) {
            address yoUsdtImpl = vm.computeCreate2Address(SALT, keccak256(type(yoUSDT).creationCode));
            if (yoUsdtImpl != EXPECTED_YOUSDT_IMPL) {
                revert UnexpectedImplAddress("yoUSDT", yoUsdtImpl, EXPECTED_YOUSDT_IMPL);
            }
            if (yoUsdtImpl.code.length == 0) {
                yoUsdtImpl = address(new yoUSDT{ salt: SALT }());
                console2.log("yoUSDT impl deployed:", yoUsdtImpl);
            } else {
                console2.log("yoUSDT impl already deployed:", yoUsdtImpl);
            }
        }
    }
}
