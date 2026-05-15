// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IYoOracle } from "src/interfaces/IYoOracle.sol";

import { YoOracleBase_Test } from "../YoOracleBase.t.sol";

contract SetAssetConfigIntegrationConcreteTest is YoOracleBase_Test {
    function test_WhenOwner_StoresConfig() external {
        uint32 windowSec = 12 hours;
        uint32 maxChangeBps = 500_000;

        vm.expectEmit(true, true, true, true, address(oracle));
        emit IYoOracle.AssetConfigUpdated(users.vault, windowSec, maxChangeBps);

        vm.prank(users.owner);
        oracle.setAssetConfig(users.vault, windowSec, maxChangeBps);

        (
            uint256 latestPrice,
            uint256 anchorPrice,
            uint64 anchorTs,
            uint64 latestTs,
            uint64 storedWindow,
            uint64 storedMaxChange
        ) = oracle.oracleData(users.vault);

        assertEq(latestPrice, 0);
        assertEq(anchorPrice, 0);
        assertEq(anchorTs, 0);
        assertEq(latestTs, 0);
        assertEq(storedWindow, uint64(windowSec));
        assertEq(storedMaxChange, uint64(maxChangeBps));
    }

    function test_RevertWhen_CallerNotOwner() external {
        vm.prank(users.eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, users.eve));
        oracle.setAssetConfig(users.vault, 1 hours, 500_000);
    }
}
