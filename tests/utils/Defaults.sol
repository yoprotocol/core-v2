// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Id } from "src/interfaces/IMorpho.sol";

import { Users } from "./Types.sol";

/// @notice Centralized test defaults. Mirrors Sablier's `Defaults` pattern.
contract Defaults {
    // ---------------------- AMOUNTS ----------------------
    uint256 public constant USDC_AMOUNT = 100_000e6;
    uint256 public constant TOKEN_AMOUNT_18 = 100_000e18;
    uint256 public constant SUPPLY_AMOUNT = 10_000e6;
    uint256 public constant APPROVAL_CAP = 1_000_000e6;

    // ---------------------- SWAP ----------------------
    uint256 public constant SWAP_AMOUNT_IN = 1000e6;
    uint256 public constant SWAP_EXPECTED_OUT = 1000e6;
    uint256 public constant ORACLE_QUOTE_1_TO_1 = 1e18;
    uint256 public constant MAX_SLIPPAGE_BPS = 50;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ---------------------- MARKETS ----------------------
    function MARKET_A() public pure returns (Id) {
        return Id.wrap(keccak256("MARKET_A"));
    }

    function MARKET_B() public pure returns (Id) {
        return Id.wrap(keccak256("MARKET_B"));
    }

    function MARKET_NULL() public pure returns (Id) {
        return Id.wrap(bytes32(0));
    }

    // ---------------------- TIME ----------------------
    uint256 public constant FEB_1_2025 = 1_738_368_000;

    // ---------------------- USERS ----------------------
    Users private _users;

    function setUsers(Users memory u) external {
        _users = u;
    }

    function users() external view returns (Users memory) {
        return _users;
    }
}
