// SPDX-License-Identifier: MIT
pragma solidity >=0.8.34 <0.9.0;

import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { Script } from "forge-std/src/Script.sol";

import { ChainId } from "./ChainId.sol";

abstract contract BaseScript is Script {
    error ChainNotSupported(string what, uint256 chainId);
    error EnvVarRequired(string name);
    error SaltTooLong(uint256 length);

    /// @dev Included to enable compilation of the script without a $MNEMONIC environment variable.
    string internal constant TEST_MNEMONIC = "test test test test test test test test test test test junk";

    /// @dev Zero-salt CREATE2 default for legacy scripts (`Deploy.s.sol`, `DeployYoUSDT.s.sol`,
    ///      `DeployTimelock.s.sol`) that read `SALT` from env. New scripts should use the
    ///      versioned `SALT` immutable below.
    bytes32 internal constant ZERO_SALT = bytes32(0);

    /// @dev The current YO V3 release version. Bump this on every adapter / registry bytecode
    ///      change so CREATE2 yields a fresh address (avoids accidental same-address re-deploys).
    string internal constant YO_VERSION = "V3.0.0";

    /// @dev Versioned CREATE2 salt: `"Version <ver>"`. Chain-independent, so a contract with
    ///      identical initcode (same bytecode + same constructor args) lands at the same address on
    ///      every chain via the canonical CREATE2 factory; a version bump yields a fresh address.
    ///      Note: contracts whose constructor args differ per chain (e.g. adapters bound to a
    ///      chain-specific `YoRegistry` or Curve router) still get distinct addresses.
    bytes32 internal immutable SALT;

    address internal broadcaster;
    uint256 internal chainId;
    string internal mnemonic;

    /// @dev Initializes the transaction broadcaster like this:
    ///
    /// - If $ETH_FROM is defined, use it.
    /// - Otherwise, derive the broadcaster address from $MNEMONIC.
    /// - If $MNEMONIC is not defined, default to a test mnemonic.
    ///
    /// The use case for $ETH_FROM is to specify the broadcaster key and its address via the command line.
    constructor() {
        chainId = block.chainid;

        address from = vm.envOr({ name: "ETH_FROM", defaultValue: address(0) });
        if (from != address(0)) {
            broadcaster = from;
        } else {
            mnemonic = vm.envOr({ name: "MNEMONIC", defaultValue: TEST_MNEMONIC });
            (broadcaster,) = deriveRememberKey({ mnemonic: mnemonic, index: 0 });
        }

        SALT = _constructCreate2Salt();
    }

    modifier broadcast() {
        vm.startBroadcast(broadcaster);
        _;
        vm.stopBroadcast();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  SALT CONSTRUCTION
    //////////////////////////////////////////////////////////////////////////*/

    function _constructCreate2Salt() internal view virtual returns (bytes32) {
        string memory create2Salt = string.concat("Version ", YO_VERSION);
        uint256 len = bytes(create2Salt).length;
        if (len > 32) {
            revert SaltTooLong(len);
        }
        return bytes32(abi.encodePacked(create2Salt));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   PROXY HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Read a transparent proxy's admin (ProxyAdmin contract) directly from the ERC-1967
    ///      admin slot. Used by upgrade scripts to resolve who must sign `upgradeAndCall`.
    function _readProxyAdmin(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.ADMIN_SLOT))));
    }

    /*//////////////////////////////////////////////////////////////////////////
                              CHAIN-AWARE ADDRESS GETTERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Default YO multisig per chain. Owns the new registries + swap oracle on first
    ///         deploy. Ownership transfer to the timelock is a follow-up operational step.
    /// @dev Overridable via the `YO_OWNER` env var.
    function getYoOwner() public view returns (address) {
        address envOverride = vm.envOr({ name: "YO_OWNER", defaultValue: address(0) });
        if (envOverride != address(0)) {
            return envOverride;
        }
        revert ChainNotSupported("YO_OWNER", chainId);
    }

    /// @notice Existing YoRegistry proxy address per chain. The V3 adapters consume this for the
    ///         `rescue` auth check; it is NOT redeployed during the V3 rollout.
    /// @dev Required via the `YO_REGISTRY` env var on first use; chain-pinned addresses can be
    ///      added here once each chain is in production.
    function getYoRegistry() public view returns (address) {
        address envOverride = vm.envOr({ name: "YO_REGISTRY", defaultValue: address(0) });
        if (envOverride == address(0)) {
            revert EnvVarRequired("YO_REGISTRY");
        }
        return envOverride;
    }

    /// @notice Morpho Blue per chain. Same canonical address on every supported chain.
    function getMorphoBlue() public view returns (address) {
        if (chainId == ChainId.BASE || chainId == ChainId.ETHEREUM) {
            return 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
        }

        if (chainId == ChainId.HYPEREVM) {
            return 0x68e37dE8d93d3496ae143F2E900490f6280C57cD;
        }
        revert ChainNotSupported("Morpho Blue", chainId);
    }

    /// @notice Curve Router-NG (latest) per chain. Unlike 1inch, the router is NOT deployed at the
    ///         same address on every chain, so each supported chain is pinned explicitly.
    /// @dev Source: https://github.com/curvefi/curve-router-ng (README deployment table).
    function getCurveRouter() public view returns (address) {
        if (chainId == ChainId.ETHEREUM) {
            return 0x45312ea0eFf7E09C83CBE249fa1d7598c4C8cd4e;
        }
        if (chainId == ChainId.BASE) {
            return 0x4f37A9d177470499A2dD084621020b023fcffc1F;
        }
        if (chainId == ChainId.ARBITRUM) {
            return 0x2191718CD32d02B8E60BAdFFeA33E4B5DD9A0A0D;
        }
        if (chainId == ChainId.OPTIMISM) {
            return 0x0DCDED3545D565bA3B19E683431381007245d983;
        }
        if (chainId == ChainId.XLAYER) {
            return 0xBFab8ebc836E1c4D81837798FC076D219C9a1855;
        }

        return address(0);
    }

    /// @notice Enso Router V2. Deployed at the same address on every chain it supports via a
    ///         deterministic CREATE2 deployment (verified on Ethereum, Base, Arbitrum).
    /// @dev Source: https://docs.enso.build/pages/build/reference/deployments. Confirm Enso is live
    ///      on the target chain before deploying — {Deploy_EnsoSwapAdapter} asserts the address has
    ///      code so a deploy on an unsupported chain reverts rather than binding a codeless router.
    function getEnsoRouter() public pure returns (address) {
        return 0xF75584eF6673aD213a685a1B58Cc0330B8eA22Cf;
    }

    /// @notice WETH address per chain.
    function getWETH() public view returns (address) {
        if (chainId == ChainId.BASE) {
            return 0x4200000000000000000000000000000000000006;
        }
        if (chainId == ChainId.ETHEREUM) {
            return 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        }
        revert ChainNotSupported("WETH", chainId);
    }

    /// @notice Lido stETH. Mainnet-only by design; the YoLidoAdapter is not deployed on L2s.
    function getLidoStETH() public view returns (address) {
        if (chainId != ChainId.ETHEREUM) {
            revert ChainNotSupported("Lido stETH", chainId);
        }
        return 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    }

    /// @notice Lido WithdrawalQueueERC721. Mainnet-only.
    function getLidoQueue() public view returns (address) {
        if (chainId != ChainId.ETHEREUM) {
            revert ChainNotSupported("Lido queue", chainId);
        }
        return 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;
    }

    /// @notice Whether the current chain supports the Lido adapter.
    function isLidoSupportedChain() public view returns (bool) {
        return chainId == ChainId.ETHEREUM;
    }

    /// @notice Maximum slippage in basis points for the swap adapter's oracle-checked path.
    function getMaxSlippageBps() public pure returns (uint256) {
        return 25; // 0.25%
    }
}
