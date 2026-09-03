// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/src/Test.sol";
import { IAuthority } from "src/interfaces/IAuthority.sol";
import { IYoOracle } from "src/interfaces/IYoOracle.sol";
import { YoApprovalRegistry } from "src/registries/YoApprovalRegistry.sol";
import { YoERC4626VaultRegistry } from "src/registries/YoERC4626VaultRegistry.sol";
import { YoMorphoMarketRegistry } from "src/registries/YoMorphoMarketRegistry.sol";
import { YoSwapPairRegistry } from "src/registries/YoSwapPairRegistry.sol";
import { YoRegistry } from "src/YoRegistry.sol";
import { YoVault } from "src/YoVault.sol";
import { MockAuthority } from "./../../mocks/MockAuthority.sol";

/// @notice Shared base for fork-based e2e tests. Each child test forks a specific network
///         (Base / Ethereum mainnet) at a pinned block, then deploys a fresh YoVault + registry
///         stack with `users.owner` as the multisig and `users.operator` as the hot key.
///
///         Skips itself gracefully when the relevant RPC env var is unset, so CI without an
///         API_KEY_ALCHEMY won't break.
// solhint-disable-next-line contract-name-capwords
abstract contract Fork_Test is Test {
    /// @dev Selector for the overloaded `manage(address,bytes,uint256)`.
    bytes4 internal constant MANAGE_SINGLE_SELECTOR = bytes4(keccak256("manage(address,bytes,uint256)"));

    /*//////////////////////////////////////////////////////////////////////////
                                       USERS
    //////////////////////////////////////////////////////////////////////////*/

    struct ForkUsers {
        address payable owner;
        address payable operator;
        address payable alice;
    }

    ForkUsers internal users;

    /*//////////////////////////////////////////////////////////////////////////
                                  CORE PROTOCOL
    //////////////////////////////////////////////////////////////////////////*/

    YoVault internal yoVault;
    MockAuthority internal authority;
    YoApprovalRegistry internal approvalRegistry;
    YoMorphoMarketRegistry internal marketRegistry;
    YoSwapPairRegistry internal pairRegistry;
    YoERC4626VaultRegistry internal yieldVaultRegistry;
    YoRegistry internal yoRegistry;

    /// @dev The YoVault NAV oracle address is a hardcoded constant. We mock it at 1:1 so vault NAV
    ///      math doesn't depend on the legacy off-chain price-publisher being live on the fork.
    function _mockNavOracleAt1To1() internal {
        vm.mockCall(
            yoVault.ORACLE_ADDRESS(),
            abi.encodeWithSelector(IYoOracle.getLatestPrice.selector, address(yoVault)),
            abi.encode(uint256(1e6), uint64(block.timestamp))
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   FORK HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Returns true and creates the fork; returns false (and the caller should skip) if no
    ///      RPC URL is set in `<NAME>_RPC_URL` env var. `blockNumber == 0` forks the latest
    ///      block — the right choice when running against a public RPC that doesn't keep old
    ///      historical state.
    function _forkIfAvailable(string memory envName, uint256 blockNumber) internal returns (bool ok) {
        string memory rpc = vm.envOr(envName, string(""));
        if (bytes(rpc).length == 0) {
            return false;
        }
        if (blockNumber == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, blockNumber);
        }
        return true;
    }

    function _maybeSkip(bool forked, string memory envName) internal {
        if (!forked) {
            string memory reason = string.concat(envName, " not set; skipping fork test");
            vm.skip(true, reason);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                STACK DEPLOYMENT
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Deploys the full YoVault + registry stack on the active fork with `asset` as the
    ///      vault's ERC-4626 asset. Grants `users.operator` the standard hot-key selector set.
    function _deployStack(IERC20 asset, string memory name, string memory symbol) internal {
        users.owner = payable(makeAddr("Owner"));
        users.operator = payable(makeAddr("Operator"));
        users.alice = payable(makeAddr("Alice"));

        // Registries.
        vm.startPrank(users.owner);
        approvalRegistry = new YoApprovalRegistry(users.owner);
        marketRegistry = new YoMorphoMarketRegistry(users.owner);
        pairRegistry = new YoSwapPairRegistry(users.owner);
        yieldVaultRegistry = new YoERC4626VaultRegistry(users.owner);
        vm.stopPrank();

        // YoRegistry behind its own ERC-1967 proxy — adapters need this for `rescue` auth.
        YoRegistry yoRegistryImpl = new YoRegistry();
        bytes memory yoRegistryInit = abi.encodeCall(YoRegistry.initialize, (users.owner, IAuthority(address(0))));
        yoRegistry = YoRegistry(payable(address(new ERC1967Proxy(address(yoRegistryImpl), yoRegistryInit))));

        // YoVault behind ERC-1967 proxy.
        YoVault impl = new YoVault();
        bytes memory initData = abi.encodeCall(YoVault.initialize, (asset, users.owner, name, symbol));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        yoVault = YoVault(payable(address(proxy)));

        // Register the vault so it counts as a valid YO vault for adapter rescue.
        vm.prank(users.owner);
        yoRegistry.addYoVault(address(yoVault));

        // Authority + operator selector grants.
        authority = new MockAuthority();
        vm.prank(users.owner);
        yoVault.setAuthority(IAuthority(address(authority)));
        authority.setAllowed(users.operator, address(yoVault), MANAGE_SINGLE_SELECTOR, true);
        authority.setAllowed(users.operator, address(yoVault), YoVault.approveToken.selector, true);

        // Bind approval registry.
        vm.prank(users.owner);
        yoVault.setApprovalRegistry(approvalRegistry);

        // NAV oracle: mock at parity so totalAssets() / share math work without the publisher.
        _mockNavOracleAt1To1();

        vm.label(address(yoVault), "YoVault");
        vm.label(address(authority), "MockAuthority");
        vm.label(address(approvalRegistry), "YoApprovalRegistry");
        vm.label(address(marketRegistry), "YoMorphoMarketRegistry");
        vm.label(address(pairRegistry), "YoSwapPairRegistry");
        vm.label(address(yieldVaultRegistry), "YoERC4626VaultRegistry");
        vm.label(address(yoRegistry), "YoRegistry");
    }

    /// @dev Approve `spender` to spend up to `cap` of `token` on behalf of the vault, via the
    ///      operator path. Exercises the full ApprovalRegistry + approveToken flow.
    function _vaultApprove(IERC20 token, address spender, uint256 cap) internal {
        vm.prank(users.owner);
        approvalRegistry.setApproval(address(yoVault), address(token), spender, cap);

        vm.prank(users.operator);
        yoVault.approveToken(address(token), spender, cap);
    }

    /// @dev Operator-side: have the vault forward `data` to `target` via `manage()`.
    function _opManage(address target, bytes memory data) internal returns (bytes memory ret) {
        // Authorize the target+selector at the inner check too.
        authority.setAllowed(users.operator, target, bytes4(data), true);

        vm.prank(users.operator);
        ret = yoVault.manage(target, data, 0);
    }
}
