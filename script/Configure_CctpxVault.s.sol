// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.34 <0.9.0;

import { console2 } from "forge-std/src/console2.sol";

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { YoCctpxAdapter } from "../src/adapters/cctpx/YoCctpxAdapter.sol";
import { IYoApprovalRegistry } from "../src/interfaces/IYoApprovalRegistry.sol";
import { IYoBridgeRouteRegistry } from "../src/interfaces/IYoBridgeRouteRegistry.sol";
import { IYoRegistry } from "../src/interfaces/IYoRegistry.sol";
import { YoVault } from "../src/YoVault.sol";

import { BaseScript } from "./Base.s.sol";
import { ChainId } from "./ChainId.sol";
import { Deploy_CctpxAdapter } from "./Deploy_CctpxAdapter.s.sol";

/// @dev The solmate `RolesAuthority` surface that the batch uses.
interface IRolesAuthorityCctpx {
    function owner() external view returns (address);
    function doesRoleHaveCapability(uint8 role, address target, bytes4 functionSig) external view returns (bool);
    function setRoleCapability(uint8 role, address target, bytes4 functionSig, bool enabled) external;
}

interface IOwnableCctpx {
    function owner() external view returns (address);
}

/// @notice Writes the admin Safe batch that enables a vault (default yoEUR) on the chain's {YoCctpxAdapter},
///         as a Safe Transaction Builder JSON in `script/safe-batches/`. Nothing is broadcast: run with
///         `--rpc-url` only. The script executes the batch as the Safe on the fork, checks the result, and then
///         writes the file.
///
///         The adapter is the CREATE2 address that {Deploy_CctpxAdapter.predictAddress} gives, so the batch can
///         be built before the deploy. That address changes with the compiler settings (`FOUNDRY_PROFILE`;
///         use `optimized`, as `just deploy`) and with the exact source text (comments included) of every file
///         in the adapter's import closure (`bytecode_hash = "ipfs"`). Runbook: deploy from the merged commit with
///         `EXPECTED_ADAPTER` set to the adapter address in this batch, or build the batch after the deploy.
///
///         The vault, its `RolesAuthority`, its approval registry, and the route registry must have the same
///         owner: the Safe that executes the batch. The batch:
///           1. `approvalRegistry.setApproval(vault, eurc, adapter, approvalCap)`. As in the earlier bridge
///              rollouts, the operator (which holds `approveToken` on the vault) then approves the adapter for
///              each transfer with `vault.approveToken(eurc, adapter, amount)`.
///           2. `routeRegistry.setRoute(vault, adapter, eurc, destinationDomain, recipient, bytes32(0), true)`.
///           3. `authority.setRoleCapability(operatorRole, adapter, crossChainTransfer.selector, true)`.
///           4. A native transfer of `ethTopUp` from the Safe to the vault, which pays the CCTPx fees.
///         Steps 1-3 are left out when the chain already has their result, so the script can run again.
///
///         Before it builds the batch, the script forks the counterpart chain at its latest block and requires
///         `recipient` there to be a YO vault (`YoRegistry.isYoVault`; the registry has the same address on both
///         chains) whose ERC-4626 `asset()` is that chain's EURC. A wrong recipient would open a route to an
///         address that cannot receive the vault's funds.
///
///         Run:
///           YO_REGISTRY=0x... YO_BRIDGE_ROUTE_REGISTRY=0x... FOUNDRY_PROFILE=optimized \
///               forge script script/Configure_CctpxVault.s.sol --rpc-url base -vvv
///
///         Required env vars:
///           - YO_REGISTRY, YO_BRIDGE_ROUTE_REGISTRY: as for {Deploy_CctpxAdapter}; they set the adapter address.
///         Optional env vars:
///           - VAULT:              default yoEUR.
///           - CCTPX_RECIPIENT:    the vault on the other domain; default VAULT (yoEUR has one address on both).
///           - CCTPX_APPROVAL_CAP: largest `approveToken` amount for the adapter; default 877_000 EURC, the cap
///                                 of the other yoEUR bridge adapters.
///           - OPERATOR_ROLE:      default 12; at most 255.
///           - VAULT_ETH_TOP_UP:   wei the Safe sends to the vault; default 0.05 ether. 0 leaves the step out.
///           - BATCH_SLUG:         output file name `yo-<chain>-<slug>-safe.json`; default "yoeur-cctpx-enable".
///           - MAINNET_RPC_URL, BASE_RPC_URL: the counterpart chain's rpc; default its `foundry.toml` alias.
contract Configure_CctpxVault is BaseScript {
    error AdapterMismatch(string what);
    error CallFailed(uint256 index, address to, bytes returnData);
    error CounterpartChainMismatch(uint256 expected, uint256 actual);
    error InsufficientSafeBalance(uint256 balance, uint256 required);
    error InvalidOperatorRole(uint256 role);
    error NotConfigured(string what);
    error NotOwnedBySafe(string what, address owner, address safe);
    error RecipientAssetNotEurc(address recipient, address asset, address eurc);
    error RecipientNotVault(address recipient);
    error RecipientNotYoVault(address recipient);
    error VaultAssetNotEurc(address asset, address eurc);

    address internal constant YO_EUR = 0x50c749aE210D3977ADC824AE11F3c7fd10c871e9;
    /// @dev Circle domain ids. Not EVM chain ids.
    uint32 internal constant ETHEREUM_DOMAIN = 0;
    uint32 internal constant BASE_DOMAIN = 6;
    bytes4 internal constant MANAGE_BATCH_SELECTOR = bytes4(keccak256("manage(address[],bytes[],uint256[])"));

    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    struct Inputs {
        YoVault vault;
        address adapter;
        IYoBridgeRouteRegistry routeRegistry;
        IYoRegistry yoRegistry;
        uint32 destinationDomain;
        address recipient;
        uint256 approvalCap;
        uint8 operatorRole;
        uint256 ethTopUp;
    }

    function run() public {
        Inputs memory inputs = readInputs();
        checkRecipient(inputs, counterpartRpc());
        Call[] memory calls = build(inputs);
        address safe = inputs.vault.owner();
        if (inputs.adapter.code.length == 0) {
            console2.log("Adapter %s is not deployed yet; the batch targets its CREATE2 address.", inputs.adapter);
        }

        uint256 snapshot = vm.snapshotState();
        uint256 vaultEth = address(inputs.vault).balance;
        execute(safe, calls);
        verify(inputs);
        _require(address(inputs.vault).balance == vaultEth + inputs.ethTopUp, "vault ETH top-up");
        vm.revertToState(snapshot);

        string memory slug = vm.envOr({ name: "BATCH_SLUG", defaultValue: string("yoeur-cctpx-enable") });
        _writeBatch(
            string.concat("script/safe-batches/yo-", _chainName(), "-", slug, "-safe.json"),
            string.concat("Enable CCTPx EURC transfers for ", inputs.vault.symbol()),
            safe,
            calls
        );
    }

    /// @notice The inputs from the env vars. See the contract NatSpec.
    function readInputs() public returns (Inputs memory inputs) {
        inputs.vault = YoVault(payable(vm.envOr({ name: "VAULT", defaultValue: YO_EUR })));
        inputs.routeRegistry = IYoBridgeRouteRegistry(vm.envAddress("YO_BRIDGE_ROUTE_REGISTRY"));
        inputs.yoRegistry = IYoRegistry(getYoRegistry());
        inputs.adapter = new Deploy_CctpxAdapter().predictAddress(inputs.routeRegistry, inputs.yoRegistry);
        inputs.destinationDomain = counterpartDomain();
        inputs.recipient = vm.envOr({ name: "CCTPX_RECIPIENT", defaultValue: address(inputs.vault) });
        inputs.approvalCap = vm.envOr({ name: "CCTPX_APPROVAL_CAP", defaultValue: uint256(877_000e6) });
        uint256 operatorRole = vm.envOr({ name: "OPERATOR_ROLE", defaultValue: uint256(12) });
        if (operatorRole > type(uint8).max) {
            revert InvalidOperatorRole(operatorRole);
        }
        inputs.operatorRole = uint8(operatorRole);
        inputs.ethTopUp = vm.envOr({ name: "VAULT_ETH_TOP_UP", defaultValue: uint256(0.05 ether) });
    }

    /// @notice The Circle domain of the other chain of the yoEUR EURC route: Ethereum <-> Base.
    function counterpartDomain() public view returns (uint32) {
        if (chainId == ChainId.ETHEREUM) {
            return BASE_DOMAIN;
        }
        if (chainId == ChainId.BASE) {
            return ETHEREUM_DOMAIN;
        }
        revert ChainNotSupported("CCTPx counterpart domain", chainId);
    }

    /// @notice The rpc of the other chain of the yoEUR EURC route: `BASE_RPC_URL` or `MAINNET_RPC_URL`, else its
    ///         `foundry.toml` alias.
    function counterpartRpc() public view returns (string memory) {
        if (chainId == ChainId.ETHEREUM) {
            return vm.envOr({ name: "BASE_RPC_URL", defaultValue: string("base") });
        }
        if (chainId == ChainId.BASE) {
            return vm.envOr({ name: "MAINNET_RPC_URL", defaultValue: string("mainnet") });
        }
        revert ChainNotSupported("CCTPx counterpart rpc", chainId);
    }

    /// @notice Revert unless `inputs.recipient` is, on the counterpart chain, a YO vault in `inputs.yoRegistry`
    ///         whose ERC-4626 `asset()` is that chain's EURC. Reads it on a new fork of `rpc` (at its latest
    ///         block), then selects the source fork again.
    function checkRecipient(Inputs memory inputs, string memory rpc) public {
        uint256 sourceFork = vm.activeFork();
        uint256 expectedChain = chainId == ChainId.ETHEREUM ? ChainId.BASE : ChainId.ETHEREUM;
        vm.createSelectFork(rpc);
        if (block.chainid != expectedChain) {
            revert CounterpartChainMismatch(expectedChain, block.chainid);
        }

        address recipient = inputs.recipient;
        if (recipient.code.length == 0) {
            revert RecipientNotVault(recipient);
        }
        address eurc = getEURCOn(block.chainid);
        address asset = IERC4626(recipient).asset();
        if (asset != eurc) {
            revert RecipientAssetNotEurc(recipient, asset, eurc);
        }
        if (!inputs.yoRegistry.isYoVault(recipient)) {
            revert RecipientNotYoVault(recipient);
        }
        vm.selectFork(sourceFork);
    }

    /// @notice The batch calls, in order, after the preflight checks. Changes no state.
    function build(Inputs memory inputs) public view returns (Call[] memory calls) {
        address safe = _preflight(inputs);
        if (safe.balance < inputs.ethTopUp) {
            revert InsufficientSafeBalance(safe.balance, inputs.ethTopUp);
        }

        Call[] memory buffer = new Call[](4);
        uint256 n;
        address vault = address(inputs.vault);
        address eurc = inputs.vault.asset();

        IYoApprovalRegistry approvalRegistry = inputs.vault.approvalRegistry();
        if (approvalRegistry.maxApproval(vault, eurc, inputs.adapter) != inputs.approvalCap) {
            buffer[n++] = Call(
                address(approvalRegistry),
                0,
                abi.encodeCall(IYoApprovalRegistry.setApproval, (vault, eurc, inputs.adapter, inputs.approvalCap))
            );
        }

        if (!_isRouteAllowed(inputs)) {
            buffer[n++] = Call(
                address(inputs.routeRegistry),
                0,
                abi.encodeCall(
                    IYoBridgeRouteRegistry.setRoute,
                    (
                        vault,
                        inputs.adapter,
                        eurc,
                        inputs.destinationDomain,
                        bytes32(uint256(uint160(inputs.recipient))),
                        bytes32(0),
                        true
                    )
                )
            );
        }

        IRolesAuthorityCctpx authority = IRolesAuthorityCctpx(address(inputs.vault.authority()));
        bytes4 selector = YoCctpxAdapter.crossChainTransfer.selector;
        if (!authority.doesRoleHaveCapability(inputs.operatorRole, inputs.adapter, selector)) {
            buffer[n++] = Call(
                address(authority),
                0,
                abi.encodeCall(
                    IRolesAuthorityCctpx.setRoleCapability, (inputs.operatorRole, inputs.adapter, selector, true)
                )
            );
        }

        if (inputs.ethTopUp != 0) {
            buffer[n++] = Call(vault, inputs.ethTopUp, "");
        }

        calls = new Call[](n);
        for (uint256 i = 0; i < n; ++i) {
            calls[i] = buffer[i];
        }
    }

    /// @notice Execute `calls` as `safe`, as the Safe's MultiSend does.
    function execute(address safe, Call[] memory calls) public {
        for (uint256 i = 0; i < calls.length; ++i) {
            vm.prank(safe);
            (bool ok, bytes memory returnData) = calls[i].to.call{ value: calls[i].value }(calls[i].data);
            if (!ok) {
                revert CallFailed(i, calls[i].to, returnData);
            }
        }
    }

    /// @notice Revert unless the chain has the state that the batch sets, and the operator role can run a
    ///         transfer: approve the adapter, call `manage`, and call `crossChainTransfer` through it.
    function verify(Inputs memory inputs) public view {
        address vault = address(inputs.vault);
        IRolesAuthorityCctpx authority = IRolesAuthorityCctpx(address(inputs.vault.authority()));
        _require(
            inputs.vault.approvalRegistry().maxApproval(vault, inputs.vault.asset(), inputs.adapter)
                == inputs.approvalCap,
            "approval cap"
        );
        _require(_isRouteAllowed(inputs), "route");
        _require(
            authority.doesRoleHaveCapability(
                inputs.operatorRole, inputs.adapter, YoCctpxAdapter.crossChainTransfer.selector
            ),
            "operator crossChainTransfer capability"
        );
        _require(
            authority.doesRoleHaveCapability(inputs.operatorRole, vault, YoVault.approveToken.selector),
            "operator approveToken capability"
        );
        _require(
            authority.doesRoleHaveCapability(inputs.operatorRole, vault, MANAGE_BATCH_SELECTOR),
            "operator manage capability"
        );
    }

    function _isRouteAllowed(Inputs memory inputs) internal view returns (bool) {
        return inputs.routeRegistry
            .isRouteAllowed(
                address(inputs.vault),
                inputs.adapter,
                inputs.vault.asset(),
                inputs.destinationDomain,
                bytes32(uint256(uint160(inputs.recipient))),
                bytes32(0)
            );
    }

    function _preflight(Inputs memory inputs) internal view returns (address safe) {
        address eurc = getEURC();
        if (inputs.vault.asset() != eurc) {
            revert VaultAssetNotEurc(inputs.vault.asset(), eurc);
        }
        // Before the deploy the adapter has no code; after it, the batch must target the same adapter.
        if (inputs.adapter.code.length != 0) {
            YoCctpxAdapter adapter = YoCctpxAdapter(inputs.adapter);
            if (address(adapter.token()) != eurc) {
                revert AdapterMismatch("token");
            }
            if (address(adapter.routeRegistry()) != address(inputs.routeRegistry)) {
                revert AdapterMismatch("route registry");
            }
        }

        safe = inputs.vault.owner();
        _requireOwner("authority", IRolesAuthorityCctpx(address(inputs.vault.authority())).owner(), safe);
        _requireOwner("approval registry", IOwnableCctpx(address(inputs.vault.approvalRegistry())).owner(), safe);
        _requireOwner("route registry", IOwnableCctpx(address(inputs.routeRegistry)).owner(), safe);
    }

    function _requireOwner(string memory what, address owner, address safe) internal pure {
        if (owner != safe) {
            revert NotOwnedBySafe(what, owner, safe);
        }
    }

    function _require(bool condition, string memory what) internal pure {
        if (!condition) {
            revert NotConfigured(what);
        }
    }

    function _chainName() internal view returns (string memory) {
        if (chainId == ChainId.ETHEREUM) {
            return "ethereum";
        }
        if (chainId == ChainId.BASE) {
            return "base";
        }
        revert ChainNotSupported("CCTPx Safe batch", chainId);
    }

    /// @dev Safe Transaction Builder format, as {MidnightSafeBatch} writes it, with each call's native value.
    ///      Single-quoted literals keep the JSON double quotes unescaped.
    function _writeBatch(string memory path, string memory name, address safe, Call[] memory calls) internal {
        // solhint-disable quotes
        string memory transactions;
        for (uint256 i = 0; i < calls.length; ++i) {
            transactions = string.concat(
                transactions,
                i == 0 ? "" : ",",
                '{"to":"',
                vm.toString(calls[i].to),
                '","value":"',
                vm.toString(calls[i].value),
                '","data":"',
                vm.toString(calls[i].data),
                '","contractMethod":null,"contractInputsValues":null}'
            );
        }
        string memory json = string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(chainId),
            '","createdAt":',
            vm.toString(block.timestamp * 1000),
            ',"meta":{"name":"',
            name,
            '","description":"',
            name,
            '","txBuilderVersion":"1.18.0","createdFromSafeAddress":"',
            vm.toString(safe),
            '","createdFromOwnerAddress":""},"transactions":[',
            transactions,
            "]}"
        );
        // solhint-enable quotes
        vm.createDir("script/safe-batches", true);
        vm.writeFile(path, json);
        console2.log("Wrote %s (%s transactions)", path, calls.length);
    }
}
