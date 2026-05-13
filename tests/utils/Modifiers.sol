// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { CommonBase } from "forge-std/src/Base.sol";

import { Users } from "./Types.sol";

/// @notice Shared modifiers used by Branching-Tree-Technique test files. Each modifier corresponds
///         to a branch of the `.tree` files; combining them in the test signature traces the path
///         through the tree.
abstract contract Modifiers is CommonBase {
    Users internal _users;

    function setUsersForModifiers(Users memory u) internal {
        _users = u;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                CALLER MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    modifier whenCallerOwner() {
        vm.startPrank(_users.owner);
        _;
        vm.stopPrank();
    }

    modifier whenCallerNotOwner() {
        vm.startPrank(_users.eve);
        _;
        vm.stopPrank();
    }

    modifier whenCallerVault() {
        vm.startPrank(_users.vault);
        _;
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                INPUT MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    modifier whenAmountNotZero() {
        _;
    }

    modifier whenVaultNotZero() {
        _;
    }

    modifier whenTokenNotZero() {
        _;
    }

    modifier whenSpenderNotZero() {
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                              REGISTRY MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    modifier whenMarketAllowed() {
        _;
    }

    modifier whenPairAllowed() {
        _;
    }

    modifier whenOracleQuoteAvailable() {
        _;
    }
}
