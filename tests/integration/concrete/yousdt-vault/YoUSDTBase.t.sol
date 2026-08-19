// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAuthority } from "src/interfaces/IAuthority.sol";
import { IYoOracle } from "src/interfaces/IYoOracle.sol";
import { yoUSDT } from "src/yoUSDT.sol";
import { YoVault } from "src/YoVault.sol";
import { MockAuthority } from "./../../../mocks/MockAuthority.sol";
import { Integration_Test } from "./../../Integration.t.sol";

/// @notice Shared base for `yoUSDT` BTT tests. Deploys yoUSDT (which inherits YoVault) behind an
///         ERC-1967 proxy and mocks the NAV oracle at 1:1 against the yoUSD constant address.
// solhint-disable-next-line contract-name-capwords
abstract contract YoUSDTBaseTestBase_Test is Integration_Test {
    /// @dev Same constant as in `src/yoUSDT.sol`. Hardcoded relay destination and NAV reference.
    address internal constant YO_USD_ADDRESS = 0x0000000f2eB9f69274678c76222B35eEc7588a65;
    uint256 internal constant RELAY_PERCENTAGE = 95e16; // 95%
    uint256 internal constant DENOMINATOR = 1e18;

    yoUSDT internal vault;
    MockAuthority internal authority;

    function _setOraclePriceForYoUSD(uint256 price) internal {
        vm.mockCall(
            vault.ORACLE_ADDRESS(),
            abi.encodeWithSelector(IYoOracle.getLatestPrice.selector, YO_USD_ADDRESS),
            abi.encode(price, uint64(block.timestamp))
        );
    }

    function setUp() public virtual override {
        super.setUp();

        // Deploy yoUSDT (USDC stand-in as the asset for tests; yoUSDT in prod targets USDT but the
        // mechanics are asset-agnostic and our mock USDC has the same 6 decimals).
        yoUSDT impl = new yoUSDT();
        bytes memory initData =
            abi.encodeCall(YoVault.initialize, (IERC20(address(usdc)), users.owner, "Yo USDT Vault", "yoUSDT"));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = yoUSDT(payable(address(proxy)));
        vm.label(address(impl), "yoUSDTImpl");
        vm.label(address(vault), "yoUSDT");

        // Wire authority.
        authority = new MockAuthority();
        vm.prank(users.owner);
        vault.setAuthority(IAuthority(address(authority)));

        // Mock the NAV oracle at the yoUSD address at 1:1.
        _setOraclePriceForYoUSD(1e6);

        // Pre-fund alice for deposits.
        usdc.mint(users.alice, 1_000_000e6);
        vm.prank(users.alice);
        usdc.approve(address(vault), type(uint256).max);
    }
}
