// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { YoAdapterBase } from "src/adapters/base/YoAdapterBase.sol";
import { YoCctpxAdapter } from "src/adapters/cctpx/YoCctpxAdapter.sol";
import { ICrossChainTokenService } from "src/interfaces/external/ICrossChainTokenService.sol";
import { IYoBridgeRouteRegistry } from "src/interfaces/IYoBridgeRouteRegistry.sol";
import { IYoCctpxAdapter } from "src/interfaces/IYoCctpxAdapter.sol";
import { IYoRegistry } from "src/interfaces/IYoRegistry.sol";

import { MockCrossChainTokenService } from "../../../../mocks/MockCrossChainTokenService.sol";
import { CctpxAdapter_Integration_Test } from "../CctpxAdapter.t.sol";

contract Constructor_CctpxAdapter_Integration_Concrete_Test is CctpxAdapter_Integration_Test {
    function test_WhenYoRegistryZero() external {
        vm.expectRevert(YoAdapterBase.ZeroRegistry.selector);
        _deploy(IERC20(address(eurc)), TOKEN_ID, IYoRegistry(address(0)));
    }

    modifier whenYoRegistryNonZero() {
        _;
    }

    function test_WhenTokenIdNotRegistered() external whenYoRegistryNonZero {
        bytes32 unknownId = keccak256("UNKNOWN");
        vm.expectRevert(abi.encodeWithSelector(MockCrossChainTokenService.TokenNotRegistered.selector, unknownId));
        _deploy(IERC20(address(eurc)), unknownId, yoRegistry);
    }

    function test_WhenTokenIsNotTheRegisteredToken() external whenYoRegistryNonZero {
        // USDC under the EURC token id: the token manager would pull a token the vault never approved.
        vm.expectRevert(abi.encodeWithSelector(IYoCctpxAdapter.TokenMismatch.selector, address(usdc), address(eurc)));
        _deploy(IERC20(address(usdc)), TOKEN_ID, yoRegistry);
    }

    function test_WhenTokenIsTheRegisteredToken() external whenYoRegistryNonZero {
        YoCctpxAdapter adapter = _deploy(IERC20(address(eurc)), TOKEN_ID, yoRegistry);

        // it should set the immutables
        assertEq(address(adapter.service()), address(mockService), "service");
        assertEq(address(adapter.token()), address(eurc), "token");
        assertEq(adapter.tokenId(), TOKEN_ID, "tokenId");
        assertEq(address(adapter.routeRegistry()), address(routeRegistry), "routeRegistry");
        assertEq(adapter.maxNativeFee(), MAX_NATIVE_FEE, "maxNativeFee");
        assertEq(address(adapter.yoRegistry()), address(yoRegistry), "yoRegistry");
    }

    function _deploy(IERC20 token, bytes32 tokenId, IYoRegistry registry) private returns (YoCctpxAdapter) {
        return new YoCctpxAdapter(
            ICrossChainTokenService(address(mockService)),
            token,
            tokenId,
            IYoBridgeRouteRegistry(address(routeRegistry)),
            MAX_NATIVE_FEE,
            registry
        );
    }
}
