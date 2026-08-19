// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { IAuthority } from "../src/interfaces/IAuthority.sol";
import { IMorpho } from "../src/interfaces/IMorpho.sol";
import { YoVault } from "../src/YoVault.sol";

import { BaseScript } from "./Base.s.sol";
import { ChainId } from "./ChainId.sol";

/// @notice Minimal throwaway authority used to route a single `YoVault.manage` call past the
///         per-target `authority().canCall(msg.sender, target, sig)` check without touching the
///         shared production `RolesAuthority`. Capabilities are an explicit
///         `(user, target, sig) → bool` allowlist that only the deployer can edit, so binding this
///         authority to a vault grants nothing to anyone else.
contract TempAuthority is IAuthority {
    error NotDeployer();

    address public immutable DEPLOYER;

    mapping(address user => mapping(address target => mapping(bytes4 sig => bool allowed))) internal _capabilities;

    constructor(address deployer) {
        DEPLOYER = deployer;
    }

    /// @notice Allow or revoke `user` calling `sig` on `target` through a vault bound to this authority.
    function setCapability(address user, address target, bytes4 sig, bool allowed) external {
        require(msg.sender == DEPLOYER, NotDeployer());
        _capabilities[user][target][sig] = allowed;
    }

    /// @inheritdoc IAuthority
    function canCall(address user, address target, bytes4 sig) external view returns (bool) {
        return _capabilities[user][target][sig];
    }
}

/// @notice Authorizes the Yo Morpho adapter on Morpho Blue for a test vault whose owner is the
///         broadcaster, without any multisig involvement. `YoVault.manage` requires
///         `authority().canCall(msg.sender, target, sig)` with NO owner bypass, so the shared
///         `RolesAuthority` (Safe-owned) would normally have to whitelist the call. Instead the
///         vault owner temporarily swaps the authority (owner-callable on `AuthUpgradeable`):
///
///           1. Deploy {TempAuthority} (deployer-gated allowlist).
///           2. `vault.setAuthority(temp)`.
///           3. `temp.setCapability(broadcaster, morpho, setAuthorization.selector, true)`.
///           4. `vault.manage(morpho, setAuthorization(adapter, true), 0)`.
///           5. `temp.setCapability(broadcaster, morpho, setAuthorization.selector, false)`.
///           6. `vault.setAuthority(SHARED_AUTHORITY)` — back to the production RolesAuthority.
///
///         All six steps run in one broadcast from the vault owner. Idempotent: when Morpho
///         already authorizes the adapter the swap is skipped entirely, and the script always
///         leaves the vault bound to {SHARED_AUTHORITY}.
///
///         Supported chains: Ethereum, Base, Arbitrum, HyperEVM.
///
///         Optional env vars:
///           - VAULT:              vault proxy to configure. Defaults to the yoTest vault.
///           - ETH_FROM, MNEMONIC: broadcaster key (see {BaseScript}); must be the vault owner.
contract Authorize_MorphoAdapter is BaseScript {
    error BroadcasterNotVaultOwner(address owner, address broadcaster);
    error AuthorityNotRestored(address current);
    error AdapterNotAuthorized(address vault, address adapter);

    /// @dev The production RolesAuthority shared by all Yo vaults (same address on every chain).
    address internal constant SHARED_AUTHORITY = 0x9524e25079b1b04D904865704783A5aA0202d44D;

    /// @dev The yoTest vault proxy (same address on every chain, cross-chain deterministic deploy).
    address internal constant DEFAULT_VAULT = 0xcF0fE5AB46cf260EB281650E8f999237684846AA;

    /// @dev Yo Morpho adapters per chain (see {Seed_PoolRegistry}): CREATE2-deterministic on
    ///      Ethereum and Base; HyperEVM and Arbitrum diverged (Morpho Blue constructor arg differs).
    address internal constant MORPHO_ADAPTER = 0x93A3A3325dE6aB429523D144b41A032e7D7456Ab;
    address internal constant MORPHO_ADAPTER_ARBITRUM = 0x94Ba489EAc7dBF9Ca295aeaB5Df8c8bCF4972BF2;
    address internal constant MORPHO_ADAPTER_HYPEREVM = 0x946FD049C47BeFF53a32588C67df6a5A16B805F0;

    function run() public broadcast {
        YoVault vault = YoVault(payable(vm.envOr({ name: "VAULT", defaultValue: DEFAULT_VAULT })));
        address morpho = getMorphoBlue();
        address adapter = _morphoAdapter();

        if (vault.owner() != broadcaster) {
            revert BroadcasterNotVaultOwner(vault.owner(), broadcaster);
        }

        if (IMorphoAuthorization(morpho).isAuthorized(address(vault), adapter)) {
            console2.log("Adapter %s already authorized on Morpho %s - skipping", adapter, morpho);
        } else {
            TempAuthority temp = new TempAuthority(broadcaster);
            vault.setAuthority(IAuthority(address(temp)));
            temp.setCapability(broadcaster, morpho, IMorpho.setAuthorization.selector, true);
            vault.manage(morpho, abi.encodeCall(IMorpho.setAuthorization, (adapter, true)), 0);
            temp.setCapability(broadcaster, morpho, IMorpho.setAuthorization.selector, false);
            console2.log("Authorized adapter %s for vault %s on Morpho %s", adapter, address(vault), morpho);
        }

        if (address(vault.authority()) != SHARED_AUTHORITY) {
            vault.setAuthority(IAuthority(SHARED_AUTHORITY));
            console2.log("Authority restored to shared RolesAuthority", SHARED_AUTHORITY);
        }

        // Post-conditions: adapter authorized, production authority bound.
        if (!IMorphoAuthorization(morpho).isAuthorized(address(vault), adapter)) {
            revert AdapterNotAuthorized(address(vault), adapter);
        } else {
            console2.log("Adapter %s authorized on Morpho %s for vault %s", adapter, morpho, address(vault));
        }
        if (address(vault.authority()) != SHARED_AUTHORITY) {
            revert AuthorityNotRestored(address(vault.authority()));
        }
    }

    /// @dev Chains with a deployed Yo Morpho adapter; reverts elsewhere so the script cannot
    ///      record an authorization against a chain without one.
    function _morphoAdapter() internal view returns (address) {
        if (chainId == ChainId.ETHEREUM || chainId == ChainId.BASE) {
            return MORPHO_ADAPTER;
        }
        if (chainId == ChainId.ARBITRUM) {
            return MORPHO_ADAPTER_ARBITRUM;
        }
        if (chainId == ChainId.HYPEREVM) {
            return MORPHO_ADAPTER_HYPEREVM;
        }
        revert ChainNotSupported("Morpho adapter", chainId);
    }
}

/// @notice Subset of Morpho Blue not covered by {IMorpho}: the authorization mapping getter used
///         for the idempotency check.
interface IMorphoAuthorization {
    function isAuthorized(address authorizer, address authorized) external view returns (bool);
}
