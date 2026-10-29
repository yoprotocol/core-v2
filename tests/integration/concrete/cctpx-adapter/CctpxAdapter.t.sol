// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YoCctpxAdapter } from "src/adapters/cctpx/YoCctpxAdapter.sol";
import { ICrossChainTokenService } from "src/interfaces/external/ICrossChainTokenService.sol";
import { IYoBridgeRouteRegistry } from "src/interfaces/IYoBridgeRouteRegistry.sol";

import {
    MockCctpxFeeManager,
    MockCctpxTokenManager,
    MockCrossChainTokenService
} from "../../../mocks/MockCrossChainTokenService.sol";
import { MockERC20 } from "../../../mocks/MockERC20.sol";
import { Integration_Test } from "../../Integration.t.sol";

/// @notice Shared set-up for `YoCctpxAdapter` tests: a mock CCTPx service, fee manager, and EURC token
///         manager, one adapter pinned to a mock EURC, and an allowlisted EURC route for `users.vault`
///         to `recipient` on Ethereum (Circle domain 0). The vault holds EURC and ETH and approves the
///         adapter, as `vault.approveToken` would.
abstract contract CctpxAdapter_Integration_Test is Integration_Test {
    bytes32 internal constant TOKEN_ID = keccak256("EURC");
    /// @dev Ethereum. Domain 0 is a valid destination, so the adapter must not treat it as unset.
    uint32 internal constant DEST_DOMAIN = 0;
    /// @dev Base, a domain with no allowlisted route.
    uint32 internal constant OTHER_DOMAIN = 6;
    uint32 internal constant STANDARD_FINALITY = 2000;
    uint32 internal constant FAST_FINALITY = 1000;
    /// @dev The production cap (see `BaseScript.getCctpxMaxNativeFee`).
    uint256 internal constant MAX_NATIVE_FEE = 0.02 ether;
    /// @dev About a live standard-transfer quote.
    uint256 internal constant FEE = 0.0001 ether;
    uint256 internal constant VAULT_EURC = 1_000_000e6;
    uint256 internal constant VAULT_ETH = 10 ether;

    MockERC20 internal eurc;
    MockCctpxFeeManager internal mockFeeManager;
    MockCrossChainTokenService internal mockService;
    MockCctpxTokenManager internal mockTokenManager;
    YoCctpxAdapter internal cctpxAdapter;

    address internal recipient;
    uint256 internal amount;

    function setUp() public virtual override {
        Integration_Test.setUp();

        eurc = new MockERC20("EURC", "EURC", 6);
        mockFeeManager = new MockCctpxFeeManager();
        mockService = new MockCrossChainTokenService(mockFeeManager);
        mockTokenManager = mockService.register(TOKEN_ID, IERC20(address(eurc)));
        cctpxAdapter = new YoCctpxAdapter(
            ICrossChainTokenService(address(mockService)),
            IERC20(address(eurc)),
            TOKEN_ID,
            IYoBridgeRouteRegistry(address(routeRegistry)),
            MAX_NATIVE_FEE,
            yoRegistry
        );
        vm.label(address(eurc), "EURC");
        vm.label(address(mockFeeManager), "MockCctpxFeeManager");
        vm.label(address(mockService), "MockCrossChainTokenService");
        vm.label(address(mockTokenManager), "MockCctpxTokenManager");
        vm.label(address(cctpxAdapter), "YoCctpxAdapter");

        recipient = defaults.BRIDGE_RECIPIENT_ADDR();
        amount = defaults.BRIDGE_AMOUNT();
        _allowRoute(users.vault, address(cctpxAdapter), address(eurc), DEST_DOMAIN, _toBytes32(recipient));

        eurc.mint(users.vault, VAULT_EURC);
        vm.prank(users.vault);
        eurc.approve(address(cctpxAdapter), type(uint256).max);
        vm.deal(users.vault, VAULT_ETH);
    }

    /// @dev A test quote for `fee` (see {MockCrossChainTokenService}).
    function _quote(uint256 fee) internal pure returns (bytes memory) {
        return abi.encode(fee);
    }

    function _toBytes32(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }
}
